#!/usr/bin/env bash
# 角色二：网关
#
#   sudo ./deploy.sh gateway
#
# 装什么：一个「后端地址列表生成器」（容器），把 backends.conf 写到 nginx 的
# include 目录。那个目录不用你指定，脚本自己判定（规则见下）。
# 不装 nginx 本身，也不改 nginx.conf；缺的站点配置会生成一份到 include 目录，
# 然后调用 nginx 自己的命令 reload（没在跑就启动），全程不需要你敲 nginx。
# 之后地址表一变（加机器、下线机器），容器自己发 HUP 让 nginx 重载，同样不用你管。
#
# 目录判定（config.ini 的 NGINX_CONF_DIR 留空时）：
#   1. 默认用 <当前用户家目录>/nginx/conf.d
#   2. 若 nginx 没有 include 这个默认目录，改用 nginx 自己的 conf.d
#
# 装完之后：加机器、删机器都不需要再来这里改配置。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

need_root gateway
need_docker

cd "$ROOT/roles/gateway"

# 地址表变化后靠这个脚本让 nginx 重载。缺了它，节点增删就不会自动生效。
# 打包清单里也校验它，这里再挡一道：文件没拷全、执行位丢了都能立刻发现。
[ -x ./reload-nginx.sh ] || die "缺少 roles/gateway/reload-nginx.sh，或它没有执行位。

    没有它，generator 写完地址表后没人通知 nginx，加节点/删节点都不会自动生效。
    处理：重新拷一份完整的 deploy/server 目录；或 chmod +x roles/gateway/reload-nginx.sh"

step "1/4 检查能不能连上注册中心"
registry_reachable || die "连不上注册中心 $REGISTRY（地址或端口不通）。
     - 注册中心在别的机器：本机 config.ini 里的 REGISTRY 要填那台的内网地址
     - 注册中心就在本机：先执行 ./deploy.sh center
     - 地址没错但连不上：检查那边防火墙有没有放开 8500"
wait_registry || die "注册中心 $REGISTRY 能连上，但还没准备好（可能在选主）。等 30 秒再试一次。"

step "2/4 判定 nginx 配置目录，缺的配置自动补"
say "    目录    $NGINX_CONF_DIR"
say "    来源    $NGINX_CONF_SRC"
ensure_nginx_files "$NGINX_CONF_DIR"

if ! conf_includes_dir "$NGINX_CONF_DIR"; then
  say ""
  say "    [待办] nginx 还没有 include 这个目录。需要在 /etc/nginx/nginx.conf 的"
  say "           http {} 里加一行（这一行只能你加：脚本不改 nginx.conf）："
  say "             include $NGINX_CONF_DIR/*.conf;"
fi

step "3/4 启动地址列表生成器"
export REGISTRY_HOSTPORT

# generator 写完地址表会自己发 HUP 让 nginx 重载，得先告诉它去哪读 pid。
# 宿主 /run 以只读方式挂进容器（/hostrun），所以把 pid 路径换算成容器内路径。
NGINX_PID_SRC="$(nginx_pid_file)"
case "$NGINX_PID_SRC" in
  /run/*)     NGINX_PIDFILE="/hostrun/${NGINX_PID_SRC#/run/}" ;;
  /var/run/*) NGINX_PIDFILE="/hostrun/${NGINX_PID_SRC#/var/run/}" ;;
  *)          NGINX_PIDFILE="" ;;
esac
if [ -n "$NGINX_PIDFILE" ]; then
  say "    nginx pid   $NGINX_PID_SRC（容器内读 $NGINX_PIDFILE）"
  export NGINX_PIDFILE
else
  say "    [注意] nginx 的 pid 文件在 $NGINX_PID_SRC，不在 /run 下，挂不进容器。"
  say "           地址表仍会自动更新，但改完需要你自己 reload。"
fi

docker compose up -d --quiet-pull

if wait_backend_file "$NGINX_CONF_DIR/backends.conf"; then
  say "    后端地址列表：$NGINX_CONF_DIR/backends.conf"
  # 只打真正的 server 行，注释里也含 "server " 字样，别一起打出来
  grep -E '^[[:space:]]*server[[:space:]]' "$NGINX_CONF_DIR/backends.conf" \
    | grep -v '127\.0\.0\.1:1 down' | sed 's/^/      /'
else
  say "    [注意] 注册中心里还没有 passing 的业务实例。"
  say "           现在那一份是占位（down），nginx 起得来但请求会 502。"
  say "           等某台机器执行 ./deploy.sh service 后，这里会自动换成真实地址。"
fi

step "4/4 让 nginx 生效"
# 边界：不动 nginx.conf 和它自己的文件，只把生成好的配置放进它的 include 目录，
# 然后由 nginx 自己的命令 reload/start 让它立即生效。
nginx_apply || die "nginx 没能生效，先修上面的报错（配置已就位，修好后重跑本命令即可）。"

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q ":$SITE_PORT "; then
    say "    $SITE_PORT 已在监听"
  else
    say "    [注意] $SITE_PORT 没有在监听。多半是 $NGINX_CONF_DIR 还没被 nginx include"
    say "           （见上面那段 [待办]），或站点配置里的 listen 不是 $SITE_PORT。"
  fi
fi

cat <<EOF

网关这边装好了，nginx 已经生效。

  不再需要你手动敲 nginx -t / nginx -s reload：
  本机执行 ./deploy.sh gateway 或 ./deploy.sh service 时都会自动 reload。

  别的机器加进来或下线：generator 会在 1~2 秒内重写地址表，然后自己给 nginx
  发 HUP 平滑重载。不需要回到这台执行任何命令。

  前提是 nginx 在跑（首次由本命令启动）。如果它被停掉了，HUP 发不过去
  （容器日志会打 [reload] 宿主 nginx 没在跑），重新执行一次本命令即可。

验证：

  curl -s 'http://$(detect_ip):$SITE_PORT/api/demo/v1/test?name=hello'

EOF
