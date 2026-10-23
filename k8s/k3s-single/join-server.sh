#!/usr/bin/env bash
# ============================================================
#  join-server.sh —— 阶段二：把一台新机器加入为 server
#
#  执行位置：node2、node3 上各执行一次（不是 node1）
#  用法：
#    sudo ./join-server.sh <node1的IP> <node-token>
#
#  node-token 在 node1 上取：
#    sudo cat /var/lib/rancher/k3s/server/node-token
#  install-single.sh 结束时也会直接打印这条命令。
#
#  为什么加入为 server 而不是 agent：
#    k3s 的 server 节点默认没有 NoSchedule 污点，可以正常跑业务 Pod。
#    3 台都做 server = HA 控制面 + 3 个 worker，不需要额外的 agent 机器，
#    而且任一台挂掉 quorum 仍是 2/3，控制面不受影响。
#    如果只做 agent，唯一那台 server 一挂，API 就废了，不能再调度。
#
#  为什么这一步不会影响业务：
#    新机器加入不碰已有节点上的任何 Pod，也不重启现有进程。
#    node1 上跑着的副本继续服务，只是集群多了两个可调度节点。
# ============================================================
set -euo pipefail

SD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cluster.env
. "$SD/cluster.env"
# shellcheck source=lib.sh
. "$SD/lib.sh"

SERVER_IP="${1:-}"
TOKEN="${2:-}"

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_E=$'\e[0m'
step() { printf '\n%s[%s]%s %s\n' "$C_B" "$1" "$C_E" "$2"; }
info() { printf '      %s\n' "$*"; }
ok()   { printf '      %s✓ %s%s\n' "$C_G" "$*" "$C_E"; }
warn() { printf '      %s! %s%s\n' "$C_Y" "$*" "$C_E"; }
die()  { printf '%s✗ %s%s\n' "$C_R" "$*" "$C_E" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 sudo 执行：sudo $0 <node1-ip> <token>"
[ -n "$SERVER_IP" ] || die "缺少参数。用法：sudo $0 <node1-ip> <node-token>"
[ -n "$TOKEN" ]     || die "缺少 token。在 node1 上取：sudo cat /var/lib/rancher/k3s/server/node-token"

# ---------------------------------------------------------------
step 0/3 "识别本机身份"
# 本机 IP 用「到 apiserver 的路由」反查，不读任何写死的节点清单。
# 这样加第 4、5、10 台时不需要改 cluster.env——集群成员本来就是动态的
# （K3S_URL + K3S_TOKEN 加入，成员表在 etcd 里）。
detect_my_ip() {
  ip -4 route get "$1" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

MY_IP="${MY_IP:-}"
if [ -z "$MY_IP" ]; then
  MY_IP=$(detect_my_ip "$SERVER_IP")
fi
if [ -z "$MY_IP" ]; then
  # 到 server 没有可用路由时，退回第一个非回环 IPv4
  MY_IP=$(ip -4 addr show 2>/dev/null \
          | awk '$1=="inet" && $2 !~ /^127\./{sub(/\/.*/,"",$2); print $2; exit}')
fi
[ -n "$MY_IP" ] || die "无法确定本机 IP。手动指定：sudo MY_IP=<本机IP> $0 $SERVER_IP <token>"

if [ "$MY_IP" = "$SERVER_IP" ]; then
  die "本机就是 $SERVER_IP（第一个 server），本脚本要在新增节点上执行。"
fi

ok "本机是 $MY_IP（hostname: $(hostname -s)），准备加入 $SERVER_IP 所在集群"

# 先查集群现有节点。k3s 的 server token 当 Bearer 直接能读 /api/v1/nodes，
# 不需要本机先有 kubeconfig —— 这一步就是「我现在到底在哪台机器上」的凭证。
nodes_json=$(curl -kfsS --max-time 5 \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://${SERVER_IP}:${K3S_API_PORT}/api/v1/nodes" 2>/dev/null) || nodes_json=""

# 从节点列表里按 IP 反查节点名（有 python3 就精确解 JSON，没有就不显示名字）
node_name_of_ip() {
  local ip="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  printf '%s' "$nodes_json" | python3 -c '
import json,sys
ip=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for n in d.get("items",[]):
    for a in n.get("status",{}).get("addresses",[]):
        if a.get("address")==ip:
            print(n["metadata"]["name"]); sys.exit(0)
sys.exit(1)' "$ip" 2>/dev/null
}

# ---------------------------------------------------------------
# 最常见的一种情况：这台机器已经是集群成员了，用户又跑了一次脚本。
# 必须排在「k3s 在跑」前面判断——否则会误报成「克隆机没卸 k3s」，
# 让人以为要卸载一台正在正常服务的节点。
if [ -n "$nodes_json" ] && printf '%s' "$nodes_json" | grep -q "\"address\":\"${MY_IP}\""; then
  _n=$(node_name_of_ip "$MY_IP") || _n=""
  printf '\n%s✓ 本机（%s%s）已经是这个集群的成员了，不需要再 join%s\n' \
    "$C_G" "$MY_IP" "${_n:+ / $_n}" "$C_E"
  printf '  确认成员：kubectl get nodes -o wide\n'
  printf '  给**新机器**加节点，请在那台机器上执行本脚本，不要在这台重跑。\n'
  printf '  本机 k3s 正在正常服务，什么都不要动。\n'
  printf '  （如果你以为自己在另一台机器上——比如刚克隆的那台——说明它的\n'
  printf '    hostname/IP 还没改，和这台撞了：先 ip -4 addr 核对再改。）\n\n'
  exit 0
fi

if systemctl is-active --quiet k3s 2>/dev/null; then
  die "本机（$(hostname -s) / $MY_IP）的 k3s 在跑，但它不是 $SERVER_IP 这个集群的成员。

  两种可能：
  A) 克隆来的虚拟机，带着原来的集群数据 —— 直接 join 会以同名节点注册，
     把那台节点顶掉，全站挂。
  B) 之前装到一半失败，k3s 起来了但没注册成功。

  两种都先在本机卸干净，再重跑本脚本：
      sudo /usr/local/bin/k3s-uninstall.sh        # 停服务 + 删 /var/lib/rancher/k3s
      sudo /usr/local/bin/k3s-agent-uninstall.sh  # 上面那个不存在时用这个
  确认干净：ls /var/lib/rancher/k3s 2>/dev/null（应报 No such file）"
fi

# ---------------------------------------------------------------
step 0.5/3 "检查 hostname 是否和集群里已有的节点重名"
# k3s 用 hostname 当节点名。克隆机通常也叫 k3s-t1，join 上去会顶替同名节点
# （node1 从集群消失，上面所有 Pod 变 NotReady），这是加机器最容易炸的一种。
MY_NAME="$(hostname -s)"

if [ -n "$nodes_json" ]; then
  case "$nodes_json" in
    *"\"name\":\"${MY_NAME}\""*)
      die "本机 hostname「${MY_NAME}」已经是集群里的一个节点名。
      不改名就 join，会把那台节点顶掉。先改名再重跑：

          sudo hostnamectl set-hostname <新节点名>   # 例如 k3s-t3，不能和现有节点同名
          exec sudo -i                              # 让新 hostname 生效
          sudo $0 $SERVER_IP <token>"
      ;;
  esac
  ok "hostname「${MY_NAME}」没和现有节点冲突"
else
  warn "读不到节点列表（token 权限或网络），跳过重名检查"
  warn "请自己确认本机 hostname（$MY_NAME）不是已有节点名"
fi

# ---------------------------------------------------------------
step 1/3 "连通性检查"
if ! curl -kfsS --max-time 5 "https://${SERVER_IP}:${K3S_API_PORT}/ping" >/dev/null 2>&1; then
  # /ping 在老版本可能没有，退回 TCP 探测
  if ! timeout 5 bash -c "cat < /dev/null > /dev/tcp/${SERVER_IP}/${K3S_API_PORT}" 2>/dev/null; then
    die "连不上 https://${SERVER_IP}:${K3S_API_PORT}。检查：
    1) node1 上 k3s 是否在跑：systemctl is-active k3s
    2) 两台机器网络是否互通：ping ${SERVER_IP}
    3) 防火墙是否放行 6443/tcp"
  fi
fi
ok "apiserver 可达"

# ---------------------------------------------------------------
step 2/3 "加入集群（server 角色）"
# 不能带 --cluster-init：那个参数只给「第一个 server」用，
# 后面加入的 server 靠 K3S_URL + K3S_TOKEN 找现有集群。
# --node-ip / --tls-san 各自设为本机，让从这台机器 kubectl 也能正常连。
K3S_OPTS="server --node-ip $MY_IP --tls-san $MY_IP --disable traefik --write-kubeconfig-mode 644"
info "K3S_URL=https://${SERVER_IP}:${K3S_API_PORT}"
info "INSTALL_K3S_EXEC=\"$K3S_OPTS\""

curl -sfL https://get.k3s.io \
  | K3S_URL="https://${SERVER_IP}:${K3S_API_PORT}" K3S_TOKEN="$TOKEN" \
    INSTALL_K3S_EXEC="$K3S_OPTS" sh - \
  || die "加入失败。看日志：journalctl -u k3s -n 80 --no-pager"

ok "k3s 已启动"

# ---------------------------------------------------------------
step 3/3 "等待本机节点 Ready"
# 按 INTERNAL-IP 匹配而不是 grep 主机名，理由同 lib.sh（避免 SIGPIPE 误判）
for i in $(seq 1 60); do
  if k3s kubectl get node -o wide --no-headers 2>/dev/null \
       | awk -v ip="$MY_IP" '$6==ip{f=1} END{exit !f}'; then
    break
  fi
  sleep 2
done

k3s kubectl get nodes -o wide 2>/dev/null | sed 's/^/      /' || true
k3s kubectl get node -o wide --no-headers 2>/dev/null \
  | awk -v ip="$MY_IP" '$6==ip{f=1} END{exit !f}' \
  || die "本机节点未出现在集群里，看 journalctl -u k3s -n 80"

printf '\n%s✓ %s 已加入集群%s\n' "$C_G" "$MY_IP" "$C_E"
printf '  回到 node1 确认：kubectl get nodes\n'
printf '  三台都 Ready 后，在 node1 执行：./scale-out.sh\n\n'
