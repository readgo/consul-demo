#!/usr/bin/env bash
# 三个角色脚本共用的东西。不要单独执行它。

# shellcheck disable=SC2034

# ---------- 定位 ----------
# lib/ 的上一层就是部署目录根，不管从哪里调用都能找对
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$LIB_DIR/.." && pwd)"
cd "$ROOT"

# ---------- 读配置 ----------
# 配置文件名不带点号，ls 直接看得见，服务器上不会以为「没有配置文件」。
CONF="config.ini"
CONF_TPL="config.ini.example"

# 没有 config.ini 时先从模板生成一份。这样服务器上拿到交付包，
# 不用先手动 cp 一次就能直接跑。
ensure_conf() {
  [ -f "$CONF" ] && return 0
  if [ -f "$CONF_TPL" ]; then
    cp "$CONF_TPL" "$CONF"
    chmod 644 "$CONF"
    printf '[提示] 没有 %s，已从 %s 生成一份（用的默认值）。\n' "$CONF" "$CONF_TPL"
    printf '       要改成别的机器/端口，改完 %s 再执行一次。\n\n' "$CONF"
  else
    # 模板也没了：用内置默认值兜底，至少不让脚本直接炸
    cat > "$CONF" <<'EOF'
REGISTRY=http://127.0.0.1:8500
MY_IP=
APP_PORT=3020
SITE_PORT=8088
NGINX_CONF_DIR=
SERVICE_NAME=consul-demo
EOF
    chmod 644 "$CONF"
    printf '[提示] 既没有 %s 也没有 %s，已用内置默认值生成一份。\n\n' "$CONF" "$CONF_TPL"
  fi
}

ensure_conf

if [ -f "$CONF" ]; then
  # 只取 KEY=VALUE，忽略注释和空行；不 source，避免文件里写错就把脚本搞崩
  while IFS='=' read -r k v; do
    case "$k" in
      ''|\#*) continue ;;
    esac
    # 去掉值两边的引号与空白
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    v="$(printf '%s' "$v" | sed -e 's/[[:space:]]*$//')"
    [ -n "$k" ] && export "$k=$v"
  done < "$CONF"
fi

REGISTRY="${REGISTRY:-http://127.0.0.1:8500}"
MY_IP="${MY_IP:-}"
APP_PORT="${APP_PORT:-3020}"
SITE_PORT="${SITE_PORT:-8088}"
SERVICE_NAME="${SERVICE_NAME:-consul-demo}"
# 这几个要给 docker compose 做变量替换，必须显式导出：
# config.ini 里没写某一项时，上面的兜底赋值不会自动带上 export 属性。
export REGISTRY MY_IP APP_PORT SITE_PORT SERVICE_NAME

# ---------- nginx 配置目录：自动判定 ----------
# config.ini 里填了就用填的；留空则按两条规则推断：
#   1. 默认 <调用者家目录>/nginx/conf.d
#   2. 若宿主机 nginx 没有 include 这个默认目录，改用 nginx 自己的 conf.d
#
# 判定过程只读 nginx 的配置文件，不修改它
# （红线：脚本不写 nginx.conf 和它自身的文件，只往 include 目录放自己的配置）。

abspath() {
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

# sudo 下 $HOME 会变成 /root，必须回到真实调用者的家目录
real_user_home() {
  local u="${SUDO_USER:-}" h=""
  if [ -n "$u" ] && [ "$u" != "root" ]; then
    h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
  fi
  [ -n "$h" ] || h="${HOME:-/root}"
  printf '%s\n' "$h"
}

# nginx 主配置路径：从 nginx -V 的 --conf-path 取，取不到按发行版惯例
nginx_main_conf() {
  local p=""
  if command -v nginx >/dev/null 2>&1; then
    p="$(nginx -V 2>&1 | tr ' ' '\n' | sed -n 's/^--conf-path=//p' | head -1)"
  fi
  [ -n "$p" ] || p="/etc/nginx/nginx.conf"
  printf '%s\n' "$p"
}

nginx_installed() { command -v nginx >/dev/null 2>&1; }

# 看 nginx 的 include 有没有覆盖某个目录（递归最多 4 层，只读）
conf_includes_dir() {
  local target main
  target="$(abspath "$1")"
  main="$(nginx_main_conf)"
  [ -r "$main" ] || return 1

  local depth=0 f pat inc hit incs
  local q=( "$main" ) next=() seen=" "
  while [ ${#q[@]} -gt 0 ] && [ "$depth" -lt 4 ]; do
    next=()
    for f in "${q[@]}"; do
      [ -r "$f" ] || continue
      # 用 here-string 读，不用 <(...)：受限环境里 /dev/fd 可能不可用
      incs="$(sed -n 's/^[[:space:]]*include[[:space:]][[:space:]]*\([^;]*\);.*/\1/p' "$f" 2>/dev/null)"
      while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        case "$pat" in
          /*) : ;;
          *)  pat="$(dirname "$f")/$pat" ;;
        esac
        hit=0
        # 这里故意不加引号，让 shell 展开通配；匹配不到时保留原文
        for inc in $pat; do
          [ -e "$inc" ] || continue
          hit=1
          case "$(abspath "$inc")" in
            "$target"|"$target"/*) return 0 ;;
          esac
          case "$seen" in
            *" $inc "*) : ;;
            *)  next+=( "$inc" ); seen="$seen$inc " ;;
          esac
        done
        # 目录还空着、通配匹配不到文件：只要 include 指的就是目标目录也算
        if [ "$hit" -eq 0 ]; then
          [ "$(abspath "$(dirname "$pat")")" = "$target" ] && return 0
        fi
      done <<< "$incs"
    done
    q=( ${next[@]+"${next[@]}"} )
    depth=$((depth + 1))
  done
  return 1
}

# nginx 自己的 conf.d 目录：从主配置的 include 推，推不出按惯例
nginx_own_conf_d() {
  local main d
  main="$(nginx_main_conf)"
  d="$(sed -n 's/^[[:space:]]*include[[:space:]][[:space:]]*\([^;]*conf\.d[^;]*\)[[:space:]]*;.*/\1/p' "$main" 2>/dev/null | head -1)"
  if [ -n "$d" ]; then
    dirname "$d"
  else
    printf '/etc/nginx/conf.d\n'
  fi
}

NGINX_CONF_DIR="${NGINX_CONF_DIR:-}"
NGINX_CONF_SRC=""
if [ -n "$NGINX_CONF_DIR" ]; then
  case "$NGINX_CONF_DIR" in
    /*) : ;;
    *)  NGINX_CONF_DIR="$ROOT/$NGINX_CONF_DIR" ;;
  esac
  NGINX_CONF_DIR="$(abspath "$NGINX_CONF_DIR")"
  NGINX_CONF_SRC="config.ini 指定"
else
  _ng_default="$(abspath "$(real_user_home)/nginx/conf.d")"
  if conf_includes_dir "$_ng_default"; then
    NGINX_CONF_DIR="$_ng_default"
    NGINX_CONF_SRC="默认目录（nginx 已 include）"
  elif nginx_installed; then
    NGINX_CONF_DIR="$(abspath "$(nginx_own_conf_d)")"
    NGINX_CONF_SRC="nginx 自己的 conf.d（默认目录 $_ng_default 没有被 include）"
  else
    NGINX_CONF_DIR="$_ng_default"
    NGINX_CONF_SRC="默认目录（本机还没装 nginx，先按默认走）"
  fi
fi
export NGINX_CONF_DIR NGINX_CONF_SRC

# 注册中心地址统一去掉末尾斜杠，避免拼出 //v1/...
REGISTRY="${REGISTRY%/}"
REGISTRY_HOSTPORT="${REGISTRY#http://}"
REGISTRY_HOSTPORT="${REGISTRY_HOSTPORT#https://}"
REGISTRY_HOSTPORT="${REGISTRY_HOSTPORT%%/*}"

# ---------- 输出 ----------
say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\n[错误] %s\n' "$*" >&2; exit 1; }

# ---------- 前置检查 ----------
need_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo ./deploy.sh $*"
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "没装 docker。先装：curl -fsSL https://get.docker.com | sudo sh"
  docker compose version >/dev/null 2>&1 || die "docker 缺少 compose 插件。装：sudo apt install docker-compose-v2"
}

# ---------- 探测本机内网 IP ----------
# 优先顺序：
#   1. config.ini 里手工填的 MY_IP
#   2. 默认出口网卡上的地址（但排除虚拟网卡段）
#   3. 第一块看起来像内网的网卡（192.168 / 10. / 172.16-31）
#
# 为什么要排除：装了 docker 或代理软件的机器上常有 198.18.x.x 这类虚拟网卡，
# 默认路由指向它，直接取就会把一个外面访问不到的地址报给注册中心。
is_bogus_ip() {
  case "$1" in
    198.18.*|198.19.*) return 0 ;;   # 代理软件常用段
    169.254.*)         return 0 ;;   # 网卡没拿到地址时的自分配段
    ''|127.*)          return 0 ;;
  esac
  return 1
}

is_lan_ip() {
  case "$1" in
    192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
  esac
  return 1
}

detect_ip() {
  if [ -n "$MY_IP" ]; then
    printf '%s' "$MY_IP"
    return
  fi

  local ip all
  all="$(ip -4 -o addr show scope global 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p')"

  # 先看默认出口网卡上的地址，可用就用它
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
  if [ -n "$ip" ] && ! is_bogus_ip "$ip"; then
    printf '%s' "$ip"
    return
  fi

  # 再挑一个标准内网段地址
  for ip in $all; do
    if is_lan_ip "$ip"; then
      printf '%s' "$ip"
      return
    fi
  done

  # 实在没有：用第一个非虚拟地址
  for ip in $all; do
    if ! is_bogus_ip "$ip"; then
      printf '%s' "$ip"
      return
    fi
  done

  die "探测不到本机内网地址。请在 config.ini 里手工填 MY_IP，例：MY_IP=192.168.1.11"
}

# 注册中心地址是回环 → 说明本机就是注册中心；否则是远端
registry_is_local() {
  case "$REGISTRY_HOSTPORT" in
    127.0.0.1:*|localhost:*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- 等待 ----------
# 注册中心能不能连（快查，3 秒内给结论）。
# 用来把「地址填错了」和「已经起来了但还在选主」区分开：
# 前者应该立刻报错，不该让人干等 40 秒。
registry_reachable() {
  local host="${REGISTRY_HOSTPORT%:*}" port="${REGISTRY_HOSTPORT##*:}"
  [ "$host" = "$port" ] && port=8500
  # /dev/tcp 是 bash 内建，不依赖 nc
  timeout 3 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null
}

# 等注册中心选出主（参数：最多等几秒）
wait_registry() {
  local max="${1:-40}" i
  for i in $(seq 1 "$max"); do
    curl -fsS "$REGISTRY/v1/status/leader" 2>/dev/null | grep -q ':8300' && return 0
    sleep 1
  done
  return 1
}

# 等某个服务出现在注册中心里（参数：服务名，期望实例数）
wait_instances() {
  local name="$1" want="${2:-1}" i n
  for i in $(seq 1 30); do
    n="$(curl -fsS "$REGISTRY/v1/catalog/service/$name" 2>/dev/null \
          | grep -o '"ServiceID"' | wc -l)"
    [ "$n" -ge "$want" ] && return 0
    sleep 1
  done
  return 1
}

# 等后端地址列表被写出来。
# 占位行（127.0.0.1:1 down）不算数——那只是让 nginx -t 别失败，不是真实例。
wait_backend_file() {
  local f="$1" i
  for i in $(seq 1 25); do
    if [ -s "$f" ] && grep 'server ' "$f" 2>/dev/null | grep -qv '127\.0\.0\.1:1 down'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ---------- nginx 配置文件的自动补齐 ----------
# 规则：目标目录里缺哪个补哪个，已存在的一律不动（尊重手工调整）。

# 从注册中心读当前 passing 实例，输出 nginx 的 server 行。拿不到返回非 0。
render_servers_from_registry() {
  local json
  command -v curl >/dev/null 2>&1 || return 1
  json="$(curl -fsS --max-time 5 \
        "$REGISTRY/v1/health/service/$SERVICE_NAME?passing=1" 2>/dev/null)" || return 1
  [ -n "$json" ] && [ "$json" != "[]" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '
      .[] | .Service as $s
      | (if ($s.Address // "") == "" then .Node.Address else $s.Address end) as $a
      | "  server \($a):\($s.Port) max_fails=2 fail_timeout=2s;"
    ' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for e in d:
    s = e.get("Service") or {}
    a = s.get("Address") or (e.get("Node") or {}).get("Address") or ""
    p = s.get("Port")
    if a and p:
        print("  server %s:%s max_fails=2 fail_timeout=2s;" % (a, p))
' 2>/dev/null
  else
    return 1
  fi
}

# 生成 backends.conf（只在该文件不存在时调用）
generate_backends_conf() {
  local dir="$1" body
  mkdir -p "$dir"
  body="$(render_servers_from_registry || true)"
  {
    printf '# 由 deploy.sh 自动生成（%s），供 nginx 的 upstream 使用。\n' "$(date '+%F %T')"
    printf '# generator 容器（consul-template）启动后会接管并持续重写这个文件。\n'
    printf 'upstream %s {\n' "$SERVICE_NAME"
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    else
      printf '  server 127.0.0.1:1 down;   # 占位：暂无业务实例报到。down 表示不接流量，只保证 nginx -t 通过\n'
    fi
    printf '}\n'
  } > "$dir/backends.conf"
  chmod 644 "$dir/backends.conf"
}

# 生成 consul-demo.conf（只在该文件不存在时调用），端口与服务名取自 config.ini
generate_site_conf() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/consul-demo.conf" <<EOF
# 由 deploy.sh 自动生成（$(date '+%F %T')）。
# 内容按 config.ini 的 SITE_PORT / SERVICE_NAME 渲染。
# 改过这两项：删掉本文件重跑 ./deploy.sh gateway 会重新生成。
# 手工调整过本文件：脚本只在文件不存在时生成，不会覆盖。
server {
    listen      $SITE_PORT;
    server_name _;

    location /api/demo/ {
        # 末尾的 / 会去掉 /api/demo/ 这一段：后端收到的是 /v1/xxx
        proxy_pass http://$SERVICE_NAME/;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    }
}
EOF
  chmod 644 "$dir/consul-demo.conf"
}

# 目标目录里缺哪个补哪个
ensure_nginx_files() {
  local dir="${1:-$NGINX_CONF_DIR}"
  mkdir -p "$dir"

  if [ -f "$dir/consul-demo.conf" ]; then
    say "    站点配置    已存在，不改   $dir/consul-demo.conf"
  else
    generate_site_conf "$dir"
    say "    站点配置    已生成       $dir/consul-demo.conf（listen $SITE_PORT → $SERVICE_NAME）"
  fi

  if [ -f "$dir/backends.conf" ]; then
    say "    后端地址表  已存在，不改   $dir/backends.conf"
  else
    generate_backends_conf "$dir"
    if grep -q '127\.0\.0\.1:1 down' "$dir/backends.conf" 2>/dev/null; then
      say "    后端地址表  已生成（占位） $dir/backends.conf"
      say "                还没有业务实例报到，先放一条 down 的占位，保证 nginx -t 不失败"
    else
      say "    后端地址表  已生成       $dir/backends.conf（取自注册中心）"
    fi
  fi
}

# ---------- 让 nginx 真正生效 ----------
# 边界（2026-10-21 明确）：不动 nginx.conf 和它本身的文件，但允许把生成的配置
# 放进它的 include 目录并让它生效。所以这里会：先 nginx -t，通过后——
# 在跑就 reload，没在跑就启动。只用 nginx 自己的命令，不写 /etc/nginx/**，
# 不装 systemd 单元。
#
# 为什么要有「没跑就启动」这一支：nginx -t 是纯语法检查，永远能通过；
# 但 nginx -s reload 需要读 pid 文件，没在跑时报
#   invalid PID number "" in "/run/nginx.pid"
# 这个错看起来像配置问题，其实是服务根本没启动。

nginx_pid_file() {
  local p
  p="$(nginx -V 2>&1 | tr ' ' '\n' | sed -n 's/^--pid-path=//p' | head -1)"
  [ -n "$p" ] || p="/run/nginx.pid"
  printf '%s\n' "$p"
}

# 只有 pid 文件有效、且那个进程还活着，才算 nginx 在跑
nginx_master_pid() {
  local f pid
  f="$(nginx_pid_file)"
  [ -r "$f" ] || return 1
  pid="$(tr -cd '0-9' < "$f" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

nginx_running() { nginx_master_pid >/dev/null 2>&1; }

# nginx -t 通过才动它；不通过就保持原样并打印原因，绝不把线上打挂
nginx_apply() {
  local out pid

  if ! nginx_installed; then
    say "    nginx 未安装，跳过（配置已写到 $NGINX_CONF_DIR，装上后重跑本命令即可）"
    return 0
  fi

  if ! out="$(nginx -t 2>&1)"; then
    say "    [失败] nginx -t 不通过，没有 reload（线上保持原样）："
    printf '%s\n' "$out" | sed 's/^/      /'
    return 1
  fi

  if nginx_running; then
    pid="$(nginx_master_pid)"
    if out="$(nginx -s reload 2>&1)"; then
      say "    nginx 已 reload（master pid $pid）"
    else
      say "    [失败] nginx -s reload："
      printf '%s\n' "$out" | sed 's/^/      /'
      return 1
    fi
    return 0
  fi

  say "    nginx 当前没有运行，启动它"
  if command -v systemctl >/dev/null 2>&1 \
     && systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
    systemctl start nginx >/dev/null 2>&1 || true
  else
    nginx >/dev/null 2>&1 || true
  fi

  if nginx_running; then
    say "    nginx 已启动（master pid $(nginx_master_pid)）"
    return 0
  fi

  say "    [失败] nginx 没起来。配置已经就位，修好后重跑本命令即可。"
  return 1
}

# 注：这里不再有「业务机上顺便 reload nginx」的函数。
# 节点增删的生效责任只有一个：网关那台的 generator 写完地址表就自己发 HUP
# （roles/gateway/reload-nginx.sh）。业务机不需要知道 nginx 的存在。
