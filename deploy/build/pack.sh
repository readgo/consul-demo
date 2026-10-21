#!/usr/bin/env bash
# ============================================================
#  构建脚本：把 deploy/src 里的运行件，按白名单产出一份干净的
#  服务端交付目录 deploy/server。
#
#    ./pack.sh                 先打应用镜像，再产出交付目录（最常用）
#    ./pack.sh --no-build      跳过打镜像，直接用现成的镜像包
#    ./pack.sh --build-only    只打应用镜像，不产出交付目录
#
#  本目录（deploy/build）只有脚本，不放任何运行件。
#  deploy/server 才是要拖到服务器上的东西。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"              # deploy/build

SRC="../src"
OUT="../server"
IMAGE="$SRC/image/consul-demo-image.tar.gz"

# ---------- 参数 ----------
DO_BUILD=1
DO_PACK=1
for arg in "$@"; do
  case "$arg" in
    --no-build)   DO_BUILD=0 ;;
    --build-only) DO_PACK=0 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "[错误] 不认识的参数：$arg" >&2
      echo "        可用：--no-build | --build-only | --help" >&2
      exit 1 ;;
  esac
done

[ -d "$SRC" ] || { echo "[错误] 找不到源目录：$(cd "$SRC" 2>/dev/null && pwd || echo "$SRC")" >&2; exit 1; }

# ---------- 第一步：打应用镜像 ----------
if [ "$DO_BUILD" = 1 ]; then
  echo "==== 1/2 打应用镜像 ===="
  bash ./build-image.sh
  echo
fi

[ "$DO_PACK" = 1 ] || { echo "只打镜像，没产出交付目录（--build-only）。"; exit 0; }

# ---------- 第二步：产出交付目录 ----------
echo "==== 2/2 产出交付目录 ===="

# 白名单：只有这些会进交付目录
# 注意：交付包里放的是 config.ini.example 模板，不放 config.ini。
# 服务器上第一次执行 deploy.sh 时会自动从模板生成 config.ini。
FILES=(
  deploy.sh
  config.ini.example
  lib/common.sh
  roles/center/run.sh
  roles/center/compose.yaml
  roles/gateway/run.sh
  roles/gateway/compose.yaml
  roles/gateway/site.conf
  roles/gateway/backends.ctmpl
  roles/service/run.sh
  roles/service/compose.yaml
)

# 空目录（运行时往里写东西）
DIRS=(
  roles/center/data/center
  roles/gateway/conf.d
)

echo "源目录：  $(cd "$SRC" && pwd)"
echo "交付目录：$(cd "$OUT" 2>/dev/null && pwd || echo "$OUT")"

# ---------- 清空交付目录，保留手写的 README.md ----------
mkdir -p "$OUT"
find "$OUT" -mindepth 1 -maxdepth 1 ! -name 'README.md' -exec rm -rf {} +

# ---------- 拷白名单 ----------
missing=0
for f in "${FILES[@]}"; do
  if [ -f "$SRC/$f" ]; then
    mkdir -p "$OUT/$(dirname "$f")"
    cp -p "$SRC/$f" "$OUT/$f"
  else
    echo "  [缺失] $f" >&2
    missing=1
  fi
done
[ "$missing" = 0 ] || { echo "[错误] 有必需文件缺失，产出中止" >&2; exit 1; }

# ---------- 交付包里不该出现的东西 ----------
# config.ini 是本地实跑时的配置，含本机地址，属于开发侧产物。
# 万一被谁手工塞进 src 目录，这里直接拦下来，别带着上服务器。
if [ -e "$OUT/config.ini" ]; then
  echo "[错误] 交付目录里出现了 config.ini，它不该上服务器" >&2
  echo "        交付包只带 config.ini.example，服务器上第一次运行会自动生成 config.ini" >&2
  exit 1
fi

for d in "${DIRS[@]}"; do
  mkdir -p "$OUT/$d"
done

# ---------- 应用镜像（业务机要用） ----------
if [ -f "$IMAGE" ]; then
  mkdir -p "$OUT/image"
  cp -p "$IMAGE" "$OUT/image/"
else
  echo "  [错误] 没有 $IMAGE" >&2
  echo "         这份交付目录拿到服务器上也装不了应用。先不带 --no-build 跑一次。" >&2
  exit 1
fi

# ---------- 版本戳 ----------
{
  echo "打包时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo
  echo "内容清单："
  ( cd "$OUT" && find . -type f | sort | sed 's/^/  /' )
} > "$OUT/VERSION.txt"

echo
echo "完成。交付目录里只有这些："
( cd "$OUT" && find . -type f | sort | sed 's/^/  /' )
echo
echo "下一步：用 WindTerm / scp 把整个 server 目录拖到服务器，"
echo "        服务器上建议改名为 ~/deploy-consul-demo"
