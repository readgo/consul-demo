#!/usr/bin/env bash
# 角色三：业务应用
#
#   sudo ./deploy.sh service        # 本机第一个实例
#   sudo ./deploy.sh service 2      # 本机第二个实例（端口自动 +1）
#
# 每台业务机执行一次。加机器 = 新机器上执行一次这条。
# 老机器、注册中心、网关，全都不用改。
#
# 与 deploy/ 那套的唯一区别：镜像不在本地构建，直接从 Docker Hub 拉。
# 换版本 = 改 config.ini 里的 IMAGE_TAG，再执行一次这条命令。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

IDX="${1:-1}"
case "$IDX" in
  ''|*[!0-9]*) die "实例序号要写数字，例：sudo ./deploy.sh service 2" ;;
esac

need_root service
need_docker

cd "$ROOT/roles/service"

# 序号 1 -> 用配置里的端口；序号 2 -> 端口 +1；以此类推
PORT=$((APP_PORT + IDX - 1))
export INSTANCE_ID="${SERVICE_NAME}-${PORT}"
export APP_PORT="$PORT"
export MY_IP="$(detect_ip)"
export REGISTRY SERVICE_NAME IMAGE_REF

step "1/6 准备"
say "    镜像        $IMAGE_REF"
say "    本机地址    $MY_IP"
say "    节点名      $(node_name)"
say "    应用端口    $PORT"
say "    实例名      $INSTANCE_ID"
say "    注册中心    $REGISTRY"

# 应用注册到本机 agent，所以先把 agent 备好。
# 少了这一步，所有机器都会直接往注册中心那台的 agent 上注册，
# 结果全挤在同一个节点名下，同名实例互相覆盖。
step "2/6 本机客户端"
ensure_local_agent

step "3/6 检查能不能连上注册中心"
registry_reachable || die "连不上注册中心 $REGISTRY（地址或端口不通）。
     - 注册中心在别的机器：本机 config.ini 里的 REGISTRY 要填那台的内网地址
     - 注册中心就在本机：先执行 ./deploy.sh center
     - 地址没错但连不上：检查那边防火墙有没有放开 8500"
wait_registry || die "注册中心 $REGISTRY 能连上，但还没准备好（可能在选主）。等 30 秒再试一次。"

step "4/6 拉镜像"
# 记住旧容器用的镜像，重启后能说清「换版本前是哪个」
OLD_REF=""
if docker ps -a --format '{{.Names}}' | grep -qx "$INSTANCE_ID"; then
  OLD_REF="$(docker inspect --format '{{.Config.Image}}' "$INSTANCE_ID" 2>/dev/null || true)"
  say "    当前容器用的是 ${OLD_REF:-未知}"
fi
pull_image "$IMAGE_REF"

step "5/6 启动"
# 同一台机器重复执行时，先把同名容器清掉（换端口、换版本都要重建）
if docker ps -a --format '{{.Names}}' | grep -qx "$INSTANCE_ID"; then
  say "    清理同名旧容器 $INSTANCE_ID"
  docker rm -f "$INSTANCE_ID" >/dev/null
fi
docker compose up -d --quiet-pull --no-build

step "6/6 等它报到"
# 等的是「自己这一条」，不是数量。只数数量的话，别的机器报的同名实例
# 就能让这里误判成功，然后打印一句"已报到"，实际自己没注册上。
if wait_self "$SERVICE_NAME" "$INSTANCE_ID"; then
  say "    已报到。注册中心现在有这些实例："
  curl -fsS "$REGISTRY/v1/catalog/service/$SERVICE_NAME" 2>/dev/null \
    | grep -oE '"ServiceID":"[^"]*"|"ServiceAddress":"[^"]*"|"ServicePort":[0-9]*' \
    | sed 's/^/      /'
else
  say "    [注意] 30 秒内没等到 $INSTANCE_ID 报到，看日志：docker logs $INSTANCE_ID --tail 40"
  exit 1
fi

if [ -n "$OLD_REF" ] && [ "$OLD_REF" != "$IMAGE_REF" ]; then
  say ""
  say "    版本已切换：$OLD_REF  ->  $IMAGE_REF"
fi

# 不在这里碰 nginx：地址表由网关那台的 generator 重写并自己发 HUP，
# 本机就算装了 nginx 也不该由业务部署脚本去 reload（职责分开）。

cat <<EOF

这台机器装好了。网关那边会在 1~2 秒内自动发现它，不需要来这里改任何配置。

  本机直连验证    curl -s 'http://$MY_IP:$PORT/healthz'
  本机接口验证    curl -s 'http://$MY_IP:$PORT/v1/test?name=hello'
  当前跑的是      $IMAGE_REF

回滚到上一个版本：把 config.ini 里的 IMAGE_TAG 改回旧的那个，再执行一次

  sudo ./deploy.sh service

网关在别的机器上也不用管：那台的 generator 会重写地址表，然后自己给 nginx
发 HUP 平滑重载——不需要去网关敲任何命令。

下线这台机器：

  docker rm -f $INSTANCE_ID

（下线后注册中心 1 分钟内清掉它，地址表随之自动重写并重载。清掉之前那几十秒里
 nginx 靠 max_fails=2 fail_timeout=2s 自动绕开这个死地址。）

EOF
