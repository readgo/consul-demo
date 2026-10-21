#!/usr/bin/env bash
# 角色三：业务应用
#
#   sudo ./deploy.sh service        # 本机第一个实例
#   sudo ./deploy.sh service 2      # 本机第二个实例（端口自动 +1）
#
# 每台业务机执行一次。加机器 = 新机器上执行一次这条。
# 老机器、注册中心、网关，全都不用改。
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
export REGISTRY SERVICE_NAME

step "1/4 准备"
say "    本机地址    $MY_IP"
say "    应用端口    $PORT"
say "    实例名      $INSTANCE_ID"
say "    注册中心    $REGISTRY"

step "2/4 检查能不能连上注册中心"
registry_reachable || die "连不上注册中心 $REGISTRY（地址或端口不通）。
     - 注册中心在别的机器：本机 config.ini 里的 REGISTRY 要填那台的内网地址
     - 注册中心就在本机：先执行 ./deploy.sh center
     - 地址没错但连不上：检查那边防火墙有没有放开 8500"
wait_registry || die "注册中心 $REGISTRY 能连上，但还没准备好（可能在选主）。等 30 秒再试一次。"

# 同一台机器重复执行时，先把同名容器清掉（换端口、换配置都要重建）
if docker ps -a --format '{{.Names}}' | grep -qx "$INSTANCE_ID"; then
  say "    清理同名旧容器 $INSTANCE_ID"
  docker rm -f "$INSTANCE_ID" >/dev/null
fi

step "3/4 导入镜像并启动"
# 镜像包只需导入一次；本机已有就跳过，避免每次几十秒
if ! docker image inspect consul-demo:local >/dev/null 2>&1; then
  [ -f "$ROOT/image/consul-demo-image.tar.gz" ] \
    || die "找不到镜像包 $ROOT/image/consul-demo-image.tar.gz
     在开发机上执行 ./scripts/build-image.sh 先生成它。"
  say "    导入镜像（第一次会慢一点）"
  docker load -i "$ROOT/image/consul-demo-image.tar.gz" >/dev/null
fi

docker compose up -d --quiet-pull --no-build

step "4/4 等它报到"
if wait_instances "$SERVICE_NAME" 1; then
  say "    已报到。注册中心现在有这些实例："
  curl -fsS "$REGISTRY/v1/catalog/service/$SERVICE_NAME" 2>/dev/null \
    | grep -oE '"ServiceID":"[^"]*"|"ServiceAddress":"[^"]*"|"ServicePort":[0-9]*' \
    | sed 's/^/      /'
else
  say "    [注意] 没等到报到，看日志：docker logs $INSTANCE_ID --tail 40"
fi

# 不在这里碰 nginx：地址表由网关那台的 generator 重写并自己发 HUP，
# 本机就算装了 nginx 也不该由业务部署脚本去 reload（职责分开）。
cat <<EOF

这台机器装好了。网关那边会在 1~2 秒内自动发现它，不需要来这里改任何配置。

  本机直连验证    curl -s 'http://$MY_IP:$PORT/healthz'
  本机接口验证    curl -s 'http://$MY_IP:$PORT/v1/test?name=hello'

网关在别的机器上也不用管：那台的 generator 会重写地址表，然后自己给 nginx
发 HUP 平滑重载——不需要去网关敲任何命令。

下线这台机器：

  docker rm -f $INSTANCE_ID

（下线后注册中心 1 分钟内清掉它，地址表随之自动重写并重载。清掉之前那几十秒里
 nginx 靠 max_fails=2 fail_timeout=2s 自动绕开这个死地址。）

EOF
