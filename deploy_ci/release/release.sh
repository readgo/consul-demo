#!/usr/bin/env bash
# ============================================================
#  发布：打一个 tag 推上去，由 GitHub Actions 构建镜像并推到 Docker Hub。
#
#    ./release.sh                  自动生成 tag（v20261021-104730）并推送
#    ./release.sh v1.2.3           用指定的 tag
#    ./release.sh --wait           推完等镜像真的出现在 Docker Hub 上再返回
#    ./release.sh --dry-run        只打印要做什么，不真打 tag、不推送
#    ./release.sh --list           看已经发过哪些 tag
#
#  为什么必须打 tag：CI 只认 tag。工作区里没提交的改动不会进镜像，
#  所以本脚本发现有未提交内容会直接停下，而不是让你发一个少了改动的版本。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 后面会 cd 到项目根，这里先把自身路径存成绝对路径，
# 否则 --help 里的 awk 找不到 ./release.sh
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$ROOT"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\n[错误] %s\n' "$*" >&2; exit 1; }

# ---------- 参数 ----------
TAG=""
WAIT=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --wait)    WAIT=1 ;;
    --dry-run) DRY=1 ;;
    --list)
      git tag -l 'v*' --sort=-creatordate | head -20
      exit 0 ;;
    -h|--help)
      awk 'NR>2 && /^# ====/ {exit} NR>2 && /^#/ {sub(/^# ?/, ""); print}' "$SELF"
      exit 0 ;;
    -*)
      die "不认识的参数：$arg
        可用：--wait | --dry-run | --list | --help | <自定 tag 名>" ;;
    *)
      [ -n "$TAG" ] && die "只能指定一个 tag，已经给了 $TAG"
      TAG="$arg" ;;
  esac
done

# ---------- 前置检查 ----------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "当前目录不是 git 仓库"

REMOTE_URL="$(git remote get-url origin 2>/dev/null)" || die "没有配 origin 远端"

# 从远端地址里取 owner/repo，两种写法都认：
#   https://github.com/readgo/consul-demo.git
#   git@github.com:readgo/consul-demo.git
# 注意：不能指望 sed 的非贪婪量词，POSIX ERE 里没有这玩意儿，
# 直接用 bash 的字符串裁剪更稳。
SLUG="${REMOTE_URL%.git}"
SLUG="${SLUG%/}"
case "$SLUG" in
  *://*)                       # 带协议：先砍协议，再砍主机名
    SLUG="${SLUG#*://}"
    SLUG="${SLUG#*/}" ;;
  *:*)                         # scp 风格：git@host:owner/repo
    SLUG="${SLUG#*:}" ;;
esac
case "$SLUG" in
  ''|/*|*/*/*)
    die "从远端地址里解析不出 owner/repo：$REMOTE_URL
         解析结果：[$SLUG]
         可以手工指定镜像仓库：IMAGE_REPO=<账号/仓库> $0 ..." ;;
esac

# 镜像推到哪个 Docker Hub 账号下。
# 必须与 .github/workflows/release.yml 里的 DOCKERHUB_NAMESPACE 一致
# （那里还会拿它跟仓库密钥 DOCKER_USERNAME 对比，不一致 CI 直接失败）。
# 不能拿 GitHub 仓库的 owner 当默认值：Docker Hub 账号和 GitHub 账号经常不是同一个。
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-wttcvs}"
IMAGE_REPO="${IMAGE_REPO:-$DOCKERHUB_NAMESPACE/${SLUG##*/}}"
ACTIONS_URL="https://github.com/$SLUG/actions/workflows/release.yml"

# 工作区有未提交内容 -> 那些改动不会进镜像。直接停，不要发一个残版本。
if [ -n "$(git status --porcelain)" ]; then
  say "[错误] 有未提交的改动，这些改动不会进镜像。先提交再发布："
  say ""
  git status --short | sed 's/^/  /'
  say ""
  say "  提交：git add -A && git commit -m \"...\" && git push"
  exit 1
fi

# tag 名：不给就按时间生成
if [ -z "$TAG" ]; then
  TAG="v$(date '+%Y%m%d-%H%M%S')"
fi

case "$TAG" in
  v*) ;;
  *) die "tag 要以 v 开头（CI 只对 v* 触发），例：v1.2.3 或 v20261021-104730" ;;
esac

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  die "本地已有 tag $TAG，换一个名字"
fi

# 远端已有同名 tag 时，推上去会被拒；提前查一下，省得推到一半失败
if git ls-remote --tags --exit-code origin "refs/tags/$TAG" >/dev/null 2>&1; then
  die "远端已有 tag $TAG，换一个名字"
fi

HEAD_SHA="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# ---------- 交代要做什么 ----------
step "1/3 发布内容"
say "    仓库        $SLUG"
say "    分支        $BRANCH"
say "    提交        $HEAD_SHA  $(git log -1 --format=%s)"
say "    tag         $TAG"
say "    镜像        $IMAGE_REPO:$TAG"
say "                $IMAGE_REPO:latest（同一个镜像的别名，正式部署请钉 tag）"

if [ "$DRY" = 1 ]; then
  step "试运行，下面这些不会真的执行"
  say "    git tag -a $TAG -m \"release $TAG\""
  say "    git push origin $TAG"
  [ "$WAIT" = 1 ] && say "    然后轮询 Docker Hub 等 $TAG 出现"
  say ""
  say "去掉 --dry-run 再跑一次就真发。"
  exit 0
fi

# ---------- 打 tag 并推 ----------
step "2/3 打 tag 并推送"
git tag -a "$TAG" -m "release $TAG"
git push origin "$TAG"
say "    已推送 $TAG"

step "3/3 等 CI 构建"
say "    构建进度   $ACTIONS_URL"
say "    构建日志   点上面链接 -> 最上面那次 run"

if [ "$WAIT" = 0 ]; then
  cat <<EOF

镜像构建要几分钟。想确认镜像真的上去了，可以：

  ./release.sh --wait                 # 只能配合刚发的 tag 用，这里请用下面的
  docker pull $IMAGE_REPO:$TAG        # 直接拉一次，能拉下来就是好了

发完之后，服务器上把 config.ini 改成这一行，再执行 sudo ./deploy.sh service：

  IMAGE_TAG=$TAG

EOF
  exit 0
fi

# ---------- 可选：等 Docker Hub 上真出现这个 tag ----------
step "等镜像出现在 Docker Hub"
say "    镜像        $IMAGE_REPO:$TAG"
say "    最多等      600 秒"

NS="${IMAGE_REPO%%/*}"
NAME="${IMAGE_REPO##*/}"
API="https://hub.docker.com/v2/repositories/$NS/$NAME/tags/$TAG"

i=0
while [ "$i" -lt 60 ]; do
  i=$((i + 1))
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$API" 2>/dev/null || echo 000)"
  case "$code" in
    200)
      say ""
      say "    镜像已就绪：$IMAGE_REPO:$TAG"
      say ""
      say "    服务器上执行："
      say "      sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=$TAG|' config.ini"
      say "      sudo ./deploy.sh service"
      exit 0 ;;
    401|403)
      say ""
      say "    [注意] Docker Hub 返回 $code，说明仓库是私有的，本脚本查不到。"
      say "           去 $ACTIONS_URL 看这次 run 是不是绿的即可。"
      exit 0 ;;
  esac
  printf '    第 %d 次还没好（HTTP %s），10 秒后再看\n' "$i" "$code"
  sleep 10
done

die "等了 600 秒还没在 Docker Hub 上看到 $TAG。
     去看构建日志：$ACTIONS_URL
     常见原因：密钥没配、Docker Hub 用户名和 IMAGE_REPO 不一致、构建失败。"
