#!/usr/bin/env bash
# ============================================================
#  构建应用镜像，导出到 deploy/src/image/consul-demo-image.tar.gz
#
#    ./build-image.sh
#
#  一般不用单独跑：./pack.sh 不带参数时会自动先调它。
#  服务器上不用跑这个，deploy.sh 只做导入。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/../.."        # 项目根

OUT=deploy/src/image
mkdir -p "$OUT"

# Dockerfile 和本脚本同属 deploy/build/，构建上下文必须是项目根
docker build -f deploy/build/Dockerfile -t consul-demo:local .
docker save consul-demo:local | gzip -1 > "$OUT/consul-demo-image.tar.gz"
ls -lh "$OUT/consul-demo-image.tar.gz"
