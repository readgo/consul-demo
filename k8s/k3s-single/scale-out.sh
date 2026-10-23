#!/usr/bin/env bash
# ============================================================
#  scale-out.sh —— 阶段三：把流量和副本收敛到新节点
#
#  执行位置：只在 node1 执行（kubectl 面向整个集群，跑一次就够）
#  前提：新节点已用 join-server.sh 加入，且 kubectl get nodes 全部 Ready
#
#  用法：
#    ./scale-out.sh            # 自动判断要不要重分布，幂等
#    ./scale-out.sh --force    # 强制重建 Pod，即使分布已经均衡
#    ./scale-out.sh --dry-run  # 只打印计划
#
#  它做三件事，顺序不能反：
#    1) 先让 Pod 分布到所有 Ready 节点（rollout restart）
#    2) 再把「有副本的节点」写进 nginx upstream
#    3) nginx -t 通过后 reload
#
#  节点清单从 kubectl get nodes 动态取，不读 cluster.env：
#    集群成员本来就在 etcd 里，加第 4、5、10 台时不需要改任何配置。
#
#  为什么必须是「先分布、后加 upstream」：
#    Service 是 externalTrafficPolicy: Local —— 节点的 NodePort 只转发给
#    本机的 Pod。新节点上还没有 Pod 时，它的 30080 会直接 REJECT。
#    如果先把 node2/node3 加进 upstream，每个请求都要先打到一个必失败的
#    地址再重试，这段时间会持续到新 Pod 调度上去为止。
#    反过来做：nginx 先只认 node1，而 node1 上有副本（maxUnavailable: 0
#    保证任何时刻都不会把它删空），流量始终有落脚点。
#
#  为什么 rollout restart 不会中断：
#    和普通发版走的是同一条 RollingUpdate 路径，maxUnavailable: 0 +
#    readinessProbe + preStop sleep 5，新 Pod 就绪后才删旧 Pod。
# ============================================================
set -euo pipefail

SD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cluster.env
. "$SD/cluster.env"
# shellcheck source=lib.sh
. "$SD/lib.sh"

FORCE=0
DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) awk 'NR>2{ if (/^# =+$/) exit; print }' "$0"; exit 0 ;;
    *) echo "未知参数：$a（--help 查看用法）" >&2; exit 1 ;;
  esac
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_E=$'\e[0m'
step() { printf '\n%s[%s]%s %s\n' "$C_B" "$1" "$C_E" "$2"; }
info() { printf '      %s\n' "$*"; }
ok()   { printf '      %s✓ %s%s\n' "$C_G" "$*" "$C_E"; }
warn() { printf '      %s! %s%s\n' "$C_Y" "$*" "$C_E"; }
die()  { printf '%s✗ %s%s\n' "$C_R" "$*" "$C_E" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = "1" ]; then printf '      （dry-run）%s\n' "$*"; else "$@"; fi; }

if command -v kubectl >/dev/null 2>&1; then
  KCTL=(kubectl)
else
  KCTL=(k3s kubectl)
fi
K() { "${KCTL[@]}" "$@"; }

# 节点是否 Ready（按 INTERNAL-IP 匹配，节点名通常是主机名，不能直接比 IP）
node_ready() {
  K get nodes -o wide --no-headers 2>/dev/null \
    | awk -v ip="$1" '$6==ip && $2=="Ready"{f=1} END{exit !f}'
}

# 某节点上的「就绪且未在终止」Pod 数
# 注意：kubectl get pods -o wide 的 NODE 列是节点名（主机名），不是 IP，
# 所以必须先做一次 IP → 节点名 的映射（NODE_NAME，在 step 1 里构建）。
pods_on() {
  local ip="$1" name="${NODE_NAME[$1]:-}"
  if [ -z "$name" ]; then
    echo 0
    return
  fi
  K -n "$NS" get pods -l "app=$DEPLOY" -o wide --no-headers 2>/dev/null \
    | awk -v n="$name" '$7==n && $3=="Running" && $2 ~ /^1\//{c++} END{print c+0}'
}

# ---------------------------------------------------------------
step 1/4 "检查节点状态"
# 不用 `mapfile < <(...)`：进程替换依赖 /dev/fd，在部分受限环境（容器、
# 加固过的 shell）下不可用，会报 "/dev/fd/63: No such file or directory"。
ALL_READY=()
_node_lines=$(K get nodes -o wide --no-headers 2>/dev/null | awk '$2=="Ready"{print $6}')
if [ -n "$_node_lines" ]; then
  while IFS= read -r _ip; do ALL_READY+=("$_ip"); done <<<"$_node_lines"
fi
if [ "${#ALL_READY[@]}" -eq 0 ]; then
  die "没有任何 Ready 节点，或连不上集群。检查：kubectl get nodes"
fi

# IP → 节点名 映射。pods_on 要用节点名去匹配 Pod 的 NODE 列。
declare -A NODE_NAME=()
_name_lines=$(K get nodes -o wide --no-headers 2>/dev/null \
  | awk '$2=="Ready"{print $6"\t"$1}')
if [ -n "$_name_lines" ]; then
  while IFS=$'\t' read -r _ip _name; do
    [ -n "${_ip:-}" ] && NODE_NAME["$_ip"]="$_name"
  done <<<"$_name_lines"
fi

info "集群内 Ready 节点（${#ALL_READY[@]} 个）："
K get nodes -o wide --no-headers 2>/dev/null \
  | awk '{printf "      %-24s %-8s %s\n", $1, $2, $6}'

UNREADY=0
# 遍历「集群里实际 Ready 的节点」，不是 cluster.env 里写死的清单。
# 写死清单的话，第 4 台之后加进来的节点不会被写进 upstream，
# 而且不报错——流量永远绕过它，属于最难查的那种漏配。
for ip in "${ALL_READY[@]}"; do
  if node_ready "$ip"; then
    printf '      %s✓%s %s\n' "$C_G" "$C_E" "$ip"
  else
    printf '      %s-%s %s（未 Ready，将跳过）\n' "$C_Y" "$C_E" "$ip"
    UNREADY=$((UNREADY + 1))
  fi
done
[ "$UNREADY" -eq "${#ALL_READY[@]}" ] && die "没有可用节点，检查：kubectl get nodes"

# 副本数少于节点数时，多出来的节点不会有 Pod，按 Local 规则它们的
# NodePort 会直接 REJECT，因此不会进 upstream——这是对的，但要让人知道
# 「加了机器没加副本 = 白加」，并给出该敲的命令。
if [ "${REPLICAS:-0}" -gt 0 ] && [ "${REPLICAS}" -lt "${#ALL_READY[@]}" ]; then
  warn "副本数 $REPLICAS < 节点数 ${#ALL_READY[@]}：只有 $REPLICAS 台会承载流量"
  info "要扩副本：kubectl -n $NS scale deploy/$DEPLOY --replicas=${#ALL_READY[@]}"
fi

# ---------------------------------------------------------------
step 2/4 "检查 Pod 分布"
dist_now() {
  local out
  out=$(K -n "$NS" get pods -l "app=$DEPLOY" -o wide --no-headers 2>/dev/null \
        | awk '{c[$7]++} END{for(n in c) printf "      %-24s %d\n", n, c[n]}')
  if [ -z "$out" ]; then
    printf '      （没有运行中的 Pod）\n'
  else
    printf '%s\n' "$out"
  fi
}
info "当前："
dist_now

# 「需要重分布」的判据不是「有节点没 Pod」，而是「副本没铺开到应有的节点上」。
# 因为副本数可能小于节点数：10 台机器、replicas=3 时，永远有 7 个节点没 Pod，
# 按「有节点没 Pod 就重启」会把每一次 scale-out 都变成一次无意义的滚动。
#   应铺开的节点数 want = min(REPLICAS, Ready 节点数)
#   实际铺开的节点数 have = 有就绪副本的节点数
#   have < want 或 就绪副本总数 < want  → 才需要重分布
want="${REPLICAS:-0}"
[ "$want" -gt "${#ALL_READY[@]}" ] && want="${#ALL_READY[@]}"

have=0; pods_total=0
for ip in "${ALL_READY[@]}"; do
  c=$(pods_on "$ip")
  pods_total=$((pods_total + c))
  [ "$c" -gt 0 ] && have=$((have + 1))
done

need_spread=0
if [ "$have" -lt "$want" ] || [ "$pods_total" -lt "$want" ]; then
  need_spread=1
fi
[ "$FORCE" = "1" ] && need_spread=1

if [ "$need_spread" = "0" ]; then
  info "副本已铺开到 $have/$want 个节点，分布已均衡，跳过 rollout restart"
else
  info "副本只铺开到 $have/$want 个节点 → 触发一次滚动，让新 ReplicaSet 均匀铺开"
  info "（走 maxUnavailable: 0 的路径，旧 Pod 就绪副本不减少，业务不中断）"
  run K -n "$NS" rollout restart "deploy/$DEPLOY"
  if [ "$DRY_RUN" != "1" ]; then
    K -n "$NS" rollout status "deploy/$DEPLOY" --timeout=300s \
      || die "滚动未完成。看：kubectl -n $NS get pods -o wide"
    info "重分布后："
    dist_now
  fi
fi

# ---------------------------------------------------------------
step 3/4 "生成 nginx upstream"
# 只把「Ready 且至少有一个就绪副本」的节点写进 upstream。
# Local 模式下无 Pod 的节点会直接 REJECT，写进去等于给自己制造失败。
UPSTREAM_IPS=()
for ip in "${ALL_READY[@]}"; do
  node_ready "$ip" || continue
  if [ "$DRY_RUN" = "1" ]; then
    # dry-run 不真的重分布，此时新节点本来就没有副本，硬按「有副本」筛
    # 会把预览结果算成「只剩 node1」，反而误导。这里按「Ready 且预计
    # 重分布后会分到副本」来展示，真跑时仍会逐个校验。
    UPSTREAM_IPS+=("$ip")
    continue
  fi
  c=$(pods_on "$ip")
  if [ "$c" -gt 0 ]; then
    UPSTREAM_IPS+=("$ip")
  else
    warn "$ip 上仍没有就绪副本，暂不加入 upstream"
  fi
done

if [ "${#UPSTREAM_IPS[@]}" -eq 0 ]; then
  die "没有任何节点有就绪副本，拒绝生成空 upstream。检查 Pod 状态：kubectl -n $NS get pods"
fi

if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）将生成 upstream：${UPSTREAM_IPS[*]}"
else
  [ "$(id -u)" = "0" ] || die "写 nginx 配置需要 root，请用 sudo 执行"
  gen_upstream "${UPSTREAM_IPS[@]}"
fi

# ---------------------------------------------------------------
step 4/4 "重载 nginx"
if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）nginx -t && systemctl reload nginx"
else
  reload_nginx
fi

# ---------------------------------------------------------------
printf '\n%s────────────────────────────────────────────────%s\n' "$C_B" "$C_E"
printf '%s阶段三完成：%d 个节点在承载流量%s\n' "$C_G" "${#UPSTREAM_IPS[@]}" "$C_E"
printf '  upstream：%s\n' "${UPSTREAM_IPS[*]}"
printf '\n  验证入口：curl -s http://127.0.0.1:%s/v1/test?name=out-$(date +%%H%%M%%S)\n' "$HTTP_PORT"
printf '  验证分布：kubectl -n %s get pods -o wide\n' "$NS"
printf '\n  下一步：关掉任意一台，验证业务不中断（见 DEPLOY.md 阶段四）\n\n'
