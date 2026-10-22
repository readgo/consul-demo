# 单机 k3d 部署（零中断发版）

**前提**：一台 VM，已装 nginx / docker / docker compose，**没有** HAProxy。
**目标**：k3d 集群（1 server + 2 agents = 3 个容器），发版过程中 100ms 一次的探测零失败。

---

## 拓扑

```
client → nginx:8080 → 127.0.0.1:8081 (k3d-demo-serverlb)
                          └─→ server 节点 30080 ─(kube-proxy, Cluster)→ 任意 Pod
                               ├─ agent-0 上的 Pod
                               └─ agent-1 上的 Pod
```

| 端口 | 归属 | 说明 |
|---|---|---|
| 80 | 系统 nginx 原始配置 | 不动 |
| 8080 | nginx 新入口 | 宿主机映射到 VM 的这个端口 |
| 8081 | k3d serverlb | 只映射到回环 |
| 6550 | k3d API server | kubectl 用，kubeconfig 自动写入 |

**为什么没有 HAProxy**：3 个 docker 容器全在同一台机器，宿主机挂了 HAProxy 也一起挂；
滚动更新的中断由 k8s 自身（`maxUnavailable: 0` + 探针 + preStop）解决，与代理层无关。
k3d 自带的 serverlb 已经承担了「把流量分到各节点」的职责。

## 文件映射

| 仓库文件 | 复制到 VM 的位置 |
|---|---|
| `k8s/k3d/app.yml` | 任意目录，`kubectl apply -f` 用 |
| `k8s/k3d/nginx-8080.conf` | `/etc/nginx/conf.d/consul-demo.conf` |

---

## 1. 前置检查

```bash
docker version --format '{{.Server.Version}}'
docker compose version
nginx -v
free -g | head -2
```

建议至少 **4 核 8G**：3 个 k3d 节点容器本身要吃 2G 左右，再加 3~4 个业务 Pod。

判据：三个命令都有版本输出。

## 2. 装 k3d

```bash
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
k3d version
```

外网不通时改用二进制直装：

```bash
curl -sL -o /tmp/k3d https://github.com/k3d-io/k3d/releases/download/v5.7.4/k3d-linux-amd64
sudo install -m 755 /tmp/k3d /usr/local/bin/k3d
k3d version
```

判据：`k3d version v5.7.x`（≥ 5.6 即可）。

## 3. 创建集群

```bash
k3d cluster create demo \
  --servers 1 --agents 2 \
  --api-port 6550 \
  --k3s-arg "--disable=traefik@server:0" \
  -p 8081:30080@loadbalancer \
  --wait
```

四个参数的作用：

| 参数 | 为什么 |
|---|---|
| `--servers 1 --agents 2` | 单机上 3 个 server 毫无意义（quorum 防的是机器故障，同机一起挂），白吃三倍内存 |
| `--api-port 6550` | 避开 6443，防止和机器上其他 k3s/k8s 抢端口 |
| `--disable=traefik` | 不装 ingress controller，省 ~100M 内存，也不用它占 80/443 |
| `-p 8081:30080@loadbalancer` | 宿主 8081 → serverlb → **server 节点** 的 30080 |

判据：

```bash
kubectl get nodes -o wide
```

三行全部 `Ready`，名字是 `k3d-demo-server-0` / `k3d-demo-agent-0` / `k3d-demo-agent-1`。

## 4. 准备镜像（这一步的顺序后面会反复用到）

```bash
docker pull wttcvs/consul-demo:v20261022-172323
k3d image import wttcvs/consul-demo:v20261022-172323 -c demo
```

`k3d image import` 会把镜像灌进**所有**节点容器。不导的话，Pod 会卡在 `ImagePullBackOff`
（节点连不上 Docker Hub，或者拉到一半超时）。

判据：

```bash
docker exec k3d-demo-agent-0 crictl images | grep consul-demo
```

## 5. 部署

```bash
kubectl apply -f app.yml
kubectl rollout status deployment/consul-demo --timeout=180s
kubectl get pods -o wide
```

判据：3 个 Pod 全 `1/1 Running`，分布在 2 个 agent 上（server 有 NoSchedule 污点，是 2-1 而不是 1-1-1）。

```bash
kubectl get svc consul-demo
```

`EXTERNAL-IP` 一列应显示 `<none>`、`PORT(S)` 是 `80:30080/TCP`。

## 6. 本机验证（绕开 nginx，直连 serverlb）

```bash
curl -s "http://127.0.0.1:8081/v1/test?name=k3d-$(date +%H%M%S)"
```

判据：返回 `hello:k3d-<时间戳>`。

## 7. nginx 入口

```bash
sudo install -m 644 ~/nginx-8080.conf /etc/nginx/conf.d/consul-demo.conf
sudo nginx -t
sudo systemctl reload nginx
```

判据：

```bash
curl -s http://127.0.0.1:8080/nginx-health                 # ok
curl -s "http://127.0.0.1:8080/v1/test?name=ng-$(date +%H%M%S)"
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/  # 仍是 200，80 没被动过
```

## 8. 宿主机：加端口转发

| 宿主机端口 | 目标 |
|---|---|
| 30081 | `VM_IP:8080` |

8081 是 k3d 的 serverlb，**不需要**映射（它只给本机 nginx 用）。

---

## 9. 零中断发版（这是本文档的核心）

### 顺序铁律

```
docker pull  →  k3d image import  →  kubectl set image
```

**先 import 再 set image**。反过来的话，新 Pod 会 `ImagePullBackOff`，
旧 Pod 因为 `maxUnavailable: 0` 一直不删，`rollout status` 卡在那里不动，
表面上「发布没反应」，实际是镜像根本没到节点上。

### 一条命令跑完

```bash
TAG=v20261023-001122          # 换成实际 tag

docker pull wttcvs/consul-demo:$TAG \
  && k3d image import wttcvs/consul-demo:$TAG -c demo \
  && kubectl set image deployment/consul-demo app=wttcvs/consul-demo:$TAG \
  && kubectl rollout status deployment/consul-demo --timeout=180s
```

用 `&&` 串联，任一步失败就停，不会出现「import 失败但镜像已切换」的半截状态。

### 边发边验

```bash
# 宿主机执行
cd ~/jing.work/consul-demo
URL='http://localhost:30081/v1/test?name=jing-{TS}' \
DURATION_SEC=120 INTERVAL_MS=100 \
./k8s/rollout-watch.sh
```

另一窗口跑上面那条发版命令。

**判据**：汇总 `失败 0`，退出码 0，响应体里能看到 tag 时间戳从旧变新。

### 观察滚动过程

```bash
kubectl get pods -w
```

能看到 `maxUnavailable: 0` 的效果：新 Pod 先 `1/1 Running` 就绪，
之后旧 Pod 才进 `Terminating`，中间任何时刻可用副本都不少于 3。

---

## 10. 回滚

```bash
kubectl rollout undo deployment/consul-demo
```

**前提**：回滚目标的镜像必须还在节点上。如果中间做过 `k3d image import` 的清理，
或者换了机器，需要重新 import 再回滚，否则又是 `ImagePullBackOff`。

---

## 11. 清理

```bash
k3d cluster delete demo
```

连带删掉三个节点容器和一个 serverlb 容器，docker 网络也会回收。

---

## 三个单机 k3d 特有的坑

### 坑 1：`externalTrafficPolicy` 必须是 Cluster

k3d 的 `-p ...@loadbalancer` 是把流量转到 **server 节点**的 30080，
而 server 节点默认带 `node-role.kubernetes.io/master:NoSchedule` 污点、上面没有 Pod。

- `Local` 模式：server 的 30080 只转发给本机 Pod，本机没有 → **直接拒绝**，整条链路 503
- `Cluster` 模式：kube-proxy 把请求 DNAT 到任意节点的 Pod，通

这和 3 台独立 VM 的 k3s 场景是**相反**的，别照抄那边的配置。

### 坑 2：镜像不会自动同步

k3d 的节点是容器，里面跑的是 containerd，**不共享宿主机的 docker 镜像**。
每次发版都必须 `k3d image import`。

替代方案是给 k3d 配一个本地 registry（`k3d registry create`），但为了 demo 不值得，
多一个组件就多一个会挂的东西。

### 坑 3：serverlb 是单点，且重启期间全断

`k3d-demo-serverlb` 是一个普通容器。`k3d cluster stop/start` 会让它重建，
这期间入口 100% 中断 —— 这是单机方案的物理上限，加多少层代理都救不了。

能做的只有：别在业务高峰重启集群。

---

## 报错对照

| 现象 | 原因 | 处理 |
|---|---|---|
| Pod `ImagePullBackOff` | 镜像没 import | 回第 4 步 |
| `curl 8081` 返回 503 | `externalTrafficPolicy: Local` 且 server 无 Pod | 改 Cluster |
| `curl 8081` 连接被拒 | serverlb 没起来 | `docker ps \| grep serverlb` |
| `rollout status` 一直不动 | 新 Pod 起不来（多半是镜像） | `kubectl describe pod` 看 Events |
| `k3d cluster create` 报端口占用 | 6443 或 30080 被占 | 换 `--api-port`，或先 `k3d cluster delete` |
| 发版时偶发 502 | preStop 时间不够 | 把 `sleep 5` 调到 8~10 |
