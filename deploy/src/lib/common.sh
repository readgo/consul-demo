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

# 等后端地址列表被写出来
wait_backend_file() {
  local f="$1" i
  for i in $(seq 1 25); do
    [ -s "$f" ] && grep -q 'server ' "$f" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}
