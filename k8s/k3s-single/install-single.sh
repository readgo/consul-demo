#!/usr/bin/env bash
# ============================================================
#  install-single.sh —— 阶段一：单机起步
#
#  执行位置：只在 node1 执行
#  用法：
#    sudo ./install-single.sh              # 默认 embedded etcd，将来可零停机扩到 3 台
#    sudo ./install-single.sh --sqlite     # 用 SQLite，将来扩 server 需要重启一次
#    sudo ./install-single.sh --dry-run    # 只打印，不做任何变更
#
#  它做四件事：
#    1) 装 k3s（默认 --cluster-init，即 embedded etcd）
#    2) 装 nginx，配 8080 入口，upstream 里先只放 node1
#    3) 预拉镜像（失败不致命，只是 Pod 首次启动会慢）
#    4) apply 清单并等就绪
#
#  为什么默认就用 etcd：
#    单机阶段 etcd 没有任何可用性收益（quorum=1，机器挂了照样全挂），
#    代价是多占 200~400MB 内存。但它换来的是「将来加第 2、3 台 server
#    时不用重启、不动这台机器」。
#    而 SQLite → etcd 必须重启 k3s 进程，而 k3s 的 containerd 内嵌在同一
#    进程里，重启等于把本机所有 Pod 掐掉，业务必然中断 1~2 分钟。
# ============================================================
set -euo pipefail

SD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cluster.env
. "$SD/cluster.env"
# shellcheck source=lib.sh
. "$SD/lib.sh"

DATastore=etcd
DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --sqlite)  DATastore=sqlite ;;
    --etcd)    DATastore=etcd ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) awk 'NR>2{ if (/^# =+$/) exit; print }' "$0"; exit 0 ;;
    *) echo "未知参数：$a（--help 查看用法）" >&2; exit 1 ;;
  esac
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_E=$'\e[0m'
step() { printf '\n%s[%s]%s %s\n' "$C_B" "$1" "$C_E" "$2"; }
info() { printf '      %s\n' "$*"; }
ok()   { printf '      %s✓ %s%s\n' "$C_G" "$*" "$C_E"; }
warn() { printf '      %s! %s%s\n' "$C_Y" "$*" "$C_E"; }
die()  { printf '%s✗ %s%s\n' "$C_R" "$*" "$C_E" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '      （dry-run）%s\n' "$*"
  else
    "$@"
  fi
}

K() { k3s kubectl "$@"; }

# ---------------------------------------------------------------
# 清单文件定位：默认在 k3s-single/ 的上一级（即完整 k8s/ 目录里）。
# 只上传了 k3s-single/ 这一层时，app.yml 会缺失，所以在第 0 步就先找、
# 先报错——不能等到第 6 步 k3s 都装完了才发现没清单。
if [ -z "${MANIFEST:-}" ]; then
  for _c in "$SD/../app.yml" "$SD/app.yml" "$SD/../../k8s/app.yml"; do
    if [ -f "$_c" ]; then MANIFEST="$_c"; break; fi
  done
fi

# ---------------------------------------------------------------
step 0/6 "前置检查"
[ "$(id -u)" = "0" ] || die "请用 sudo 执行：sudo $0"

if [ -z "${MANIFEST:-}" ] || [ ! -f "$MANIFEST" ]; then
  die "找不到 app.yml（部署清单）。已找过：
    $SD/../app.yml
    $SD/app.yml
    $SD/../../k8s/app.yml
  最省事的做法：把仓库里的 k8s/app.yml 传到 $(dirname "$SD")/app.yml
  也可以手动指定：sudo MANIFEST=/path/to/app.yml $0"
fi
ok "清单文件 $MANIFEST"

if ! has_local_ip "$NODE1_IP"; then
  die "本机没有 ${NODE1_IP} 这个地址。实际地址：
$(ip -4 addr show | awk '/inet /{print "    "$2}' )
请改 cluster.env 里的 NODE1_IP（三台上的这个文件要一致）"
fi
ok "本机地址包含 $NODE1_IP"

info "数据存储 : $DATastore$([ "$DATastore" = etcd ] && echo '（--cluster-init，将来可零停机扩 server）')"
info "镜像     : $IMAGE"
info "入口     : nginx :$HTTP_PORT → NodePort :$NODE_PORT"

# ---------------------------------------------------------------
step 1/6 "安装 k3s"
if systemctl is-active --quiet k3s 2>/dev/null; then
  warn "k3s 已在运行，跳过安装（要重装请先 /usr/local/bin/k3s-uninstall.sh）"
else
  if [ "$DATastore" = "etcd" ]; then
    K3S_EXEC="server --cluster-init"
  else
    K3S_EXEC="server"
  fi
  # --node-ip      : 多网卡（装了 docker 会有 docker0）时不指定可能绑错网卡
  # --tls-san      : 允许从其它机器用 $NODE1_IP 连 apiserver，否则证书 SAN 不匹配
  # --disable traefik : 我们用 nginx 做入口，ingress 白占内存
  # --write-kubeconfig-mode 644 : 让普通用户能直接 kubectl
  K3S_OPTS="$K3S_EXEC --node-ip $NODE1_IP --tls-san $NODE1_IP --disable traefik --write-kubeconfig-mode 644"

  info "INSTALL_K3S_EXEC=\"$K3S_OPTS\""
  if [ "$DRY_RUN" = "1" ]; then
    info "（dry-run）跳过实际安装"
  else
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$K3S_OPTS" sh - \
      || die "k3s 安装失败。检查外网（get.k3s.io）是否可达"
    ok "k3s 已安装"
  fi
fi

if [ "$DRY_RUN" != "1" ]; then
  step 2/6 "等待节点 Ready"
  # 用 awk 判断而不是 `| grep -qw Ready`，理由见 lib.sh 的 has_local_ip 注释
  for i in $(seq 1 60); do
    if K get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{f=1} END{exit !f}'; then break; fi
    sleep 2
  done
  K get nodes --no-headers 2>/dev/null | sed 's/^/      /' || true
  K get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{f=1} END{exit !f}' \
    || die "节点 60 秒内没有 Ready，看 journalctl -u k3s -n 50"
  ok "节点已就绪"
else
  step 2/6 "等待节点 Ready"
  info "（dry-run）跳过"
fi

# ---------------------------------------------------------------
step 3/6 "安装 nginx"
if command -v nginx >/dev/null 2>&1; then
  warn "nginx 已安装，跳过 apt"
elif [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）apt-get update -qq && apt-get install -y -qq nginx"
else
  apt-get update -qq
  apt-get install -y -qq nginx || die "nginx 安装失败"
  ok "nginx 已安装"
fi

# ---------------------------------------------------------------
step 4/6 "配置 nginx 入口（upstream 先只放 node1）"
if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）将生成 upstream：$NODE1_IP:$NODE_PORT"
  info "（dry-run）将安装 $SD/nginx/consul-demo.conf → /etc/nginx/conf.d/"
else
  # 单机阶段 upstream 只有 node1。
  # 绝不能提前把 node2/node3 写进去：Local 模式下那两台没有 Pod，
  # 节点端口会直接 REJECT，nginx 每个请求都要先失败再重试。
  gen_upstream "$NODE1_IP"
  install -m 644 "$SD/nginx/consul-demo.conf" /etc/nginx/conf.d/consul-demo.conf
  reload_nginx
  ok "nginx 已监听 :$HTTP_PORT"
fi

# ---------------------------------------------------------------
step 5/6 "预拉镜像"
if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）k3s crictl pull $IMAGE"
else
  if k3s crictl pull "$IMAGE" >/dev/null 2>&1; then
    ok "镜像已在本机"
  else
    warn "预拉失败——不致命，kubelet 会自己重试。"
    warn "若 Pod 一直 ImagePullBackOff，说明节点拉不到 Docker Hub，"
    warn "需要在能联网的机器上 docker save 后 k3s ctr images import 进来。"
  fi
fi

# ---------------------------------------------------------------
step 6/6 "部署并等待就绪"
if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）sed 替换 image 行 → k3s kubectl -n $NS apply -f -"
  info "（dry-run）k3s kubectl -n $NS rollout status deploy/$DEPLOY --timeout=300s"
else
  # 清单里的 image 是写死的，这里从管道替换，不改仓库里的 app.yml，
  # 免得每换一个版本就多一次「image 字段变更」的提交。
  sed -E "s|^([[:space:]]*image:[[:space:]]*).*|\1${IMAGE}|" "$MANIFEST" \
    | K -n "$NS" apply -f - | sed 's/^/      /'

  if K -n "$NS" rollout status "deploy/$DEPLOY" --timeout=300s; then
    ok "3 副本已就绪"
  else
    printf '\n'
    K -n "$NS" get pods -o wide 2>/dev/null | sed 's/^/      /' || true
    printf '\n'
    K -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
      | grep -iE 'warning|failed|backoff' | tail -8 | sed 's/^/      /' || true
    die "滚动未在 300 秒内完成。常见原因：镜像拉不下来（见上面 events）"
  fi
fi

# ---------------------------------------------------------------
printf '\n%s────────────────────────────────────────────────%s\n' "$C_B" "$C_E"
if [ "$DRY_RUN" = "1" ]; then
  printf '%sdry-run 结束，未对系统做任何修改%s\n\n' "$C_Y" "$C_E"
  exit 0
fi

printf '%s阶段一完成%s\n' "$C_B" "$C_E"
printf '  验证：curl -s http://127.0.0.1:%s/v1/test?name=standalone-$(date +%%H%%M%%S)\n' "$HTTP_PORT"

TOKEN=$(cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo "<读取失败>")
printf '\n%s阶段二：在每台新增节点上各执行一次%s\n' "$C_B" "$C_E"
printf '  sudo ./join-server.sh %s %s\n' "$NODE1_IP" "$TOKEN"
printf '  （新节点不用改 cluster.env —— 本机 IP 由脚本按路由自动探测）\n'
printf '\n'
