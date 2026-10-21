#!/bin/sh
# generator 重写完 backends.conf 之后被 consul-template 调用：通知宿主机 nginx 平滑重载。
#
# 这个脚本跑在 consul-template 容器里。它不装 nginx、也不负责启动 nginx，只发一个 HUP：
#
#   1) compose 里给了 pid: host —— 共享宿主 pid 命名空间，才看得见宿主的 nginx master
#   2) compose 里给了 CAP_KILL + apparmor=unconfined —— 否则信号会被拦（实测三者缺一不可）
#   3) compose 把宿主 /run 只读挂到 /hostrun —— pid 文件从这里读
#
# nginx 没在跑时直接跳过（exit 0）：首次启动是 deploy.sh gateway 的职责，这里不越权去起它。
# 本脚本必须可执行（git 里带 +x），consul-template 是直接 exec 它，不走 shell 解析。

set -u

PIDFILE="${NGINX_PIDFILE:-/hostrun/nginx.pid}"

pid=""
if [ -r "$PIDFILE" ]; then
  pid="$(tr -cd '0-9' < "$PIDFILE" 2>/dev/null)"
fi

if [ -z "$pid" ]; then
  echo "[reload] 宿主 nginx 没在跑（读不到 $PIDFILE），跳过。要启动它请执行 ./deploy.sh gateway"
  exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
  echo "[reload] pid 文件里的进程 $pid 已不存在，跳过"
  exit 0
fi

if kill -HUP "$pid" 2>/dev/null; then
  echo "[reload] 地址表已更新，已通知 nginx 平滑重载（master pid $pid）"
  exit 0
fi

echo "[reload] 给 nginx 发 HUP 失败（pid $pid）。检查 compose 里的 pid: host / cap_add: KILL / apparmor=unconfined" >&2
exit 1
