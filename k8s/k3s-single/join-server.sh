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
MY_IP=""
for ip in "$NODE2_IP" "$NODE3_IP"; do
  if has_local_ip "$ip"; then
    MY_IP="$ip"
    break
  fi
done

if [ -z "$MY_IP" ]; then
  if has_local_ip "$NODE1_IP"; then
    die "这台是 node1（$NODE1_IP）。本脚本要在 node2 / node3 上执行。"
  fi
  die "本机 IP 既不是 $NODE2_IP 也不是 $NODE3_IP。实际地址：
$(ip -4 addr show | awk '/inet /{print "    "$2}')
请改 cluster.env 里的 NODE2_IP / NODE3_IP"
fi
ok "本机是 $MY_IP，将加入 $SERVER_IP 所在集群"

if systemctl is-active --quiet k3s 2>/dev/null; then
  warn "k3s 已在本机运行，跳过安装"
  systemctl is-active k3s
  exit 0
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
