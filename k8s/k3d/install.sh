#!/usr/bin/env bash
# ============================================================
#  k3d/install.sh —— 单机 k3d 从零到跑通：建集群 → 导镜像 → 部署
#
#  执行位置：k3d 宿主机（有 docker + k3d + kubectl 的那台）。
#  对应 DEPLOY.md 的第 3、4、5 步，一条命令代替手工敲。
#
#  用法：
#    ./install.sh                        # 集群不存在就建，然后导镜像 + 部署
#    ./install.sh --dry-run              # 只打印将要做什么
#    TAG=v20261023-001122 ./install.sh   # 指定镜像版本
#    CREATE_CLUSTER=0 ./install.sh       # 只做「导镜像 + 部署」，不碰集群
#    PORT=8081 CLUSTER=demo ./install.sh # 换映射端口 / 集群名
#
#  幂等性：可以反复执行。
#    - 集群已存在        → 跳过创建
#    - 节点已有该镜像    → 跳过 import
#    - Deployment 已存在 → kubectl apply 只做必要变更
#
#  ------------------------------------------------------------------
#  为什么必须 import：k3d 的「节点」是三个 docker 容器，各跑自己的
#  containerd，**不共享宿主机的 docker 镜像**。只做 kubectl apply 的话，
#  imagePullPolicy: IfNotPresent 不会去拉，新 Pod 直接 ImagePullBackOff；
#  而 maxUnavailable: 0 让旧 Pod 不删，rollout 会一直卡住。
#  ============================================================
set -uo pipefail

CLUSTER="${CLUSTER:-demo}"
API_PORT="${API_PORT:-6550}"
PORT="${PORT:-8081}"
NS="${NS:-default}"
DEPLOY="${DEPLOY:-consul-demo}"
CONTAINER="${CONTAINER:-app}"
TAG="${TAG:-}"
REPO="${REPO:-}"
CREATE_CLUSTER="${CREATE_CLUSTER:-1}"
LOCAL_ONLY="${LOCAL_ONLY:-0}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-240s}"
IMPORT_TIMEOUT="${IMPORT_TIMEOUT:-600}"
DRY_RUN="${DRY_RUN:-0}"
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY_RUN=1; done

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST="${MANIFEST:-$HERE/app.yml}"

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
run()  { if [ "$DRY_RUN" = "1" ]; then dim "（dry-run）$(printf '%q ' "$@")"; else "$@"; fi; }

# ---------- 0. 前置检查 ----------
step 0/7 "前置检查"

for c in kubectl docker k3d curl; do
  command -v "$c" >/dev/null 2>&1 || die "找不到 $c"
done
[ -f "$MANIFEST" ] || die "找不到清单文件：$MANIFEST（用 MANIFEST=/path/app.yml 指定）"

info "集群 / 命名空间 : $CLUSTER / $NS"
info "清单文件        : $MANIFEST"
info "宿主映射端口    : $PORT → serverlb:30080"
[ "$DRY_RUN" = "1" ] && warn "dry-run 模式：只打印，不执行任何变更"

# ---------- 1. 集群 ----------
step 1/7 "确保集群存在"

clusters=$(k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}')
exists=0
while IFS= read -r c; do [ "$c" = "$CLUSTER" ] && exists=1; done <<<"$clusters"

if [ "$exists" = "1" ]; then
  info "${C_GRN}集群 $CLUSTER 已存在，跳过创建${C_END}"
elif [ "$CREATE_CLUSTER" != "1" ]; then
  die "集群 $CLUSTER 不存在，且 CREATE_CLUSTER=0。先手动建：
      k3d cluster create $CLUSTER --servers 1 --agents 2 --api-port $API_PORT \\
        --k3s-arg '--disable=traefik@server:0' -p $PORT:30080@loadbalancer --wait"
else
  info "创建集群 $CLUSTER（1 server + 2 agents，首次要拉 k3s 镜像，可能几分钟）"
  run k3d cluster create "$CLUSTER" \
    --servers 1 --agents 2 \
    --api-port "$API_PORT" \
    --k3s-arg "--disable=traefik@server:0" \
    -p "$PORT:30080@loadbalancer" \
    --wait || die "创建失败。卡在 Starting node 'k3d-demo-tools' 见 DEPLOY.md 第 3 节"
fi

# ---------- kubectl context ----------
# 不用 `| grep -qx`：grep 命中即退出会让上游收 SIGPIPE，pipefail 下整条
# 管道返回非 0，把「有 context」误判成「没有」。
ctx_names=$(kubectl config get-contexts -o name 2>/dev/null)
has_ctx=0
while IFS= read -r c; do [ "$c" = "k3d-$CLUSTER" ] && has_ctx=1; done <<<"$ctx_names"
if [ "$has_ctx" = "1" ]; then
  KCTL=(kubectl --context "k3d-$CLUSTER")
  info "kubectl context : k3d-$CLUSTER"
else
  KCTL=(kubectl)
  warn "没有 k3d-$CLUSTER 这个 context，用当前：$(kubectl config current-context 2>/dev/null)"
fi

if [ "$DRY_RUN" != "1" ]; then
  "${KCTL[@]}" get nodes --request-timeout=10s >/dev/null 2>&1 || die "连不上集群，节点没就绪？"
  "${KCTL[@]}" get nodes --no-headers 2>/dev/null | awk '{printf "      node %-22s %s\n", $1, $2}'
fi

# ---------- 2. 选定镜像 ----------
step 2/7 "选定镜像版本"

is_release_tag() { [[ "$1" =~ ^v[0-9] ]]; }

# tag 从 Deployment 推导；集群刚建还没 Deployment，就退回脚本内置的仓库名
REPO="${REPO:-wttcvs/consul-demo}"

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
  json=$(curl -fsS --max-time 8 --noproxy '*' \
    "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100" 2>/dev/null) || return 0
  [ -z "$json" ] && return 0
  printf '%s\n' "$json" | grep -o '"name":"[^"]*"' | sed 's/"name":"//; s/"$//' \
    | while IFS= read -r t; do is_release_tag "$t" && printf '%s\n' "$t"; done
}

docker_tags=$(tags_docker "$REPO" | sort -uV)
docker_latest=""
[ -n "$docker_tags" ] && docker_latest=$(printf '%s\n' "$docker_tags" | tail -n1)
if [ -n "$docker_latest" ]; then
  info "本机 docker     : $docker_latest  （共 $(printf '%s\n' "$docker_tags" | wc -l | tr -d ' ') 个版本）"
else
  dim "本机 docker     : 无"
fi

hub_latest=""
if [ -n "$TAG" ]; then
  dim "Docker Hub      : 已用 TAG 指定，跳过"
elif [ "$LOCAL_ONLY" = "1" ]; then
  dim "Docker Hub      : 已跳过（LOCAL_ONLY=1）"
else
  hub_tags=$(tags_hub "$REPO" | sort -uV)
  if [ -n "$hub_tags" ]; then
    hub_latest=$(printf '%s\n' "$hub_tags" | tail -n1)
    info "Docker Hub      : $hub_latest"
  else
    dim "Docker Hub      : 查不到（网络不通或私有仓库），已忽略"
  fi
fi

new_tag="$TAG"
if [ -z "$new_tag" ]; then
  new_tag=$(printf '%s\n%s\n' "${docker_latest:-}" "${hub_latest:-}" \
            | grep -E '^v[0-9]' | sort -uV | tail -n1)
fi
[ -z "$new_tag" ] && die "没有可用 tag。先构建镜像，或用 TAG=<tag> 指定"

target="$REPO:$new_tag"
info "${C_GRN}部署镜像        : $target${C_END}"

# ---------- 3. docker pull ----------
step 3/7 "准备镜像到宿主机 docker"

have_local=0
case $'\n'"$docker_tags"$'\n' in
  *$'\n'"$new_tag"$'\n'*) have_local=1 ;;
esac

if [ "$have_local" = "1" ]; then
  info "本机 docker 已有，跳过 pull"
else
  info "docker pull $target"
  run docker pull "$target" || die "pull 失败：镜像不存在、仓库私有或网络不通。未做任何部署。"
fi

# ---------- 4. 导入到 k3d 节点 ----------
step 4/7 "导入镜像到 k3d 节点"

NODES=("k3d-$CLUSTER-server-0" "k3d-$CLUSTER-agent-0" "k3d-$CLUSTER-agent-1")

# 所有节点都已有该 tag 才跳过。先把输出收进变量再判断——`docker exec | grep -q`
# 会在 grep 命中时触发 SIGPIPE，pipefail 下把「有镜像」误判成「没有」。
need_import=1
if [ "$DRY_RUN" != "1" ]; then
  need_import=0
  for n in "${NODES[@]}"; do
    docker inspect "$n" >/dev/null 2>&1 || continue
    imgs=$(docker exec "$n" crictl images 2>/dev/null) || imgs=""
    case "$imgs" in
      *"$new_tag"*) ;;
      *) need_import=1 ;;
    esac
  done
fi

if [ "$need_import" = "0" ]; then
  info "所有节点已有 $new_tag，跳过 import"
else
  if [ "$DRY_RUN" = "1" ]; then
    dim "（dry-run）k3d image import $target -c $CLUSTER"
  else
    info "k3d image import $target -c $CLUSTER  （约 10~60s，不影响运行中的 Pod）"
    timeout "$IMPORT_TIMEOUT" k3d image import "$target" -c "$CLUSTER" \
      || die "import 失败或超时（${IMPORT_TIMEOUT}s）。未做任何部署。"

    missing=""
    for n in "${NODES[@]}"; do
      docker inspect "$n" >/dev/null 2>&1 || continue
      imgs=$(docker exec "$n" crictl images 2>/dev/null) || imgs=""
      case "$imgs" in
        *"$new_tag"*) ;;
        *) missing="$missing $n" ;;
      esac
    done
    if [ -n "$missing" ]; then
      first_node=$(printf '%s' "$missing" | awk '{print $1}')
      die "这些节点里没有 $new_tag：$missing
      不要继续 apply，否则新 Pod 会 ImagePullBackOff。
      手动确认：docker exec $first_node crictl images | grep consul-demo"
    fi
    info "${C_GRN}✓ 所有节点均已加载 $new_tag${C_END}"
  fi
fi

# ---------- 5. 部署 ----------
step 5/7 "应用清单"

cur_image=""
# dry-run 也查一下，只是只读操作，这样「首次部署 / 已存在」的判断是准的
cur_image=$("${KCTL[@]}" -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].image}" 2>/dev/null)

if [ -z "$cur_image" ]; then
  info "首次部署：apply $MANIFEST，镜像替换为 $target"
else
  info "已存在（当前 $cur_image），apply 只做必要变更"
fi

# 清单里 image 是写死的；用 sed 把那一行替换成选定版本再 apply。
# 走管道 apply 而不是改文件，仓库里的 app.yml 始终保持原样。
if [ "$DRY_RUN" = "1" ]; then
  dim "（dry-run）sed 替换 image 行 → ${KCTL[*]} -n $NS apply -f -"
else
  sed -E "s|^([[:space:]]*image:[[:space:]]*).*|\1$target|" "$MANIFEST" \
    | "${KCTL[@]}" -n "$NS" apply -f - || die "apply 失败"
fi

# ---------- 6. 等待滚动 ----------
step 6/7 "等待就绪（超时 $ROLLOUT_TIMEOUT）"
if [ "$DRY_RUN" = "1" ]; then
  dim "（dry-run）rollout status deploy/$DEPLOY"
else
  "${KCTL[@]}" -n "$NS" rollout status "deploy/$DEPLOY" --timeout="$ROLLOUT_TIMEOUT" \
    || die "没有在 $ROLLOUT_TIMEOUT 内就绪。排查：
      kubectl -n $NS get pods -o wide
      kubectl -n $NS describe pod <未就绪的 Pod> | sed -n '/Events:/,\$p'"
  printf '\n'
  "${KCTL[@]}" -n "$NS" get pods -o wide | sed 's/^/      /'
fi

# ---------- 7. 自检 ----------
step 7/7 "链路自检"

if [ "$DRY_RUN" = "1" ]; then
  dim "（dry-run）curl 127.0.0.1:$PORT/v1/test"
  exit 0
fi

ok=0
resp=$(curl -sS --noproxy '*' --max-time 5 "http://127.0.0.1:$PORT/v1/test?name=install-$(date +%H%M%S)" 2>/dev/null) && ok=1
if [ "$ok" = "1" ]; then
  info "serverlb($PORT) : $resp"
else
  warn "serverlb($PORT) 不通。可能：端口映射没生效、$PORT 被占、serverlb 未启动"
  dim "  查：docker ps | grep serverlb ；ss -lntp | grep :$PORT"
fi

svc=$("${KCTL[@]}" -n "$NS" get svc "$DEPLOY" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
info "Service nodePort : ${svc:-?}"

printf '\n%s✓ 完成：%s 已在 %s 上运行%s\n\n' "$C_GRN" "$target" "$CLUSTER" "$C_END"
printf '  下一步：配置 nginx 入口（DEPLOY.md 第 7 步）\n'
printf '    sudo install -m 644 %s/nginx-8080.conf /etc/nginx/conf.d/consul-demo.conf\n' "$HERE"
printf '    sudo nginx -t && sudo systemctl reload nginx\n\n'
printf '  之后发新版：%s/deploy.sh\n\n' "$HERE"
