#!/usr/bin/env bash
# ============================================================
#  rollout-test.sh —— 阶段一：在单机上验证「零中断滚动更新」
#
#  执行位置：只在 node1 执行
#  用法：
#    sudo ./rollout-test.sh              # 默认：造一个本地新 tag → 真发版 → 断言 0 失败
#    sudo ./rollout-test.sh --restart     # 不换镜像，只 rollout restart（最快，30 秒）
#    sudo ./rollout-test.sh --bad         # 负向：发一个拉不到的镜像，验证「发版失败但线上不受影响」
#    sudo ./rollout-test.sh --dry-run     # 只打印计划
#
#  它自己起观测器（../rollout-watch.sh），所以**不需要开两个窗口**。
#
#  三种模式分别证明什么：
#    --restart  证明「换 Pod 这个动作本身不中断」。走的是和换镜像完全相同的
#               RollingUpdate 路径（maxSurge 1 / maxUnavailable 0 / readinessProbe
#               / preStop sleep 5），差别只是 image 字段没变。
#    默认       证明「换版本不中断」。用 k3s ctr 把现有镜像打一个新 tag，
#               imagePullPolicy: IfNotPresent 下本地已有就不会去 registry 拉，
#               所以不需要联网、不需要 build，30 秒内能反复跑。
#    --bad      证明「坏版本发不出去」。新 Pod 起不来时旧 Pod 一个都不会被删，
#               这是 maxUnavailable: 0 唯一能挡住的事故类型（发一半把线上弄挂）。
#
#  为什么不能只看 kubectl rollout status 成功：
#    它只告诉你「Pod 都就绪了」，不告诉你「这期间有没有请求掉地」。掉 3 个
#    请求它也照样 Success。必须外部持续打压才有结论。
# ============================================================
set -euo pipefail

SD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cluster.env
. "$SD/cluster.env"
# shellcheck source=lib.sh
. "$SD/lib.sh"

MODE=normal
DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --restart) MODE=restart ;;
    --bad)     MODE=bad ;;
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

TS=$(date +%Y%m%d-%H%M%S)
WATCH_PID=''
WATCH_LOG=''

cleanup() {
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill -TERM "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  [ -n "$WATCH_LOG" ] && [ -f "$WATCH_LOG" ] && rm -f "$WATCH_LOG"
}
trap cleanup EXIT

# ---------------------------------------------------------------
step 0/5 "前置检查"

# 只输出纯数字。kubectl 偶发返回空（rollout 刚结束、apiserver 抖动），
# 空值直接拿去 -lt 比较会报 integer expression expected，所以统一清洗。
# tries 次轮询取最后一次非空值，避免把「瞬时读不到」当成「副本为 0」。
ready_replicas() {
  local n='' i
  for i in 1 2 3; do
    n=$(K -n "$NS" get "deploy/$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    n=${n//[!0-9]/}
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }
    sleep 1
  done
  printf '0'
}

# 观测器定位，规则和 install-single.sh 找 app.yml 一致
if [ -z "${WATCH:-}" ]; then
  for _c in "$SD/../rollout-watch.sh" "$SD/rollout-watch.sh" "$SD/../../k8s/rollout-watch.sh"; do
    if [ -f "$_c" ]; then WATCH="$_c"; break; fi
  done
fi
if [ -z "${WATCH:-}" ] || [ ! -f "$WATCH" ]; then
  die "找不到 rollout-watch.sh。已找过：
    $SD/../rollout-watch.sh
    $SD/rollout-watch.sh
    $SD/../../k8s/rollout-watch.sh
  上传仓库里的 k8s/rollout-watch.sh 到 $(dirname "$SD")/rollout-watch.sh，
  或手动指定：sudo WATCH=/path/to/rollout-watch.sh $0"
fi
ok "观测器 $WATCH"

R=$(ready_replicas); R=${R:-0}
if [ "$R" -lt 1 ]; then
  die "deploy/$DEPLOY 没有就绪副本（readyReplicas=$R）。先确认：kubectl -n $NS get pods"
fi
info "就绪副本 $R/$REPLICAS"

# 镜像名从集群里取，不信 cluster.env —— 上一次发版可能已经改过
OLD_IMAGE=$(K -n "$NS" get "deploy/$DEPLOY" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$CONTAINER\")].image}" 2>/dev/null || true)
[ -n "$OLD_IMAGE" ] || die "取不到容器 $CONTAINER 的当前镜像，检查：kubectl -n $NS get deploy/$DEPLOY -o yaml"
info "当前镜像 $OLD_IMAGE"

# 入口必须现在就是通的。不通就别开始——否则后面所有失败都是入口的问题，
# 会被误读成「滚动更新导致中断」。
if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）curl http://127.0.0.1:$HTTP_PORT/v1/test"
else
  _pre=$(curl -sS --noproxy '*' -m 3 "http://127.0.0.1:${HTTP_PORT}/v1/test?name=pre-$TS" 2>&1 || true)
  if [[ "$_pre" != *hello* ]]; then
    die "入口 http://127.0.0.1:$HTTP_PORT 现在就不通（返回：${_pre:0:80}）
  先修好入口再做滚动测试：
    curl -sv http://127.0.0.1:$HTTP_PORT/nginx-health
    kubectl -n $NS get pods -o wide"
  fi
  ok "入口通：${_pre:0:48}"
fi

case "$MODE" in
  restart) info "模式     : --restart（只重建 Pod，换 tag 之外的一切照旧）" ;;
  bad)     info "模式     : --bad（发拉不到的镜像，验证旧版本不被删）" ;;
  *)       info "模式     : 真发版（本地造新 tag，不联网）" ;;
esac
info "观测     : 100ms 一次，跑满整个滚动过程"

# ---------------------------------------------------------------
step 1/5 "准备新版本镜像"
SRC_FULL=''
NEW_REF=''
if [ "$MODE" = "restart" ]; then
  info "跳过（--restart 不改 image）"
elif [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）从 containerd 里解析 $OLD_IMAGE 的全名并打一个新 tag"
  if [ "$MODE" = "bad" ]; then
    info "（dry-run）新 tag 不 import，imagePullPolicy=IfNotPresent → 必然拉取失败"
  fi
else
  # containerd 里存的是全名（docker.io/wttcvs/consul-demo:tag），
  # 用后缀匹配把用户眼里的短名还原成全名，避免 ctr tag 找不到源。
  SRC_FULL=$(k3s ctr -n k8s.io images list -q 2>/dev/null \
    | awk -v s="$OLD_IMAGE" 'length($0)>=length(s) && substr($0, length($0)-length(s)+1)==s {print; exit}' || true)
  if [ -z "$SRC_FULL" ]; then
    warn "containerd 里没找到 $OLD_IMAGE —— 无法在本地造 tag"
    info "可用镜像（前 10 个）："
    k3s ctr -n k8s.io images list -q 2>/dev/null | head -10 | sed 's/^/        /'
    die "改用不发镜像的模式：sudo $0 --restart"
  fi
  ok "本地镜像 $SRC_FULL"

  if [ "$MODE" = "bad" ]; then
    NEW_REF="${SRC_FULL%:*}:vbad-$TS"
    info "目标 $NEW_REF（不 import，必然拉不到）"
  else
    NEW_REF="${SRC_FULL%:*}:vtest-$TS"
    if [ "$(id -u)" = "0" ]; then
      k3s ctr -n k8s.io images tag "$SRC_FULL" "$NEW_REF" \
        || die "打 tag 失败：$SRC_FULL → $NEW_REF"
    else
      die "打 tag 需要 root，请用 sudo 执行"
    fi
    # 确认 tag 真的进去了：ctr 的 tag 在部分版本上会静默失败
    k3s ctr -n k8s.io images list -q 2>/dev/null \
      | awk -v t="$NEW_REF" 'index($0,t){f=1} END{exit !f}' \
      || die "tag 后仍查不到 $NEW_REF，containerd 拒绝了这次操作"
    ok "已打 tag $NEW_REF（本地已有层，发版不需要联网）"
  fi
fi

# ---------------------------------------------------------------
step 2/5 "起观测器"
if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）后台起 URL=http://127.0.0.1:$HTTP_PORT/v1/test?name=rt-{TS} EXPECT=hello 的采样"
else
  WATCH_LOG=$(mktemp "/tmp/rollout-test-XXXXXX.log")
  # EXPECT 必须显式给 hello：rollout-watch.sh 默认期望响应体含 'jing'，
  # 我们的 name 是 rt-<时间戳>，不覆盖会让每一次请求都被判成失败。
  # QUIET_OK=1 让成功行只落日志不上屏，失败行仍然实时打出来。
  URL="http://127.0.0.1:${HTTP_PORT}/v1/test?name=rt-{TS}" \
  EXPECT=hello INTERVAL_MS=100 DURATION_SEC=0 TIMEOUT=3 QUIET_OK=1 \
    "$WATCH" >"$WATCH_LOG" 2>&1 &
  WATCH_PID=$!
  sleep 2
  kill -0 "$WATCH_PID" 2>/dev/null || {
    printf '\n'
    sed 's/^/      /' "$WATCH_LOG"
    die "观测器起来就退出了，看上面的报错"
  }
  ok "观测器已在后台采样（pid $WATCH_PID）"
fi

# ---------------------------------------------------------------
step 3/5 "触发滚动更新"
if [ "$DRY_RUN" = "1" ]; then
  case "$MODE" in
    restart) info "（dry-run）kubectl -n $NS rollout restart deploy/$DEPLOY" ;;
    *)       info "（dry-run）kubectl -n $NS set image deploy/$DEPLOY $CONTAINER=$NEW_REF" ;;
  esac
else
  case "$MODE" in
    restart)
      run K -n "$NS" rollout restart "deploy/$DEPLOY"
      ;;
    *)
      # 新 Pod 起不来时 kubectl 会 block 到超时，用 timeout 兜一层，
      # 免得 --bad 模式下脚本看起来像卡死。
      run K -n "$NS" set image "deploy/$DEPLOY" "$CONTAINER=$NEW_REF"
      ;;
  esac
  ok "已下发"
fi

# ---------------------------------------------------------------
step 4/5 "等待滚动结果"
ROLL_RC=0
if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）kubectl rollout status --timeout=180s"
else
  case "$MODE" in
    bad)
      # 期望它失败：新镜像拉不到，rollout 会一直等到超时。
      info "预期：新 Pod 卡在 ImagePullBackOff，旧 Pod 全部继续服务"
      if K -n "$NS" rollout status "deploy/$DEPLOY" --timeout=40s; then
        warn "意外：坏镜像竟然滚完了。看 kubectl -n $NS get pods -o wide"
        ROLL_RC=0
      else
        ROLL_RC=1
      fi
      ;;
    *)
      if K -n "$NS" rollout status "deploy/$DEPLOY" --timeout=180s; then
        ROLL_RC=0
      else
        ROLL_RC=1
      fi
      ;;
  esac
  printf '\n'
  K -n "$NS" get pods -o wide --no-headers 2>/dev/null | sed 's/^/      /' || true
fi

# ---------------------------------------------------------------
step 5/5 "停采样并出结论"
if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）kill -TERM 观测器，解析汇总里的「失败」计数"
  printf '\n%sdry-run 结束，未对系统做任何修改%s\n\n' "$C_Y" "$C_E"
  exit 0
fi

# 必须是 TERM 不是 INT：脚本里 `cmd &` 起的后台作业默认继承 SIG_IGN，
# 对它们 kill -INT 会被忽略，进程赖着不走、汇总永远不出。
kill -TERM "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=''

FAIL_CNT=$(awk '/^失败/{ if (match($0,/[0-9]+/)) { print substr($0,RSTART,RLENGTH); exit } }' "$WATCH_LOG")
TOTAL_CNT=$(awk '/^总请求/{ if (match($0,/[0-9]+/)) { print substr($0,RSTART,RLENGTH); exit } }' "$WATCH_LOG")

printf '\n'
if [ -z "${TOTAL_CNT:-}" ] || [ "${TOTAL_CNT:-0}" -lt 10 ]; then
  info "观测器汇总（没解析到有效计数，原文照贴）："
  tail -40 "$WATCH_LOG" | sed 's/^/      /'
  die "采样没跑起来（总请求=${TOTAL_CNT:-?}）。上面是观测器原话"
fi

info "总请求 $TOTAL_CNT 次，失败 ${FAIL_CNT:-?} 次"
if [ -n "${FAIL_CNT:-}" ] && [ "$FAIL_CNT" -gt 0 ]; then
  info "失败明细（最多 10 条）："
  awk '/FAIL/{print; c++} c>=10{exit}' "$WATCH_LOG" | sed 's/^/      /'
fi

READY_NOW=$(ready_replicas); READY_NOW=${READY_NOW:-0}

printf '\n%s────────────────────────────────────────────────%s\n' "$C_B" "$C_E"

PASS=1
case "$MODE" in
  bad)
    # --bad 的判据有两条：旧版本一个不少 + 外部请求 0 失败。
    if [ "${FAIL_CNT:-1}" -ne 0 ]; then
      printf '%s✗ 未通过%s：坏版本发版期间有 %s 次请求失败\n' "$C_R" "$C_E" "$FAIL_CNT"
      PASS=0
    elif [ "$READY_NOW" -lt "$REPLICAS" ]; then
      printf '%s✗ 未通过%s：坏版本把可用副本吃到了 %s/%s（maxUnavailable: 0 没生效）\n' \
        "$C_R" "$C_E" "$READY_NOW" "$REPLICAS"
      PASS=0
    else
      printf '%s✓ 通过%s：坏版本卡在拉镜像，线上 %s/%s 副本照常服务，%s 次请求 0 失败\n' \
        "$C_G" "$C_E" "$READY_NOW" "$REPLICAS" "$TOTAL_CNT"
    fi
    info "回滚到发版前的镜像…"
    K -n "$NS" set image "deploy/$DEPLOY" "$CONTAINER=$OLD_IMAGE" >/dev/null
    K -n "$NS" rollout status "deploy/$DEPLOY" --timeout=180s >/dev/null 2>&1 \
      && ok "已回滚到 $OLD_IMAGE" \
      || warn "回滚未在 180s 内完成，手动确认：kubectl -n $NS get pods -o wide"
    ;;
  *)
    if [ "$ROLL_RC" -ne 0 ]; then
      printf '%s✗ 未通过%s：滚动本身就没跑完\n' "$C_R" "$C_E"
      PASS=0
    elif [ "${FAIL_CNT:-1}" -ne 0 ]; then
      printf '%s✗ 未通过%s：滚动成功但期间有 %s 次请求失败 —— 存在不可用窗口\n' \
        "$C_R" "$C_E" "$FAIL_CNT"
      PASS=0
    else
      printf '%s✓ 通过%s：%s 次请求全部 200，滚动更新期间服务无中断\n' \
        "$C_G" "$C_E" "$TOTAL_CNT"
    fi
    ;;
esac

if [ "$MODE" != "bad" ] && [ "$MODE" != "restart" ] && [ -n "$NEW_REF" ]; then
  printf '\n  当前镜像是测试 tag：%s\n' "$NEW_REF"
  printf '  它是本地 ctr tag，不在任何 registry 上——别拿它当正式版本。\n'
  printf '  恢复原镜像：sudo kubectl -n %s set image deploy/%s %s=%s\n' \
    "$NS" "$DEPLOY" "$CONTAINER" "$OLD_IMAGE"
  printf '  （app.yml 里的 image 没动，下次 apply 会自动退回原镜像）\n'
fi

printf '\n  看分布：kubectl -n %s get pods -o wide\n' "$NS"
printf '  复跑三种模式：sudo %s / --restart / --bad\n\n' "$0"

[ "$PASS" = "1" ] || exit 1
