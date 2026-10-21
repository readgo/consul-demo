#!/usr/bin/env bash
# 角色二：网关
#
#   sudo ./deploy.sh gateway
#
# 装什么：一个「后端地址列表生成器」（容器），把 backends.conf 写到 nginx 的
# include 目录。那个目录不用你指定，脚本自己判定（规则见下）。
# 不装 nginx 本身，也不改宿主机的 nginx —— 站点配置缺了会生成一份，其余由你手动维护。
#
# 目录判定（config.ini 的 NGINX_CONF_DIR 留空时）：
#   1. 默认用 <当前用户家目录>/nginx/conf.d
#   2. 若 nginx 没有 include 这个默认目录，改用 nginx 自己的 conf.d
#
# 装完之后：加机器、删机器都不需要再来这里。
# 唯一要做的：后端有变化时手动 reload 一次 nginx（脚本会告诉你什么时候）。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

need_root gateway
need_docker

cd "$ROOT/roles/gateway"

step "1/3 检查能不能连上注册中心"
registry_reachable || die "连不上注册中心 $REGISTRY（地址或端口不通）。
     - 注册中心在别的机器：本机 config.ini 里的 REGISTRY 要填那台的内网地址
     - 注册中心就在本机：先执行 ./deploy.sh center
     - 地址没错但连不上：检查那边防火墙有没有放开 8500"
wait_registry || die "注册中心 $REGISTRY 能连上，但还没准备好（可能在选主）。等 30 秒再试一次。"

step "2/3 判定 nginx 配置目录，缺的配置自动补"
say "    目录    $NGINX_CONF_DIR"
say "    来源    $NGINX_CONF_SRC"
ensure_nginx_files "$NGINX_CONF_DIR"

if ! conf_includes_dir "$NGINX_CONF_DIR"; then
  say ""
  say "    [待办] nginx 还没有 include 这个目录。需要在 /etc/nginx/nginx.conf 的"
  say "           http {} 里加一行（手动，脚本不碰宿主机 nginx）："
  say "             include $NGINX_CONF_DIR/*.conf;"
fi

step "3/3 启动地址列表生成器"
export REGISTRY_HOSTPORT
docker compose up -d --quiet-pull

if wait_backend_file "$NGINX_CONF_DIR/backends.conf"; then
  say "    后端地址列表：$NGINX_CONF_DIR/backends.conf"
  grep 'server ' "$NGINX_CONF_DIR/backends.conf" \
    | grep -v '127\.0\.0\.1:1 down' | sed 's/^/      /'
else
  say "    [注意] 注册中心里还没有 passing 的业务实例。"
  say "           现在那一份是占位（down），nginx 起得来但请求会 502。"
  say "           等某台机器执行 ./deploy.sh service 后，这里会自动换成真实地址。"
fi

cat <<EOF

网关这边准备好了。收尾两件事：

  1) $NGINX_CONF_DIR 是否已被 nginx include
     上面没打印「待办」就是已经 include，什么都不用做。

  2) 以后只要有机器加进来或下线，reload 一次让 nginx 读到新名单：

       sudo nginx -t && sudo nginx -s reload

验证：

  curl -s 'http://$(detect_ip):$SITE_PORT/api/demo/v1/test?name=hello'

EOF
