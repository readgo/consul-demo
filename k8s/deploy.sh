#!/usr/bin/env bash
# ============================================================
#  deploy.sh —— 自动发现最新镜像 tag 并发布，不需要手输 tag
#
#  执行位置：任一 k3s 节点，或配好 kubeconfig 的宿主机。
#  kubectl 面向整个集群，只需要在一个地方跑一次。
#
#  用法：
#    ./k8s/deploy.sh                  # 自动找最新 tag，有更新就发
#    ./k8s/deploy.sh --dry-run        # 只打印将要执行的命令，不动集群
#    TAG=v20261022-170000 ./k8s/deploy.sh   # 跳过发现，指定 tag
#    LOCAL_ONLY=1 ./k8s/deploy.sh     # 只认本机 containerd 里已有的镜像
#
#  配套：另开一个窗口跑 ./k8s/rollout-watch.sh，这里发、那边看有没有断。
#
#  ------------------------------------------------------------------
#  为什么不能只信一个来源：
#
#    本地 containerd  —— 一定有（能跑才在），但可能落后于刚构建好的镜像
#    Docker Hub API   —— 是最新发布物，但国内网络时通时不通，且未必已拉到本机
#    git tag          —— 只代表「打过标记」，镜像可能还没构建完，最不可靠
#
#  所以：本地和 Hub 都查，取版本最大的那个。若最大 tag 本地没有，
#  明确告警——kubelet 会去拉（imagePullPolicy: IfNotPresent），拉不动就是
#  ImagePullBackOff，那是网络问题不是发版逻辑问题。
# ============================================================
set -uo pipefail

NS="${NS:-default}"
DEPLOY="${DEPLOY:-consul-demo}"
CONTAINER="${CONTAINER:-app}"
TAG="${TAG:-}"                     # 显式指定则跳过发现
REPO="${REPO:-}"                   # 显式指定则跳过从 Deployment 推导
LOCAL_ONLY="${LOCAL_ONLY:-0}"      # 1 = 不查 Docker Hub
HUB_CHECK="${HUB_CHECK:-1}"        # 0 = 完全不联网
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
DRY_RUN="${DRY_RUN:-0}"

if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_GRN=$'\e[32m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'; C_END=$'\e[0m'
else
  C_RED=; C_YEL=; C_GRN=; C_DIM=; C_B=; C_END=
fi

step() { printf '\n%s[%s]%s %s\n' "$C_B" "$1" "$C_END" "$2"; }
info() { printf '      %s\n' "$*"; }
warn() { printf '      %s%s%s\n' "$C_YEL" "$*" "$C_END"; }
err()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_END" >&2; }
die()  { err "✗ $*"; exit 1; }

# ---------- 前置检查 ----------
command -v kubectl >/dev/null 2>&1 || die "找不到 kubectl"

if ! kubectl -n "$NS" get deploy "$DEPLOY" --request-timeout=10s >/dev/null 2>&1; then
  die "连不上集群，或 $NS/$DEPLOY 不存在。检查 kubeconfig：echo \$KUBECONFIG / kubectl cluster-info"
fi

# ---------- 1. 读当前版本 ----------
step 1/5 "读取当前版本"
maybe_dry=""
[ "$DRY_RUN" = "1" ] && maybe_dry="（dry-run，不会真的执行）"

cur_image=$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].image}" 2>/dev/null)

if [ -z "$cur_image" ]; then
  err "读不到容器 $CONTAINER 的镜像，实际容器名是："
  kubectl -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null | sed 's/^/        /'
  exit 1
fi

# 拆分 repo 与 tag。注意镜像可能是 registry:5000/a/b:v1 这种带端口的写法，
# 直接 ${img%:*} 会把 registry 的端口当分隔符切错，所以先看最后一个路径段。
if [ -n "$REPO" ]; then
  cur_repo="$REPO"
  cur_tag="${cur_image##*:}"
else
  last="${cur_image##*/}"
  if [[ "$last" == *:* ]]; then
    cur_repo="${cur_image%:*}"
    cur_tag="${last##*:}"
  else
    cur_repo="$cur_image"
    cur_tag="latest"
  fi
fi

info "Deployment : $NS/$DEPLOY（容器 $CONTAINER）$maybe_dry"
info "当前镜像   : $cur_repo:$cur_tag"

# ---------- tag 发现 ----------
# 只认 v<数字> 开头的 tag：排除 latest 和各种临时标记
is_release_tag() { [[ "$1" =~ ^v[0-9] ]]; }

tags_local() {
  local repo="$1" raw line t
  # k3s ctr 要 root，先试普通用户（有些环境已经免密），不行再 sudo -n（-n 表示不交互，
  # 免得脚本卡在密码提示上）
  raw=$(k3s ctr -n k8s.io images ls -q 2>/dev/null)
  [ -z "$raw" ] && raw=$(sudo -n k3s ctr -n k8s.io images ls -q 2>/dev/null)
  [ -z "$raw" ] && return 0
  while IFS= read -r line; do
    line="${line%%@*}"                       # 去掉 @sha256:... 摘要后缀
    case "$line" in
      *"$repo:"*)
        t="${line##*:}"
        is_release_tag "$t" && printf '%s\n' "$t"
        ;;
    esac
  done <<<"$raw"
}

tags_hub() {
  local repo="$1" json
  # 公开仓库的 tag 列表不用认证。--max-time 8：国内不通时别把发版卡死在这。
  json=$(curl -fsS --max-time 8 \
    "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100" 2>/dev/null) || return 0
  [ -z "$json" ] && return 0
  printf '%s\n' "$json" \
    | grep -o '"name":"[^"]*"' | sed 's/"name":"//; s/"$//' \
    | while IFS= read -r t; do is_release_tag "$t" && printf '%s\n' "$t"; done
}

step 2/5 "发现可用 tag"

local_latest=""
local_tags=""
# 在宿主机上执行时本机没有 k3s 命令，别把它报成「镜像不存在」
if command -v k3s >/dev/null 2>&1; then
  local_tags=$(tags_local "$cur_repo" | sort -uV)
fi
if [ -n "$local_tags" ]; then
  local_latest=$(printf '%s\n' "$local_tags" | tail -n1)
  info "本地 containerd : $local_latest  （共 $(printf '%s\n' "$local_tags" | wc -l | tr -d ' ') 个版本）"
elif ! command -v k3s >/dev/null 2>&1; then
  info "本地 containerd : ${C_DIM}本机没有 k3s 命令（在宿主机执行），跳过${C_END}"
else
  info "本地 containerd : ${C_DIM}无（没导入过这个镜像，或 ctr 无权限）${C_END}"
fi

hub_latest=""
if [ -n "$TAG" ]; then
  hub_note="已用 TAG 指定，跳过"
elif [ "$LOCAL_ONLY" = "1" ] || [ "$HUB_CHECK" = "0" ]; then
  hub_note="已跳过（LOCAL_ONLY / HUB_CHECK=0）"
else
  hub_tags=$(tags_hub "$cur_repo" | sort -uV)
  if [ -n "$hub_tags" ]; then
    hub_latest=$(printf '%s\n' "$hub_tags" | tail -n1)
    info "Docker Hub      : $hub_latest"
  else
    hub_note="查不到（网络不通或仓库私有），已忽略"
  fi
fi
[ -n "${hub_note:-}" ] && info "Docker Hub      : ${C_DIM}${hub_note}${C_END}"

# ---------- 2. 选版本 ----------
new_tag="$TAG"
if [ -z "$new_tag" ]; then
  new_tag=$(printf '%s\n%s\n' "${local_latest:-}" "${hub_latest:-}" \
            | grep -E '^v[0-9]' | sort -uV | tail -n1)
fi
[ -z "$new_tag" ] && die "没找到任何可用 tag。请先构建镜像，或用 TAG=<tag> 显式指定"

info "${C_GRN}选定            : $new_tag${C_END}"

# Hub 上有、本地没有 → 告警但继续（kubelet 会去拉）
if [ -n "$local_latest" ] && [ "$new_tag" != "$local_latest" ] && [ "$new_tag" != "$cur_tag" ]; then
  if ! printf '%s\n' "$local_tags" | grep -qx "$new_tag"; then
    warn "⚠ 本机 containerd 里没有 $new_tag —— kubelet 会去仓库拉取。"
    warn "  拉不动时会 ImagePullBackOff，需要先 k3s ctr images import 或配好镜像加速。"
  fi
fi

# ---------- 3. 是否需要发版 ----------
step 3/5 "对比版本"
if [ "$new_tag" = "$cur_tag" ]; then
  info "线上已经是 $new_tag，无需发版。"
  info "${C_DIM}想强制重建 Pod 用：kubectl -n $NS rollout restart deploy/$DEPLOY${C_END}"
  exit 0
fi
info "线上 $cur_tag  →  目标 $new_tag"

# ---------- 4. 执行 ----------
step 4/5 "更新镜像"
cmd=(kubectl -n "$NS" set image "deploy/$DEPLOY" "$CONTAINER=$cur_repo:$new_tag")
printf '      %s%s%s\n' "$C_DIM" "${cmd[*]}" "$C_END"
if [ "$DRY_RUN" = "1" ]; then
  info "dry-run 结束，未对集群做任何修改。"
  exit 0
fi
"${cmd[@]}" || die "set image 失败"

# ---------- 5. 等待滚动完成 ----------
step 5/5 "等待滚动更新完成（超时 $ROLLOUT_TIMEOUT）"
if kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout="$ROLLOUT_TIMEOUT"; then
  printf '\n%s✓ 发布成功：%s%s\n' "$C_GRN" "$cur_repo:$new_tag" "$C_END"
  printf '\n  回滚上一版：kubectl -n %s rollout undo deploy/%s\n' "$NS" "$DEPLOY"
  printf '  查看历史  ：kubectl -n %s rollout history deploy/%s\n\n' "$NS" "$DEPLOY"
  exit 0
fi

# 失败时给能直接定位的信息，不自动回滚——回不回退由人决定
err ""
err "✗ 滚动更新没有在 $ROLLOUT_TIMEOUT 内完成"
printf '\n  当前 Pod：\n'
kubectl -n "$NS" get pods -l "app=$DEPLOY" -o wide 2>/dev/null | sed 's/^/    /'

printf '\n  最近告警事件：\n'
kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
  | grep -iE 'warning|failed|unhealthy|backoff|error|oom' \
  | tail -n 10 | sed 's/^/    /'

# 关键：不能按 phase != Running 找未就绪的 Pod。
# 最常见的失败恰恰是「Pod 已经 Running，但 readinessProbe 一直不过」，
# 这种 phase 是 Running，按 phase 筛会一个都找不到。必须看 Ready 条件。
printf '\n  未就绪 Pod 详情（重点看 Events 段）：\n'
notready=$(kubectl -n "$NS" get pods -l "app=$DEPLOY" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
  | grep -v 'True' | awk 'NF {print $1}' | head -2)

if [ -z "$notready" ]; then
  printf '    %s全部 Pod 都 Ready，可能是探针刚过、Pod 仍在 Terminating 或节点调度慢，看上面的告警事件。%s\n' "$C_DIM" "$C_END"
else
  for p in $notready; do
    printf '    ── %s\n' "$p"
    kubectl -n "$NS" describe pod "$p" 2>/dev/null | sed -n '/Events:/,$p' | sed 's/^/      /'
  done
fi

printf '\n  旧版本仍在服务（maxUnavailable: 0），线上没断。\n'
printf '  回滚：kubectl -n %s rollout undo deploy/%s\n\n' "$NS" "$DEPLOY"
exit 1
