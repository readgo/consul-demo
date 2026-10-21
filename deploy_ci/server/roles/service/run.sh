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

step "1/5 准备"
say "    镜像        $IMAGE_REF"
say "    本机地址    $MY_IP"
say "    应用端口    $PORT"
say "    实例名      $INSTANCE_ID"
say "    注册中心    $REGISTRY"

step "2/5 检查能不能连上注册中心"
registry_reachable || die "连不上注册中心 $REGISTRY（地址或端口不通）。
     - 注册中心在别的机器：本机 config.ini 里的 REGISTRY 要填那台的内网地址
     - 注册中心就在本机：先执行 ./deploy.sh center
     - 地址没错但连不上：检查那边防火墙有没有放开 8500"
wait_registry || die "注册中心 $REGISTRY 能连上，但还没准备好（可能在选主）。等 30 秒再试一次。"

step "3/5 拉镜像"
# 记住旧容器用的镜像，重启后能说清「换版本前是哪个」
OLD_REF=""
if docker ps -a --format '{{.Names}}' | grep -qx "$INSTANCE_ID"; then
  OLD_REF="$(docker inspect --format '{{.Config.Image}}' "$INSTANCE_ID" 2>/dev/null || true)"
  say "    当前容器用的是 ${OLD_REF:-未知}"
fi
pull_image "$IMAGE_REF"

step "4/5 启动"
# 同一台机器重复执行时，先把同名容器清掉（换端口、换版本都要重建）
if docker ps -a --format '{{.Names}}' | grep -qx "$INSTANCE_ID"; then
  say "    清理同名旧容器 $INSTANCE_ID"
  docker rm -f "$INSTANCE_ID" >/dev/null
fi
docker compose up -d --quiet-pull --no-build

step "5/5 等它报到"
if wait_instances "$SERVICE_NAME" 1; then
  say "    已报到。注册中心现在有这些实例："
  curl -fsS "$REGISTRY/v1/catalog/service/$SERVICE_NAME" 2>/dev/null \
    | grep -oE '"ServiceID":"[^"]*"|"ServiceAddress":"[^"]*"|"ServicePort":[0-9]*' \
    | sed 's/^/      /'
else
  say "    [注意] 没等到报到，看日志：docker logs $INSTANCE_ID --tail 40"
fi

if [ -n "$OLD_REF" ] && [ "$OLD_REF" != "$IMAGE_REF" ]; then
  say ""
  say "    版本已切换：$OLD_REF  ->  $IMAGE_REF"
fi

cat <<EOF

这台机器装好了。网关那边会自动发现它，不需要来这里加配置。

  本机直连验证    curl -s 'http://$MY_IP:$PORT/healthz'
  本机接口验证    curl -s 'http://$MY_IP:$PORT/v1/test?name=hello'
  当前跑的是      $IMAGE_REF

回滚到上一个版本：把 config.ini 里的 IMAGE_TAG 改回旧的那个，再执行一次

  sudo ./deploy.sh service

如果这是新加进来的机器，去网关那台执行一次，让 nginx 读到新地址：

  sudo nginx -t && sudo nginx -s reload

下线这台机器：

  docker rm -f $INSTANCE_ID

（下线后注册中心会在 1 分钟内自动清掉它，网关再 reload 一次即可。）

EOF
