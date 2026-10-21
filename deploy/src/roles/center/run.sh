#!/usr/bin/env bash
# 角色一：注册中心
#
#   sudo ./deploy.sh center
#
# 只在一台机器上执行一次。装完之后：
#   - 以后加机器、删机器，这台机器什么都不用改
#   - 别的机器只需要在 config.ini 里把 REGISTRY 指向这台机器的内网地址
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

need_root center
need_docker

cd "$ROOT/roles/center"

# 注册中心必须由本机提供，配成远端说明这台上不该装它
if ! registry_is_local; then
  die "本机 config.ini 里 REGISTRY=$REGISTRY 指向了别的机器。
     这台机器不需要装注册中心，直接执行 ./deploy.sh service 即可。"
fi

step "1/3 准备数据目录"
mkdir -p data/center
# 容器里的进程用户和宿主用户对不上，不放开会报 permission denied，注册一律失败
chmod 0777 data/center
say "    data/center 已就绪"

# 本机地址由脚本探测后传进容器：机器多网卡时注册中心不会自己挑，
# 而每台机器 IP 不同，不能写死在文件里
export MY_IP="$(detect_ip)"
say "    本机地址    $MY_IP"

step "2/3 启动注册中心"
docker compose up -d --quiet-pull

step "3/3 等它就绪"
wait_registry || die "注册中心没起来。看日志：docker logs consul-demo-center --tail 40"
say "    已就绪"
cat <<EOF

注册中心装好了，以后不用再碰它。

  管理页面    http://$MY_IP:8500/ui
  访问地址    http://$MY_IP:8500

其它机器要接进来，把它们的 config.ini 改成这一行：

  REGISTRY=http://$MY_IP:8500

然后在那台机器上执行：sudo ./deploy.sh service

EOF
