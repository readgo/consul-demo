#!/usr/bin/env bash
# 角色二：网关
#
#   sudo ./deploy.sh gateway
#
# 装什么：一个「地址列表生成器」（容器）+ 一份 nginx 站点配置（文件）。
# 不装 nginx 本身，也不改宿主机的 nginx —— 配置准备好，include 和 reload 由人来做。
#
# 装完之后：加机器、删机器都不需要再来这里。
# 唯一要做的：后端有变化时手动 reload 一次 nginx（脚本会告诉你什么时候）。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

need_root gateway
need_docker

cd "$ROOT/roles/gateway"
mkdir -p conf.d

step "1/4 检查能不能连上注册中心"
registry_reachable || die "连不上注册中心 $REGISTRY（地址或端口不通）。
     - 注册中心在别的机器：本机 config.ini 里的 REGISTRY 要填那台的内网地址
     - 注册中心就在本机：先执行 ./deploy.sh center
     - 地址没错但连不上：检查那边防火墙有没有放开 8500"
wait_registry || die "注册中心 $REGISTRY 能连上，但还没准备好（可能在选主）。等 30 秒再试一次。"

step "2/4 生成 nginx 站点配置"
# 把端口和服务名填进模板
sed -e "s/__SITE_PORT__/$SITE_PORT/g" \
    -e "s/__SERVICE_NAME__/$SERVICE_NAME/g" \
    site.conf > conf.d/site.conf
say "    conf.d/site.conf（监听 $SITE_PORT，转发给 $SERVICE_NAME）"

step "3/4 启动地址列表生成器"
export REGISTRY_HOSTPORT
docker compose up -d --quiet-pull

step "4/4 等地址列表生成"
if wait_backend_file conf.d/backends.conf; then
  say "    后端地址列表："
  grep 'server ' conf.d/backends.conf | sed 's/^/      /'
else
  say "    [注意] 暂时还没有任何业务机报到，地址列表是空的。"
  say "           等有机器执行 ./deploy.sh service 后，这里会自动出现。"
fi

cat <<EOF

网关这边准备好了。下面这步必须你手动做（本脚本不碰宿主机 nginx）：

  1) 让宿主机 nginx 认这个目录（只做一次）：

     echo "include $ROOT/roles/gateway/conf.d/*.conf;" \\
       | sudo tee /etc/nginx/conf.d/consul-demo.conf
     sudo nginx -t && sudo nginx -s reload

  2) 以后只要有机器加进来或下线，reload 一次即可：

     sudo nginx -t && sudo nginx -s reload

验证：

  curl -s 'http://$(detect_ip):$SITE_PORT/api/demo/v1/test?name=hello'

EOF
