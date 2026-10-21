#!/usr/bin/env bash
# ============================================================
#  构建入口：打应用镜像 + 校验成品目录。
#
#    ./pack.sh                 先打应用镜像，再校验 ../server（最常用）
#    ./pack.sh --no-build      跳过打镜像，只做校验（应用代码没动时用）
#    ./pack.sh --build-only    只打应用镜像，不校验
#
#  deploy/ 下只有两个目录：
#    build/   本目录，只有构建工具（Dockerfile / build-image.sh / pack.sh）
#    server/  部署件的唯一源 + 产物，整个拖到服务器
#
#  部署脚本没有第二份，改就直接改 ../server 里的。本脚本不复制、不清空
#  任何部署件，只做两件事：打镜像、检查成品是否干净。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"              # deploy/build

OUT="../server"
IMAGE="$OUT/image/consul-demo-image.tar.gz"

# ---------- 参数 ----------
DO_BUILD=1
DO_CHECK=1
for arg in "$@"; do
  case "$arg" in
    --no-build)   DO_BUILD=0 ;;
    --build-only) DO_CHECK=0 ;;
    -h|--help)
      sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "[错误] 不认识的参数：$arg" >&2
      echo "        可用：--no-build | --build-only | --help" >&2
      exit 1 ;;
  esac
done

[ -d "$OUT" ] || { echo "[错误] 找不到成品目录：$(cd "$OUT" 2>/dev/null && pwd || echo "$OUT")" >&2; exit 1; }

# ---------- 第一步：打应用镜像 ----------
if [ "$DO_BUILD" = 1 ]; then
  echo "==== 1/2 打应用镜像 ===="
  bash ./build-image.sh
  echo
fi
[ "$DO_CHECK" = 1 ] || { echo "只打镜像，没校验成品目录（--build-only）。"; exit 0; }

# ---------- 第二步：校验成品目录 ----------
echo "==== 2/2 校验成品目录 ===="
echo "成品目录：$(cd "$OUT" && pwd)"

# 部署件必须齐全。少一个，服务器上装不起来。
REQUIRED=(
  deploy.sh
  config.ini.example
  lib/common.sh
  roles/center/run.sh
  roles/center/compose.yaml
  roles/gateway/run.sh
  roles/gateway/compose.yaml
  roles/gateway/backends.ctmpl
  roles/service/run.sh
  roles/service/compose.yaml
)

missing=0
for f in "${REQUIRED[@]}"; do
  [ -f "$OUT/$f" ] || { echo "  [缺失] $f" >&2; missing=1; }
done
[ "$missing" = 0 ] || { echo "[错误] 成品目录不完整，先补齐上面的文件" >&2; exit 1; }

# 成品目录里不该有自己的构建工具、源码、开发文档。
# 它是唯一源，所以这里只能反向检查：混进来就中止，别带着上服务器。
dirty=0
for f in pack.sh build-image.sh Dockerfile Makefile config.ini; do
  if [ -e "$OUT/$f" ]; then
    echo "  [不该出现] $f" >&2
    dirty=1
  fi
done
# 说明文档只允许 README.md
# 用 here-string 读，不用 <(...)：受限环境里 /dev/fd 可能不可用，会静默跳过检查
bad_md="$( cd "$OUT" && find . -type f -name '*.md' ! -name 'README.md' | sed 's|^\./||' )"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  echo "  [不该出现] $f（成品目录只放 README.md）" >&2
  dirty=1
done <<< "$bad_md"
# 源码与构建配置一律不许出现
bad_src="$( cd "$OUT" && find . -type f \( -name '*.ts' -o -name 'package.json' -o -name 'package-lock.json' -o -name 'tsconfig.json' \) | sed 's|^\./||' )"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  echo "  [不该出现] $f（这是开发件）" >&2
  dirty=1
done <<< "$bad_src"

if [ "$dirty" = 1 ]; then
  echo >&2
  echo "[错误] 成品目录里混进了开发件，中止。" >&2
  echo "        deploy/server 是唯一源，但它同时是要拖到服务器的那一份，" >&2
  echo "        所以里面只能有服务器自己会用的文件。" >&2
  echo "        config.ini 是本机实跑配置：删掉即可，deploy.sh 下次会自动从模板生成。" >&2
  exit 1
fi

# ---------- nginx 站点配置不随包走 ----------
# nginx 配置全项目只有一份：仓库根 nginx/consul-demo.conf。
# 它由人手动复制到宿主机 nginx 的 include 目录（config.ini 里的 NGINX_CONF_DIR），
# 不进交付包 —— 交付目录里出现 nginx/ 反而会让人以为是脚本管这件事。
if [ -e "$OUT/nginx" ]; then
  echo "[错误] 成品目录里出现了 nginx/" >&2
  echo "        nginx 配置不随交付包走：仓库根 nginx/consul-demo.conf 由人手动复制" >&2
  exit 1
fi

# ---------- 运行时目录（空目录，git 不跟踪，每次补一下）----------
mkdir -p "$OUT/roles/center/data/center"

# ---------- 应用镜像 ----------
[ -f "$IMAGE" ] || {
  echo "[错误] 没有 $IMAGE" >&2
  echo "        这份目录拿到服务器上也装不了应用。先不带 --no-build 跑一次。" >&2
  exit 1
}

# ---------- 版本戳 ----------
{
  echo "打包时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo
  echo "内容清单："
  ( cd "$OUT" && find . -type f ! -path './VERSION.txt' | sort | sed 's/^/  /' )
} > "$OUT/VERSION.txt"

echo
echo "校验通过。成品目录里是这些："
( cd "$OUT" && find . -type f | sort | sed 's/^/  /' )
echo
echo "下一步：整个 server 目录拖到服务器（建议改名 ~/deploy-consul-demo），"
echo "        在上面执行 sudo ./deploy.sh <center|gateway|service|all>。"
