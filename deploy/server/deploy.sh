#!/usr/bin/env bash
# ============================================================
#  部署入口。按功能分成三块，想装哪块就装哪块。
#
#    sudo ./deploy.sh center     注册中心   一台机器装一次，之后永远不用管
#    sudo ./deploy.sh gateway    网关       负责接流量的那台机器
#    sudo ./deploy.sh service    业务应用   每台业务机各装一次
#
#    sudo ./deploy.sh all        三块装在同一台（单机演示用）
#    sudo ./deploy.sh status     看当前机器上跑着什么
#
#    ./deploy.sh init            只生成配置文件，不做任何部署
#
#  加机器：新机器拷一份目录 -> 改 config.ini 里的 REGISTRY -> sudo ./deploy.sh service
#          老机器、注册中心、网关都不用改。
#
#  本脚本不碰宿主机 nginx 的任何配置：不写 /etc/nginx/**、不 reload、
#  不装任何 nginx 相关的系统服务。nginx 那边只有两件事，都由人手动做。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/lib/common.sh"

usage() {
  awk 'NR>2 && /^# ====/ {exit} NR>2 && /^#/ {sub(/^# ?/, ""); print}' "$0"
  exit "${1:-0}"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  center)
    exec bash "$ROOT/roles/center/run.sh"
    ;;
  gateway)
    exec bash "$ROOT/roles/gateway/run.sh"
    ;;
  service)
    exec bash "$ROOT/roles/service/run.sh" "${1:-1}"
    ;;
  all)
    say "==== 单机演示：三块装在同一台 ===="
    # 顺序有讲究：先有注册中心，应用才报得了到；先有应用，网关才生得出地址列表
    bash "$ROOT/roles/center/run.sh"
    bash "$ROOT/roles/service/run.sh" 1
    bash "$ROOT/roles/gateway/run.sh"
    ;;
  status)
    show_one() {   # $1=容器名  $2=没装时的提示
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; then
        docker ps -a --filter "name=^${1}$" --format '  {{.Names}}  {{.Status}}'
      else
        say "  $2"
      fi
    }

    say "注册中心"
    show_one consul-demo-center "（本机没装）"

    say "网关"
    show_one consul-demo-generator "（本机没装）"

    say "业务应用"
    # 只认「服务名-纯数字」，避免把注册中心/网关的容器名也算进来
    found=0
    while read -r n; do
      [ -z "$n" ] && continue
      found=1
      docker ps -a --filter "name=^${n}$" --format '  {{.Names}}  {{.Status}}'
    done <<< "$(docker ps -a --format '{{.Names}}' 2>/dev/null \
                  | grep -E "^${SERVICE_NAME}-[0-9]+$" || true)"
    [ "$found" = 0 ] && say "  （本机没装）"

    say ""
    say "注册中心 $REGISTRY 上现在有这些业务机："
    curl -fsS "$REGISTRY/v1/catalog/service/$SERVICE_NAME" 2>/dev/null \
      | grep -oE '"ServiceAddress":"[^"]*"|"ServicePort":[0-9]*' \
      | paste - - | sed 's/"ServiceAddress":"//; s/"ServicePort"://; s/"//g; s/^/  /' \
      || say "  （连不上注册中心）"
    ;;
  init)
    # common.sh 已经自动建过了；这里只是把结果亮给人看，说明下一步做什么
    if [ ! -f "$CONF" ]; then
      say "[错误] 配置文件没生成出来，检查目录写权限"
      exit 1
    fi
    say "配置文件已就绪：$ROOT/$CONF"
    say ""
    grep -vE '^\s*(#|$)' "$CONF" | sed 's/^/  /'
    say ""
    say "要改哪一项就编辑这个文件，然后执行对应的部署命令："
    say "  sudo ./deploy.sh center     装注册中心"
    say "  sudo ./deploy.sh gateway    装网关"
    say "  sudo ./deploy.sh service    装业务应用"
    say "  sudo ./deploy.sh all        三块装同一台"
    ;;
  ''|-h|--help|help)
    usage 0
    ;;
  *)
    say "不认识的命令：$cmd"
    say ""
    usage 1
    ;;
esac
