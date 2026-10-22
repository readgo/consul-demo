#!/usr/bin/env bash
# rollout-watch.sh —— 滚动更新「零中断」验证器
#
# 每 INTERVAL_MS 毫秒打一次请求，逐条记录时间戳 / 状态码 / 耗时 / 响应体，
# 并把连续失败聚合成「中断区间」，滚动更新跑完后看汇总就能判断有没有掉服务。
#
# 用法：
#   ./rollout-watch.sh                          # 默认 http://localhost:30080/v1/test?name=jing，100ms 一次，跑到 Ctrl+C
#   DURATION_SEC=60 ./rollout-watch.sh          # 跑 60 秒自动停并出汇总
#   INTERVAL_MS=50 ./rollout-watch.sh           # 改成 50ms 一次
#   URL=http://10.0.3.9:30080/v1/test?name=jing ./rollout-watch.sh
#   EXPECT=hello ./rollout-watch.sh             # 校验响应体必须含这个子串（默认 jing）
#
# 典型用法：窗口 A 起脚本 → 窗口 B 执行 kubectl set image / rollout restart → 脚本汇总看中断段。
set -uo pipefail

URL="${URL:-http://localhost:30080/v1/test?name=jing}"
INTERVAL_MS="${INTERVAL_MS:-100}"
DURATION_SEC="${DURATION_SEC:-0}"      # 0 = 一直跑，Ctrl+C 结束
EXPECT="${EXPECT:-jing}"               # 响应体必须包含的子串，空串则只校验 HTTP 200
TIMEOUT="${TIMEOUT:-3}"                # 单次请求超时（秒）
QUIET_OK="${QUIET_OK:-0}"              # 1 = 只打印失败行，成功行不刷屏
LOG="${LOG:-/tmp/rollout-watch-$(printf '%(%Y%m%d-%H%M%S)T' -1).log}"

if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_GRN=$'\e[32m'; C_DIM=$'\e[2m'; C_END=$'\e[0m'
else
  C_RED=; C_YEL=; C_GRN=; C_DIM=; C_END=
fi

# ---------- 计时工具（用 bash 内建 EPOCHREALTIME，避免每轮 fork date） ----------
now_ms()   { local t="${EPOCHREALTIME/./}"; printf '%d' $(( t / 1000 )); }
stamp()    { local e="${EPOCHREALTIME}"; printf '%(%F %T)T.%03d' "${e%.*}" "$(( 10#${e#*.} / 1000 ))"; }
hms2()     { printf '%(%H:%M:%S)T.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"; }
fmt_ms()   { awk -v x="$1" 'BEGIN{printf "%d", x*1000+0.5}'; }
fmt_sec()  { awk -v x="$1" 'BEGIN{printf "%.1f", x/1000}'; }
fmt_pct()  { awk -v a="$1" -v b="$2" 'BEGIN{ if(b==0) printf "0.00"; else printf "%.2f", a*100/b }'; }

# ---------- 输出 ----------
say()  { printf '%s\n' "$*" >>"$LOG"; }                 # 只落日志
show() { printf '%s\n' "$*"; say "$*"; }                # 上屏 + 落日志

# ---------- 状态 ----------
total=0; ok=0; fail=0
sum_ms=0; max_ms=0
in_seg=0
seg_start_abs=0; seg_cnt=0; seg_reason=''
segments=()                            # 已闭合的中断区间描述
SUMMARY_RC=0

TMPB=$(mktemp); ERRF=$(mktemp)
cleanup() { rm -f "$TMPB" "$ERRF"; }
trap cleanup EXIT

log_both() { printf '%s\n' "$*"; printf '%s\n' "$*" >>"$LOG"; }

summary() {
  local end_ms dur fail_rate verdict i s
  end_ms=$(now_ms); dur=$(( end_ms - T0 ))

  # Ctrl+C 收尾时若仍在失败段里，也要把它算进去
  if [ "$in_seg" -eq 1 ]; then
    segments+=("$(hms2 $(( seg_start_abs ))) → 结束时仍在中断  持续 $(fmt_sec $(( end_ms - seg_start_abs )))s  连续失败 ${seg_cnt} 次  ${seg_reason}")
    in_seg=0
  fi

  fail_rate=$(fmt_pct "$fail" "$total")

  echo
  log_both "════════════════════ 验证结果 ════════════════════"
  log_both "目标 URL     : $URL"
  log_both "采样间隔     : ${INTERVAL_MS} ms"
  log_both "运行时长     : $(fmt_sec "$dur") s（$(hms2 $(( T0 ))) → $(hms2 $(( end_ms )))）"
  log_both "总请求       : $total"
  log_both "成功         : $ok"
  log_both "失败         : ${fail}  (${fail_rate}%)"
  log_both "最大响应耗时 : ${max_ms} ms"
  if [ "$total" -gt 0 ]; then
    log_both "平均响应耗时 : $(( sum_ms / total )) ms"
  fi
  log_both "日志明细     : $LOG"

  if [ "${#segments[@]}" -gt 0 ]; then
    echo
    log_both "中断区间（连续失败聚合）："
    i=1
    for s in "${segments[@]}"; do
      log_both "  #$i  $s"
      i=$((i+1))
    done
  fi

  echo
  if [ "$fail" -eq 0 ]; then
    verdict="✓ 全部请求成功，滚动更新期间服务无中断"
    printf '%s%s%s\n' "$C_GRN" "$verdict" "$C_END"
    say "$verdict"
    SUMMARY_RC=0
  else
    verdict="✗ 检测到 ${#segments[@]} 段中断，累计失败 ${fail} 次 —— 更新期间存在不可用窗口"
    printf '%s%s%s\n' "$C_RED" "$verdict" "$C_END"
    say "$verdict"
    SUMMARY_RC=1
  fi
}

trap 'echo; summary; exit "$SUMMARY_RC"' INT TERM

T0=$(now_ms)
echo "────────────────────────────────────────────────────"
show "开始采样：$URL"
show "间隔 ${INTERVAL_MS}ms  超时 ${TIMEOUT}s  期望响应含 '${EXPECT}'"
show "按 Ctrl+C 结束并出汇总；另开窗口执行 rollout 触发更新。"
echo "────────────────────────────────────────────────────"

while :; do
  if [ "$DURATION_SEC" != "0" ] && [ $(( $(now_ms) - T0 )) -ge $(( DURATION_SEC * 1000 )) ]; then
    summary; exit "$SUMMARY_RC"
  fi

  start=$(now_ms)
  line_ts=$(stamp)
  # --noproxy '*' 必须加：环境里若有 http_proxy，curl 会把 localhost 请求交给代理，
  # 代理连不上就返回 502，看起来像服务挂了，实际是假失败。
  raw=$(curl -sS --noproxy '*' -m "$TIMEOUT" -o "$TMPB" -w '%{http_code} %{time_total}' "$URL" 2>"$ERRF")
  rc=$?
  code=${raw%% *}; tt=${raw##* }
  [ -z "$code" ] && code=000
  dur_ms=$(fmt_ms "${tt:-0}")
  body=$(head -c 200 "$TMPB" 2>/dev/null | tr -d '\r\n')
  errmsg=$(head -1 "$ERRF" 2>/dev/null | tr -d '\r')
  # 去掉 curl 错误信息里的 "curl: (7) " 前缀，只留人话；太长则截断，避免刷屏
  if [[ "$errmsg" =~ ^curl:\ \([0-9]+\)\ (.*)$ ]]; then errmsg="${BASH_REMATCH[1]}"; fi
  [ "${#errmsg}" -gt 56 ] && errmsg="${errmsg:0:56}…"

  total=$((total+1))
  sum_ms=$(( sum_ms + dur_ms ))
  [ "$dur_ms" -gt "$max_ms" ] && max_ms=$dur_ms

  rel=$(fmt_sec $(( start - T0 )))

  if [ "$rc" -ne 0 ]; then
    reason="curl rc=$rc ${errmsg}"
  elif [ "$code" != "200" ]; then
    reason="HTTP $code  ${errmsg}"
  elif [ -n "$EXPECT" ] && [[ "$body" != *"$EXPECT"* ]]; then
    reason="响应体不含 '${EXPECT}': ${body:0:60}"
  else
    reason=""
  fi

  if [ -z "$reason" ]; then
    ok=$((ok+1))
    if [ "$in_seg" -eq 1 ]; then
      # 中断结束，闭合区间
      segments+=("$(hms2 $(( seg_start_abs ))) → $(hms2 $(( start )))  持续 $(fmt_sec $(( start - seg_start_abs )))s  连续失败 ${seg_cnt} 次  ${seg_reason}")
      show "${C_YEL}▲ 恢复${C_END}  ${line_ts}  中断段持续 $(fmt_sec $(( start - seg_start_abs )))s，失败 ${seg_cnt} 次"
      in_seg=0; seg_cnt=0; seg_reason=''
    fi
    if [ "$QUIET_OK" != "1" ]; then
      printf '%s\n' "[$(printf '%8s' "${rel}s")] ${line_ts}  ${C_DIM}200${C_END} $(printf '%5s' "${dur_ms}ms")  ${body}"
      say "[${rel}s] ${line_ts}  200 ${dur_ms}ms  ${body}"
    fi
  else
    fail=$((fail+1))
    if [ "$in_seg" -eq 0 ]; then
      in_seg=1; seg_start_abs=$start; seg_cnt=0; seg_reason=$reason
    fi
    seg_cnt=$((seg_cnt+1))
    printf '%s\n' "${C_RED}[$(printf '%8s' "${rel}s")] ${line_ts}  FAIL $(printf '%5s' "${dur_ms}ms")  ${reason}${C_END}"
    say "[${rel}s] ${line_ts}  FAIL ${dur_ms}ms  ${reason}"
  fi

  # 节奏控制：扣掉本轮已耗时，补齐到 INTERVAL_MS
  elapsed=$(( $(now_ms) - start ))
  sleep_ms=$(( INTERVAL_MS - elapsed ))
  if [ "$sleep_ms" -gt 0 ]; then
    sleep "$(awk -v m="$sleep_ms" 'BEGIN{printf "%.3f", m/1000}')"
  fi
done
