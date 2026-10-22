#!/usr/bin/env bash
# 角色：本机客户端（consul agent，client 模式）
#
#   sudo ./deploy.sh agent
#
# 业务机各装一次。装好之后应用注册到本机的 127.0.0.1:8500，
# 由这个 agent 转给注册中心，每台机器在注册中心里是独立的一个节点。
#
# 注册中心那台会自动跳过（它自带 server agent，再装一个会抢端口）。
# ./deploy.sh service 会自动调这里，单独执行只是为了排查问题。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

need_root agent
need_docker

# 注册中心在本机：server 自己就是一个 agent，不用再加
if registry_is_self; then
  say "    注册中心在本机（$REGISTRY），它自带 agent，不需要再装"
  exit 0
fi

REGISTRY_HOST="$(registry_host)"
export REGISTRY_HOST
export MY_IP="$(detect_ip)"
export NODE_NAME="$(node_name)"

step "1/3 准备"
say "    节点名      $NODE_NAME"
say "    本机地址    $MY_IP"
say "    加入        $REGISTRY_HOST:8301（$REGISTRY_HOST 的 serf 端口）"

step "2/3 检查能不能连上注册中心"
registry_reachable || die "连不上注册中心 $REGISTRY（地址或端口不通）。
     - 本机 config.ini 里的 REGISTRY 要填注册中心那台的内网地址
     - 检查那边防火墙有没有放开 8500 和 8301
     - 注册中心还在启动：等 10 秒再试一次"

# 数据目录要给容器里的 consul 用户写权限，跟注册中心那边同一个处理
mkdir -p data/agent
chmod 777 data/agent

cd "$ROOT/roles/agent"

step "3/3 启动并等它加入集群"
docker compose up -d --quiet-pull --no-build

# 判据：本机 agent 能报出集群 leader，说明不但进程起来了，而且真的加进去了。
# 只看容器是 Up 不够——retry-join 还没连上时容器也是 Up。
if wait_local_agent 25; then
  say "    已加入集群。注册中心里现在有这些节点："
  curl -fsS "$CONSUL_AGENT_ADDR/v1/catalog/nodes" 2>/dev/null \
    | grep -oE '"Node":"[^"]*"|"Address":"[^"]*"' | paste - - \
    | sed 's/"Node":"//; s/"Address":"//; s/"//g; s/^/      /' || true
else
  say "    [注意] 30 秒内没连上注册中心，看日志：docker logs consul-demo-agent --tail 40"
  say "     - 确认 $REGISTRY_HOST 的 8301 端口从本机能通"
  exit 1
fi

cat <<EOF

这台的客户端装好了，节点名是 $NODE_NAME。

应用的注册地址已经改成 127.0.0.1:8500（本机 agent），不用你填。

查看集群：
  docker exec consul-demo-agent consul members

查看本机注册了哪些服务：
  curl -s http://127.0.0.1:8500/v1/agent/services

这台下线（会连同它注册的服务一起从目录消失）：
  docker rm -f consul-demo-agent

EOF
