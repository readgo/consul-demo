#!/usr/bin/env bash
# ============================================================
#  k3d/deploy.sh —— 单机 k3d 一键滚动更新（自动找最新 tag）
#
#  执行位置：k3d 宿主机（装了 docker + k3d + kubectl 的那台）。
#  用法：
#    ./k3d/deploy.sh                     # 自动找最新 tag，有更新就发
#    ./k3d/deploy.sh --dry-run           # 只打印将要执行的命令，不动任何东西
#    TAG=v20261023-001122 ./k3d/deploy.sh
#    LOCAL_ONLY=1 ./k3d/deploy.sh        # 不查 Docker Hub，只认本机 docker 里已有的
#    SKIP_IMPORT=1 ./k3d/deploy.sh       # 跳过 pull/import（节点能自己拉时用）
#
#  ------------------------------------------------------------------
#  与 ../deploy.sh（3 台独立 VM 的 k3s）唯一但致命的差别：
#
#    k3s  : 三个节点共享同一个镜像仓库，kubelet 自己 pull 就能拿到，
#           脚本只要 set image 就行。
#
#    k3d  : 三个「节点」是三个 docker 容器，各跑自己的 containerd，
#           **不共享宿主机的 docker 镜像**。set image 之后节点里没有该镜像，
#           imagePullPolicy: IfNotPresent 又不会去拉 → ImagePullBackOff；
#           而 maxUnavailable: 0 让旧 Pod 不删，rollout 会一直卡住。
#
#  所以这里的顺序是硬性的三级串联，中间任何一步失败都必须停：
#
#      docker pull  →  k3d image import  →  kubectl set image
#
#  ------------------------------------------------------------------
#  tag 来源说明（为什么两个来源都要查）：
#    本机 docker   —— 权威，因为只有它里面的镜像能被 import
#    Docker Hub    —— 是最新发布物，但可能还没拉到本机；查到了会自动补 pull
#  若 Hub 上有更新的 tag 但 pull 失败（网络/私有仓库），直接退出，不发版。
#  ============================================================
set -uo pipefail

CLUSTER="${CLUSTER:-demo}"
NS="${NS:-default}"
DEPLOY="${DEPLOY:-consul-demo}"
CONTAINER="${CONTAINER:-app}"
TAG="${TAG:-}"
REPO="${REPO:-}"
LOCAL_ONLY="${LOCAL_ONLY:-0}"
SKIP_IMPORT="${SKIP_IMPORT:-0}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-240s}"
IMPORT_TIMEOUT="${IMPORT_TIMEOUT:-600}"
DRY_RUN="${DRY_RUN:-0}"
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY_RUN=1; done

if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_GRN=$'\e[32m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'; C_END=$'\e[0m'
else
  C_RED=; C_YEL=; C_GRN=; C_DIM=; C_B=; C_END=
fi

step() { printf '\n%s[%s]%s %s\n' "$C_B" "$1" "$C_END" "$2"; }
info() { printf '      %s\n' "$*"; }
dim()  { printf '      %s%s%s\n' "$C_DIM" "$*" "$C_END"; }
warn() { printf '      %s%s%s\n' "$C_YEL" "$*" "$C_END"; }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_END" >&2; exit 1; }

# ---------- 0. 前置检查 ----------
step 0/6 "前置检查"

command -v kubectl >/dev/null 2>&1 || die "找不到 kubectl"
command -v docker  >/dev/null 2>&1 || die "找不到 docker"
command -v k3d     >/dev/null 2>&1 || die "找不到 k3d"

KCTL=(kubectl)
# 不用 `| grep -qx`：grep 命中即退出会让上游 kubectl 收到 SIGPIPE，
# 在 pipefail 下整个管道返回非 0，把「有 context」误判成「没有」。
ctx_names=$(kubectl config get-contexts -o name 2>/dev/null)
has_ctx=0
while IFS= read -r c; do [ "$c" = "k3d-$CLUSTER" ] && has_ctx=1; done <<<"$ctx_names"
if [ "$has_ctx" = "1" ]; then
  KCTL=(kubectl --context "k3d-$CLUSTER")
  info "kubectl context : k3d-$CLUSTER"
else
  warn "kubeconfig 里没有 k3d-$CLUSTER，用当前 context：$(kubectl config current-context 2>/dev/null)"
fi

"${KCTL[@]}" -n "$NS" get deploy "$DEPLOY" --request-timeout=10s >/dev/null 2>&1 \
  || die "连不上集群，或 $NS/$DEPLOY 不存在（集群起来了吗：k3d cluster list）"

docker inspect "k3d-$CLUSTER-agent-0" >/dev/null 2>&1 \
  || die "找不到容器 k3d-$CLUSTER-agent-0，确认 --cluster / CLUSTER 参数"

info "集群 / 对象   : $CLUSTER / $NS/$DEPLOY（容器 $CONTAINER）"
[ "$DRY_RUN" = "1" ] && warn "dry-run 模式：只打印，不执行任何变更"

# ---------- 1. 读当前版本 ----------
step 1/6 "读取当前版本"

cur_image=$("${KCTL[@]}" -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].image}" 2>/dev/null)

if [ -z "$cur_image" ]; then
  printf '      读不到容器 %s，实际容器名：\n' "$CONTAINER"
  "${KCTL[@]}" -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' | sed 's/^/        /'
  exit 1
fi

# 镜像可能是 registry:5000/a/b:v1，不能直接 ${img%:*}（会切错 registry 端口）
if [ -n "$REPO" ]; then
  cur_repo="$REPO"; cur_tag="${cur_image##*:}"
else
  last="${cur_image##*/}"
  if [[ "$last" == *:* ]]; then
    cur_repo="${cur_image%:*}"; cur_tag="${last##*:}"
  else
    cur_repo="$cur_image"; cur_tag="latest"
  fi
fi

info "当前镜像     : $cur_repo:$cur_tag"

# ---------- 2. 发现可用 tag ----------
is_release_tag() { [[ "$1" =~ ^v[0-9] ]]; }

tags_docker() {
  local repo="$1" line t
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | while IFS= read -r line; do
        case "$line" in
          *"$repo:"*) t="${line##*:}"; is_release_tag "$t" && printf '%s\n' "$t" ;;
        esac
      done
}

tags_hub() {
  local repo="$1" json
  # 公开仓库免认证。--max-time 8：国内不通时别把发版卡死在发现阶段。
  json=$(curl -fsS --max-time 8 --noproxy '*' \
    "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100" 2>/dev/null) || return 0
  [ -z "$json" ] && return 0
  printf '%s\n' "$json" | grep -o '"name":"[^"]*"' | sed 's/"name":"//; s/"$//' \
    | while IFS= read -r t; do is_release_tag "$t" && printf '%s\n' "$t"; done
}

step 2/6 "发现可用 tag"

docker_tags=$(tags_docker "$cur_repo" | sort -uV)
if [ -n "$docker_tags" ]; then
  docker_latest=$(printf '%s\n' "$docker_tags" | tail -n1)
  info "本机 docker    : $docker_latest  （共 $(printf '%s\n' "$docker_tags" | wc -l | tr -d ' ') 个版本）"
else
  info "本机 docker    : ${C_DIM}无${C_END}"
  docker_latest=""
fi

hub_latest=""
if [ -n "$TAG" ]; then
  dim "Docker Hub     : 已用 TAG 指定，跳过"
elif [ "$LOCAL_ONLY" = "1" ]; then
  dim "Docker Hub     : 已跳过（LOCAL_ONLY=1）"
else
  hub_tags=$(tags_hub "$cur_repo" | sort -uV)
  if [ -n "$hub_tags" ]; then
    hub_latest=$(printf '%s\n' "$hub_tags" | tail -n1)
    info "Docker Hub     : $hub_latest"
  else
    dim "Docker Hub     : 查不到（网络不通或私有仓库），已忽略"
  fi
fi

new_tag="$TAG"
if [ -z "$new_tag" ]; then
  new_tag=$(printf '%s\n%s\n' "${docker_latest:-}" "${hub_latest:-}" \
            | grep -E '^v[0-9]' | sort -uV | tail -n1)
fi
[ -z "$new_tag" ] && die "没有任何可用 tag。先构建镜像，或用 TAG=<tag> 指定"

info "${C_GRN}选定           : $new_tag${C_END}"

# ---------- 3. 对比 ----------
step 3/6 "对比版本"
if [ "$new_tag" = "$cur_tag" ]; then
  info "线上已经是 $new_tag，无需发版。"
  dim "想强制重建 Pod：kubectl -n $NS rollout restart deploy/$DEPLOY"
  exit 0
fi
info "线上 $cur_tag  →  目标 $new_tag"

# ---------- 4. pull + import（k3d 的核心步骤） ----------
step 4/6 "准备镜像（docker pull → k3d image import）"

target="$cur_repo:$new_tag"

if [ "$SKIP_IMPORT" = "1" ]; then
  warn "SKIP_IMPORT=1，跳过 pull/import —— 节点必须能自己拉到该镜像，"
  warn "否则新 Pod 会 ImagePullBackOff 并把 rollout 卡死。"
else
  have_local=0
  # 同样避开 `| grep -q`：printf 可能被 SIGPIPE 打断，pipefail 下返回非 0，
  # 会把「本机已有镜像」误判成「没有」，于是多做一次没必要的 pull。
  case $'\n'"$docker_tags"$'\n' in
    *$'\n'"$new_tag"$'\n'*) have_local=1 ;;
  esac
  if [ "$have_local" = "1" ]; then
    dim "本机 docker 已有 $target，跳过 pull"
  else
    info "docker pull $target"
    if [ "$DRY_RUN" = "1" ]; then
      dim "（dry-run 跳过）"
    else
      docker pull "$target" || die "pull 失败：镜像不存在、仓库私有或网络不通。未对集群做任何修改。"
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then
    dim "（dry-run 跳过）k3d image import $target -c $CLUSTER"
  else
    info "k3d image import $target -c $CLUSTER  （约 10~60s，不改动运行中的容器）"
    # import 是往各节点的 containerd 里写镜像，不影响正在服务的 Pod。
    timeout "$IMPORT_TIMEOUT" k3d image import "$target" -c "$CLUSTER" \
      || die "import 失败或超时（${IMPORT_TIMEOUT}s）。未对 Deployment 做任何修改，线上仍是 $cur_tag。"

    # 验证：镜像必须真的落到节点里，否则 set image 必然 ImagePullBackOff
    missing=""
    for n in "k3d-$CLUSTER-server-0" "k3d-$CLUSTER-agent-0" "k3d-$CLUSTER-agent-1"; do
      docker inspect "$n" >/dev/null 2>&1 || continue
      # 先把输出收进变量再判断。`docker exec ... | grep -q` 会在 grep 命中时
      # 触发 SIGPIPE，pipefail 下整条管道返回非 0，把「有镜像」误判成「没有」。
      imgs=$(docker exec "$n" crictl images 2>/dev/null) || imgs=""
      case "$imgs" in
        *"$new_tag"*) ;;
        *) missing="$missing $n" ;;
      esac
    done
    if [ -n "$missing" ]; then
      first_node=$(printf '%s' "$missing" | awk '{print $1}')
      die "这些节点里没有 $new_tag：$missing
      不要继续 set image，否则新 Pod 会 ImagePullBackOff。
      手动确认：docker exec $first_node crictl images | grep consul-demo"
    fi
    info "${C_GRN}✓ 所有节点均已加载 $new_tag${C_END}"
  fi
fi

# ---------- 5. 更新镜像 ----------
step 5/6 "更新 Deployment"
cmd=("${KCTL[@]}" -n "$NS" set image "deploy/$DEPLOY" "$CONTAINER=$target")
printf '      %s%s%s\n' "$C_DIM" "${cmd[*]}" "$C_END"

if [ "$DRY_RUN" = "1" ]; then
  info "dry-run 结束，未对集群做任何修改。"
  exit 0
fi

"${cmd[@]}" || die "set image 失败"

# ---------- 6. 等待滚动完成 ----------
step 6/6 "等待滚动完成（超时 $ROLLOUT_TIMEOUT）"
if "${KCTL[@]}" -n "$NS" rollout status "deploy/$DEPLOY" --timeout="$ROLLOUT_TIMEOUT"; then
  printf '\n%s✓ 发布成功：%s%s\n' "$C_GRN" "$target" "$C_END"
  printf '  旧版本 %s 已全部替换\n' "$cur_tag"
  printf '  回滚上一版：kubectl -n %s rollout undo deploy/%s\n' "$NS" "$DEPLOY"
  printf '  查看历史  ：kubectl -n %s rollout history deploy/%s\n\n' "$NS" "$DEPLOY"
  exit 0
fi

# 失败不自动回滚，交给人决定；但把定位所需信息一次给全
printf '\n%s✗ 滚动更新没有在 %s 内完成%s\n' "$C_RED" "$ROLLOUT_TIMEOUT" "$C_END"

printf '\n  当前 Pod：\n'
"${KCTL[@]}" -n "$NS" get pods -l "app=$DEPLOY" -o wide 2>/dev/null | sed 's/^/    /'

printf '\n  最近告警事件：\n'
"${KCTL[@]}" -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
  | grep -iE 'warning|failed|unhealthy|backoff|error|oom' | tail -n 10 | sed 's/^/    /'

# 不能按 phase != Running 找 —— 最常见的失败是「Running 但 readinessProbe 不过」
printf '\n  未就绪 Pod（重点看 Events 段）：\n'
notready=$("${KCTL[@]}" -n "$NS" get pods -l "app=$DEPLOY" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
  | grep -v 'True' | awk 'NF {print $1}' | head -2)

if [ -z "$notready" ]; then
  dim "全部 Pod 都 Ready —— 可能卡在调度或旧 Pod Terminating，看上面的告警事件。"
else
  for p in $notready; do
    printf '    ── %s\n' "$p"
    "${KCTL[@]}" -n "$NS" describe pod "$p" 2>/dev/null | sed -n '/Events:/,$p' | sed 's/^/      /'
  done
fi

printf '\n  旧版本仍在服务（maxUnavailable: 0），线上没断。\n'
printf '  回滚：kubectl -n %s rollout undo deploy/%s\n\n' "$NS" "$DEPLOY"
exit 1
