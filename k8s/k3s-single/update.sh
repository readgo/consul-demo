#!/usr/bin/env bash
# ============================================================
#  update.sh —— 拉 latest → 滚动更新 → 打印「从 X 更新到 Y」
#
#  执行位置：只在 node1（10.0.3.13）执行，需要 sudo
#
#  用法：
#    sudo ./update.sh                         # 拉 latest，滚更，结束打一行版本变更
#    sudo ./update.sh --force                 # latest 没变也强制滚一次（纯演练滚动）
#    sudo ./update.sh --tag v20261023-110000  # 不拉 latest，直接发指定版本
#    sudo ./update.sh --dry-run               # 只打印要做什么
#
#  在宿主机另开一个窗口观察（那个窗口别关，要停按 Ctrl+C 不要按 Ctrl+Z）：
#    URL='http://localhost:30084/v1/test?name=jing-{TS}' \
#      DURATION_SEC=180 INTERVAL_MS=100 ./k8s/rollout-watch.sh
#
#  它只干发版，不起观测器。有没有断由宿主机那个窗口说了算。
# ============================================================
set -uo pipefail

SD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cluster.env
. "$SD/cluster.env"

TARGET_TAG="latest"
FORCE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)   TARGET_TAG="${2:?--tag 后面要跟版本号}"; shift 2 ;;
    --tag=*) TARGET_TAG="${1#*=}"; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,/^# =\+$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 1 ;;
  esac
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_E=$'\e[0m'
info() { printf '      %s\n' "$*"; }
ok()   { printf '      %s✓ %s%s\n' "$C_G" "$*" "$C_E"; }
warn() { printf '      %s! %s%s\n' "$C_Y" "$*" "$C_E"; }
die()  { printf '%s✗ %s%s\n' "$C_R" "$*" "$C_E" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  die "需要 root：sudo $0 $*"
fi

if command -v kubectl >/dev/null 2>&1; then KCTL=(kubectl); else KCTL=(k3s kubectl); fi
CRI=(k3s crictl)
"${CRI[@]}" version >/dev/null 2>&1 || CRI=(crictl)
"${CRI[@]}" version >/dev/null 2>&1 || die "找不到 crictl（k3s crictl 也不可用），本机是 k3s 节点吗？"

# ---------- 工具函数 ----------

# 取镜像的仓库摘要（sha256:...）。crictl 对引用写法敏感，
# 带不带 docker.io/ 前缀都试一次。
repo_digest() {
  local ref="$1" out d
  for r in "$ref" "docker.io/${ref#docker.io/}"; do
    out=$("${CRI[@]}" inspecti "$r" 2>/dev/null) || continue
    d=$(printf '%s' "$out" | tr -d ' \n' \
        | grep -oE '"repoDigests":\[[^]]*\]' \
        | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
    if [ -n "$d" ]; then printf '%s\n' "$d"; return 0; fi
  done
  return 1
}

# 用 digest 反查「这个镜像对应哪个 v* 版本号」。
# 查不到不算错：有的环境连不上 Docker Hub，退化成显示 latest@sha256:xxxx 即可。
hub_tag_for_digest() {
  local repo="$1" want="$2"
  command -v python3 >/dev/null 2>&1 || return 0
  curl -fsS --max-time 8 \
    "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100" 2>/dev/null \
  | python3 -c '
import json,sys
want=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for r in d.get("results",[]):
    n=r.get("name","")
    if not (n.startswith("v") and n[1:2].isdigit()): continue
    if any(i.get("digest")==want for i in r.get("images",[])):
        print(n)
' "$want" | sort -V | tail -1
}

short() { printf '%s' "${1:7:12}"; }

# ---------- 1. 当前版本 ----------

cur_image=$("${KCTL[@]}" -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].image}" 2>/dev/null)
[ -n "$cur_image" ] || die "读不到 $NS/$DEPLOY 里容器 $CONTAINER 的镜像"

# 拆 repo / tag，兼容 registry:5000/a/b:v1 和 repo@sha256:xxx
if [[ "$cur_image" == *"@"* ]]; then
  cur_repo="${cur_image%%@*}"; cur_tag="digest:$(short "${cur_image##*@}")"
else
  last="${cur_image##*/}"
  if [[ "$last" == *:* ]]; then cur_repo="${cur_image%:*}"; cur_tag="${last##*:}"
  else cur_repo="$cur_image"; cur_tag="latest"; fi
fi

cur_digest=$("${KCTL[@]}" -n "$NS" get pods -l "app=$DEPLOY" \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null \
  | sed 's/^.*sha256:/sha256:/' | tr -d ' \n')

info "当前版本：$cur_tag${cur_digest:+（$(short "$cur_digest")）}"
info "目标版本：$cur_repo:$TARGET_TAG"

# ---------- 2. 拉镜像 ----------

REF="$cur_repo:$TARGET_TAG"
if [ "$DRY_RUN" = "1" ]; then
  info "（dry-run）${CRI[*]} pull $REF"
  info "（dry-run）${KCTL[*]} -n $NS set image deploy/$DEPLOY $CONTAINER=<新版本>"
  exit 0
fi

printf '\n%s[1/3]%s 拉取 %s\n' "$C_B" "$C_E" "$REF"
info "超时 ${PULL_TIMEOUT:-600}s（国内链路慢，别急）"
pull_log=$("${CRI[@]}" pull "$REF" 2>&1)
if [ $? -ne 0 ]; then
  printf '%s\n' "$pull_log" | tail -5 | sed 's/^/      /'
  echo
  die "拉取失败，线上版本没有任何改动（还是 $cur_tag）"
fi
ok "已落盘"

new_digest=$(repo_digest "$REF") || die "拉下来了但读不到摘要，检查：${CRI[*]} images | grep ${cur_repo##*/}"
info "新摘要：$(short "$new_digest")"

# ---------- 3. 决定发什么 ----------

new_ver=""
if [ "$TARGET_TAG" != "latest" ]; then
  new_ver="$TARGET_TAG"
else
  new_ver=$(hub_tag_for_digest "$cur_repo" "$new_digest")
  [ -n "$new_ver" ] && info "latest 对应版本：$new_ver"
  [ -z "$new_ver" ] && warn "查不到 latest 对应的版本号（Hub 不通？），下面按摘要发"
fi

same=0
if [ -n "$cur_digest" ] && [ "$cur_digest" = "$new_digest" ]; then same=1; fi

if [ "$same" = "1" ] && [ "$FORCE" != "1" ]; then
  echo
  ok "已是最新：$cur_tag 就是 $REF 指向的镜像（$(short "$new_digest")），无需更新"
  info "想强制滚一次验证流程：sudo $0 --force"
  exit 0
fi

# 有版本号就发版本号（可读、下次好对比）；否则按摘要发，保证一定触发滚动
if [ -n "$new_ver" ] && [[ "$new_ver" == v* ]]; then
  NEW_IMAGE="${cur_repo}:${new_ver}"
  # 本地先把 tag 指到刚拉的摘要上，kubelet 的 IfNotPresent 就不会再去联网拉
  ctr_src="docker.io/${cur_repo#docker.io/}"
  k3s ctr -n k8s.io images tag "${ctr_src}@${new_digest}" "${ctr_src}:${new_ver}" >/dev/null 2>&1 \
    || warn "本地打 tag 失败（不影响，kubelet 会自己拉）"
elif [ "$same" = "1" ]; then
  NEW_IMAGE=""        # --force 且版本没变：只重启，不改镜像
else
  NEW_IMAGE="${cur_repo}@${new_digest}"
  new_ver="latest@$(short "$new_digest")"
fi

# ---------- 4. 滚动更新 ----------

if [ -z "$NEW_IMAGE" ]; then
  printf '\n%s[2/3]%s 强制重建（镜像未变）\n' "$C_B" "$C_E"
  "${KCTL[@]}" -n "$NS" rollout restart "deploy/$DEPLOY" >/dev/null
else
  printf '\n%s[2/3]%s 更新镜像 %s\n' "$C_B" "$C_E" "$NEW_IMAGE"
  "${KCTL[@]}" -n "$NS" set image "deploy/$DEPLOY" "$CONTAINER=$NEW_IMAGE" >/dev/null
fi

printf '%s[3/3]%s 等待滚动完成（maxUnavailable=0，逐个换）\n' "$C_B" "$C_E"
if ! "${KCTL[@]}" -n "$NS" rollout status "deploy/$DEPLOY" --timeout="${ROLLOUT_TIMEOUT:-180s}" 2>&1 | sed 's/^/      /'; then
  echo
  "${KCTL[@]}" -n "$NS" rollout undo "deploy/$DEPLOY" >/dev/null 2>&1 \
    && warn "已回滚到上一版本（旧 Pod 在滚动期间一个都没删，业务没断）" \
    || warn "回滚失败，手动执行：kubectl -n $NS rollout undo deploy/$DEPLOY"
  die "滚动更新未完成"
fi

# ---------- 5. 结果 ----------

final_digest=$("${KCTL[@]}" -n "$NS" get pods -l "app=$DEPLOY" \
  -o jsonpath='{.items[*].status.containerStatuses[0].imageID}' 2>/dev/null \
  | tr ' ' '\n' | sed 's/^.*sha256:/sha256:/' | sort -u | head -1)

ready=$("${KCTL[@]}" -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null); ready=${ready:-0}

echo
printf '%s────────────────────────────────────────%s\n' "$C_B" "$C_E"
printf '  %s✓ 已从 %s 更新到 %s%s\n' "$C_G" "$cur_tag" "$new_ver" "$C_E"
printf '%s────────────────────────────────────────%s\n' "$C_B" "$C_E"
printf '  镜像  %s\n' "${NEW_IMAGE:-$cur_image（仅重建）}"
printf '  摘要  %s → %s\n' "${cur_digest:+$(short "$cur_digest")}" "$(short "$new_digest")"
printf '  副本  %s/%s 就绪\n' "$ready" "${REPLICAS:-3}"

if [ -n "$final_digest" ] && [ "$final_digest" != "$new_digest" ]; then
  echo
  warn "注意：Pod 实际跑的摘要（$(short "$final_digest")）和刚拉的（$(short "$new_digest")）不一致"
  warn "     执行 kubectl -n $NS get pods -l app=$DEPLOY 看是否还在换"
fi

exit 0
