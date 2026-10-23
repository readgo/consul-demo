#!/usr/bin/env bash
# ============================================================
#  lib.sh —— install-single.sh / scale-out.sh 共用函数
#
#  这里只放「生成 upstream」这一件事。做法是把 upstream 单独写进
#  /etc/nginx/conf.d/00-upstream-consul-demo.conf，
#  和 server 段的 consul-demo.conf 分开。
#
#  为什么不合并成一个文件：
#    扩容时只需要重写 upstream 这一小段，server 段（location、超时、
#    重试策略）一个字都不用动，也就不会因为改错一段把整站弄挂。
#
#  为什么文件名带 00- 前缀：
#    conf.d/*.conf 按字典序加载，upstream 先定义、server 后引用，读配置
#    时不会因为顺序导致「upstream 未定义」的困惑（nginx 本身两阶段解析
#    允许反序，但先定义更便于人排查）。
# ============================================================

UPSTREAM_FILE=/etc/nginx/conf.d/00-upstream-consul-demo.conf

# has_local_ip <ip>：本机是否绑定了该地址
#
# 用 awk 而不是 `ip addr | grep -q`：脚本开了 pipefail，grep -q 一旦命中
# 就立刻退出，上游 ip 命令还在写就会被 SIGPIPE 打断，整条管道返回 141，
# 于是「有这个 IP」被误判成「没有」。这个坑在 k3d/deploy.sh 里踩过一次。
has_local_ip() {
  ip -4 addr show 2>/dev/null \
    | awk -v ip="$1" '$2 ~ "^"ip"/" {f=1} END{exit !f}'
}

# gen_upstream <ip> [ip...]
# 生成 upstream 块并写入 UPSTREAM_FILE（调用方负责 reload）
gen_upstream() {
  if [ "$#" -lt 1 ]; then
    echo "gen_upstream: 至少需要一个节点 IP" >&2
    return 1
  fi

  {
    echo "# 由 k3s-single 脚本生成，不要手改 —— 改了下次 scale-out 会被覆盖"
    echo "# 生成时间：$(date '+%F %T')"
    echo "upstream consul_demo {"
    for ip in "$@"; do
      # max_fails=1 fail_timeout=2s：节点整机消失时，第一个失败请求后
      # 立刻摘除，2 秒后重新试探。这跟 k8s 那 40 秒的
      # node-monitor-grace-period 是两条独立路径，不用等 k8s 摘 Endpoints。
      echo "    server ${ip}:${NODE_PORT} max_fails=1 fail_timeout=2s;"
    done
    echo "    keepalive 32;"
    echo "}"
  } >"$UPSTREAM_FILE"

  echo "已生成 $UPSTREAM_FILE："
  sed 's/^/    /' "$UPSTREAM_FILE"
}

# reload_nginx：语法检查通过才 reload，失败则不动线上
reload_nginx() {
  if ! nginx -t 2>&1 | sed 's/^/    /'; then
    echo "nginx 配置有语法错误，已放弃 reload，线上仍是旧配置" >&2
    return 1
  fi
  systemctl reload nginx
  echo "nginx 已平滑 reload（存量连接不中断）"
}
