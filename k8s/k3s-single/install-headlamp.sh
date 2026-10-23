#!/usr/bin/env bash
# ============================================================
#  install-headlamp.sh —— 在 k3s 上装 Headlamp（K8s 图形界面）
#
#  执行位置：node1（10.0.3.13）即可，单机/多机都行
#
#  用法：
#    sudo ./install-headlamp.sh                 # 安装，默认 NodePort 30090
#    sudo ./install-headlamp.sh --port 30091    # 换端口
#    sudo ./install-headlamp.sh --token         # 只重新生成登录 token
#    sudo ./install-headlamp.sh --uninstall     # 卸载
#    sudo ./install-headlamp.sh --dry-run       # 只打印清单，不 apply
#
#  装完打开 http://<node1-IP>:30090 ，登录页选「Token」粘贴脚本打印的 token。
#
#  为什么用 NodePort 而不是 port-forward：
#    port-forward 是前台进程，Ctrl+Z 只是挂起、关终端就断，还要再配 systemd。
#    NodePort 由 kube-proxy 常驻，机器重启自动恢复，没有任何前台进程要保。
# ============================================================
set -uo pipefail

SD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=cluster.env
[ -f "$SD/cluster.env" ] && . "$SD/cluster.env"

NS_HL="${NS_HEADLAMP:-headlamp}"
HL_PORT="${HEADLAMP_PORT:-30090}"
HL_IMAGE="${HEADLAMP_IMAGE:-ghcr.io/headlamp-k8s/headlamp:latest}"
TOKEN_TTL="${TOKEN_TTL:-24h}"
SA_NAME="headlamp-admin"

ACTION=install
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port)   HL_PORT="${2:?--port 后面要跟端口}"; shift 2 ;;
    --port=*) HL_PORT="${1#*=}"; shift ;;
    --token)  ACTION=token; shift ;;
    --uninstall|--remove) ACTION=uninstall; shift ;;
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

if command -v kubectl >/dev/null 2>&1; then KCTL=(kubectl); else KCTL=(k3s kubectl); fi
if [ "$DRY_RUN" != "1" ]; then
  "${KCTL[@]}" get --raw=/healthz --request-timeout=5s >/dev/null 2>&1 \
    || die "连不上集群。kubectl 要能在本机跑通（root 下 /etc/rancher/k3s/k3s.yaml 才有权限）"
fi

# ---------- 卸载 ----------

if [ "$ACTION" = "uninstall" ]; then
  printf '%s[卸载]%s 删除 namespace %s 下的 Headlamp\n' "$C_B" "$C_E" "$NS_HL"
  "${KCTL[@]}" delete namespace "$NS_HL" --ignore-not-found >/dev/null 2>&1
  ok "已删除（namespace $NS_HL 连带 Deployment/Service/SA 全部回收）"
  info "镜像还留在 node 上，要一起清：sudo k3s crictl rmi $HL_IMAGE"
  exit 0
fi

# ---------- 只出 token ----------

gen_token() {
  "${KCTL[@]}" -n "$NS_HL" create token "$SA_NAME" --duration="$TOKEN_TTL" 2>/dev/null
}

if [ "$ACTION" = "token" ]; then
  t=$(gen_token) || die "生成失败：ServiceAccount $NS_HL/$SA_NAME 不存在？先跑一次安装"
  printf '\n访问 http://%s:%s\n\nToken（%s 有效）：\n%s\n\n' \
    "$(hostname -I 2>/dev/null | awk '{print $1}')" "$HL_PORT" "$TOKEN_TTL" "$t"
  exit 0
fi

# ---------- 清单 ----------

MANIFEST=$(cat <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS_HL}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NS_HL}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${SA_NAME}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NS_HL}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: headlamp
  namespace: ${NS_HL}
  labels:
    k8s-app: headlamp
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: headlamp
  template:
    metadata:
      labels:
        k8s-app: headlamp
    spec:
      serviceAccountName: ${SA_NAME}
      containers:
      - name: headlamp
        image: ${HL_IMAGE}
        imagePullPolicy: IfNotPresent
        args:
        - --in-cluster
        - --plugins-dir=/headlamp/plugins
        ports:
        - name: http
          containerPort: 4466
        readinessProbe:
          httpGet:
            path: /
            port: 4466
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: headlamp
  namespace: ${NS_HL}
  labels:
    k8s-app: headlamp
spec:
  type: NodePort
  selector:
    k8s-app: headlamp
  ports:
  - name: http
    port: 80
    targetPort: 4466
    nodePort: ${HL_PORT}
YAML
)

if [ "$DRY_RUN" = "1" ]; then
  printf '\n%s[1/4]%s 将 apply 的清单（NodePort %s）：\n\n' "$C_B" "$C_E" "$HL_PORT"
  printf '%s\n' "$MANIFEST" | sed 's/^/      /'
  printf '\n      （dry-run，未执行）\n'
  exit 0
fi

# ---------- 1. 预拉镜像 ----------

printf '\n%s[1/4]%s 预拉镜像 %s\n' "$C_B" "$C_E" "$HL_IMAGE"
pull_cmd=""
if [ "$(id -u)" -eq 0 ]; then
  command -v k3s >/dev/null 2>&1 && pull_cmd="k3s crictl"
else
  sudo -n true 2>/dev/null && command -v k3s >/dev/null 2>&1 && pull_cmd="sudo -n k3s crictl"
fi

if [ -z "$pull_cmd" ]; then
  warn "拿不到 crictl（要 root 或 k3s 不在本机），跳过预拉，交给 kubelet"
else
  if $pull_cmd pull "$HL_IMAGE" >/tmp/headlamp-pull.log 2>&1; then
    ok "镜像已落盘"
  else
    warn "拉取失败，最后 3 行："
    tail -3 /tmp/headlamp-pull.log | sed 's/^/        /'
    warn "ghcr.io 国内常不通。两个办法："
    warn "  1) 换一个能拉的镜像：sudo HEADLAMP_IMAGE=<别的地址>/headlamp:latest \$0"
    warn "  2) 在能上网的机器 docker pull 后：docker save > hl.tar，"
    warn "     scp 到本机再 sudo k3s ctr images import hl.tar"
    warn "下面仍然会 apply，Pod 会停在 ImagePullBackOff 等你解决镜像"
  fi
fi

# ---------- 2. apply ----------

printf '%s[2/4]%s 创建 namespace / SA / 权限 / Deployment / Service\n' "$C_B" "$C_E"
printf '%s\n' "$MANIFEST" | "${KCTL[@]}" apply -f - 2>&1 | sed 's/^/      /' \
  || die "apply 失败"

# ---------- 3. 等就绪 ----------

printf '%s[3/4]%s 等待 Pod 就绪（最多 120s）\n' "$C_B" "$C_E"
if "${KCTL[@]}" -n "$NS_HL" rollout status deploy/headlamp --timeout=120s 2>&1 | sed 's/^/      /'; then
  ok "Pod 已就绪"
else
  warn "没就绪，看这两个："
  "${KCTL[@]}" -n "$NS_HL" get pods -o wide 2>&1 | sed 's/^/        /'
  "${KCTL[@]}" -n "$NS_HL" describe pod -l k8s-app=headlamp 2>/dev/null \
    | sed -n '/Events:/,$p' | tail -8 | sed 's/^/        /'
  die "Headlamp 启动失败（镜像拉不下来是最常见原因）"
fi

# ---------- 4. 给地址和 token ----------

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "${IP:-}" ] || IP="<node1-IP>"

token=$(gen_token) || token=""
if [ -z "$token" ]; then
  warn "token 生成失败，手动：sudo kubectl -n $NS_HL create token $SA_NAME --duration=$TOKEN_TTL"
fi

echo
printf '%s────────────────────────────────────────%s\n' "$C_B" "$C_E"
printf '  %s✓ Headlamp 已启动%s\n' "$C_G" "$C_E"
printf '%s────────────────────────────────────────%s\n' "$C_B" "$C_E"
printf '  访问   http://%s:%s\n' "$IP" "$HL_PORT"
printf '  登录页选「Token」，粘贴：\n\n'
printf '%s\n\n' "$token"
printf '  token %s 过期，重新生成：sudo %s --token\n' "$TOKEN_TTL" "$0"
printf '  换台机器打不开 → 放行端口：sudo ufw allow %s/tcp\n' "$HL_PORT"
