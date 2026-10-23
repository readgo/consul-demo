# 单机起步 → 3 台不停机扩容 · 演练手册

目标：一台机器起步，跑通零中断滚动更新；再扩到三台，实现「关掉一台业务照常」。

---

## 0. 拓扑与角色

| 机器 | IP | 角色 | 说明 |
|---|---|---|---|
| node1 | `10.0.3.13` | k3s server + nginx 入口 | 起步时唯一的一台（演练机名 `k3s-t1`），**唯一写进 `cluster.env` 的 IP** |
| node2 | 后加，实际 IP | k3s server | 不用改配置，`join-server.sh` 自动探测本机 IP |
| node3 | 后加，实际 IP | k3s server | 同上 |
| 第 4~10 台 | 后加，实际 IP | k3s server | 同上，**零配置** |

> 集群成员是动态的（`K3S_URL` + `K3S_TOKEN` 加入，成员表在 etcd 里）。
> `cluster.env` 只保留 `NODE1_IP` 做引导；节点清单由 `kubectl get nodes` 动态取。
> 演练环境已占用：`.8/.9/.10` = 旧三台 k3s、`.11` = nginx 网关、`.12` = k3d。

三台都是 server 而不是 1 server + 2 agent，因为 **k3s 的 server 节点默认没有 `NoSchedule` 污点**，可以直接跑业务 Pod。这样 3 台同时是「HA 控制面 + 3 个 worker」，关任意一台 etcd quorum 仍是 2/3。

**端口约定**：`8080` = nginx 入口（宿主机映射到它），`30080` = Service nodePort，`6443` = apiserver。**80 全程不动**。

---

## 1. 准备（在宿主机）

需要上传的仓库文件（保持目录结构，不要拆开）：

```
k8s/
├── app.yml                  ← 部署清单
├── deploy.sh                ← 发版（阶段五用）
├── rollout-watch.sh         ← 零中断观测（阶段五用）
└── k3s-single/
    ├── cluster.env          ← 唯一要改的文件
    ├── lib.sh
    ├── install-single.sh
    ├── join-server.sh
    ├── scale-out.sh
    ├── rollout-test.sh      ← 单机阶段验滚动更新（一键，自己起观测器）
    ├── nginx/consul-demo.conf
    └── DEPLOY.md            ← 本文件
```

宿主机路径：`/home/jing/jing.work/consul-demo/k8s/`

**每台机器都要放一份**，位置统一为 `~/k8s/`。`join-server.sh` 在新节点上执行，所以新加的每台也得有。

> **只做「阶段一 单机」时，最少需要这三样**：
> `k3s-single/`（整个目录，含 `nginx/`）、同级的 `app.yml`、同级的 `rollout-watch.sh`。
> 实际位置可以简化为 `~/k3s-single/` + `~/app.yml` + `~/rollout-watch.sh`
> —— 脚本会依次在 `../app.yml`、`./app.yml`、`../../k8s/app.yml` 里找清单。
> 只传了 `k3s-single/` 没传 `app.yml` 时，第 0 步就会报错，不会装到一半才失败。

上传后，**每台都**执行：

```bash
cd ~/k8s/k3s-single
chmod +x *.sh
```

**只改 node1 那一台 `cluster.env` 里的 `NODE1_IP`**：

```bash
grep -E '^NODE1_IP' cluster.env     # 应是 NODE1_IP=10.0.3.13
```

> 新加的机器**不需要改这个文件**：`join-server.sh` 会按「到 apiserver 的路由」
> 自动探测本机 IP 并写成 `--node-ip`。`cluster.env` 里已没有 `NODE2_IP/NODE3_IP`，
> 加第 4 台、第 10 台都不用动配置。

---

## 2. 阶段一：单机起步

### 【node1】执行

```bash
cd ~/k8s/k3s-single
sudo ./install-single.sh --dry-run     # 先看计划
sudo ./install-single.sh               # 真跑
```

它做六件事：装 k3s（带 `--cluster-init`，即 embedded etcd）→ 等 Ready → 装 nginx → 生成 upstream（只含 node1）→ 预拉镜像 → apply 清单并等 3 副本就绪。

**判据**：最后出现 `✓ 3 副本已就绪`，并打印出阶段二的 join 命令（含 token）。

### 【node1】验证

```bash
curl -s http://127.0.0.1:8080/v1/test?name=standalone-$(date +%H%M%S)
curl -s http://127.0.0.1:8080/nginx-health
kubectl get pods -o wide          # 3 个 Pod 全在 node1，正常
```

第一条应返回 `hello:standalone-<时间戳>`。三条都对，单机阶段成立。

### 【node1】验证零中断滚动更新（单机版）

一条命令，不用开两个窗口：

```bash
cd ~/k8s/k3s-single
sudo ./rollout-test.sh --restart     # 先跑这个：30 秒，只重建 Pod 不换镜像
sudo ./rollout-test.sh               # 再跑这个：真换版本（本地造 tag，不联网）
sudo ./rollout-test.sh --bad         # 最后跑这个：发坏镜像，验证旧版本不被删
```

三种模式各自证明什么：

| 模式 | 做了什么 | 证明的事 |
|---|---|---|
| `--restart` | `kubectl rollout restart` | 「换 Pod」这个动作本身不中断（走的是和换镜像完全相同的 RollingUpdate 路径） |
| 默认 | `k3s ctr images tag` 造新 tag → `set image` | 「换版本」不中断。本地已有镜像层，`IfNotPresent` 不会去 registry 拉，所以不需要联网、不需要 build |
| `--bad` | 发一个拉不到的 tag | 「坏版本发不出去」——新 Pod 起不来时旧 Pod 一个都不会被删，这正是 `maxUnavailable: 0` 唯一能挡住的事故 |

脚本自己在后台起 `rollout-watch.sh`（100ms 一次持续打压），滚完自动停采样、解析汇总、给结论，退出码 0 = 通过。

**判据**：

```
✓ 通过：812 次请求全部 200，滚动更新期间服务无中断
```

失败时会打出失败明细（前 10 条），并用 `✗ 未通过` + 退出码 1 结束。

> 为什么不看 `kubectl rollout status` 就下结论：它只说明「Pod 都就绪了」，
> 期间掉 3 个请求它照样 Success。必须有外部持续打压才能下判断。

> 默认模式结束后，线上跑的是本地测试 tag（形如 `vtest-20261023-103000`），
> 它不在任何 registry 上。要恢复原版本，脚本末尾会打印现成的 `kubectl set image` 命令。
> `app.yml` 里的 image 没动，下次 apply 会自动退回原镜像。

---

## 3. 阶段二：加机器（2 台、3 台……10 台，动作完全一样）

### 【每台新节点】执行

```bash
cd ~/k8s/k3s-single
sudo ./join-server.sh 10.0.3.13 <node-token>
```

token 在 node1 上取：`sudo cat /var/lib/rancher/k3s/server/node-token`

**不用改 `cluster.env`**：脚本按「到 apiserver 的路由」自动探测本机 IP 写进 `--node-ip`。

**判据**：出现 `✓ <本机IP>，将加入 10.0.3.13 所在集群`，最后是 `✓ <本机IP> 已加入集群`。

### 【node1】确认

```bash
kubectl get nodes -o wide          # 全部 Ready，ROLES 都是 control-plane,etcd,master
kubectl get pods -o wide           # 注意：Pod 仍然全在 node1，这是正常的
```

> **关键**：加节点不会自动迁移已有 Pod。k8s 只会在「新建 Pod」时才考虑新节点。所以下一步必须主动触发一次重分布。

---

## 4. 阶段三：收敛

### 【node1】执行

```bash
cd ~/k8s/k3s-single
sudo ./scale-out.sh --dry-run     # 先看计划
sudo ./scale-out.sh               # 真跑
```

它按固定顺序做三件事：

1. 检查每个 Ready 节点上有没有就绪副本，没有就 `rollout restart` 触发重分布（走 `maxUnavailable: 0`，不中断）
2. 把「有副本」的节点写进 nginx upstream
3. `nginx -t` 通过后 `reload`

**顺序不能反**：`externalTrafficPolicy: Local` 下，没有 Pod 的节点端口会直接 REJECT。先加 upstream 再分布，等于让 nginx 每个请求先打到必失败的地址。

**判据**：

```bash
kubectl get pods -o wide          # 三台各 1 个（1-1-1）
curl -s http://127.0.0.1:8080/v1/test?name=out-$(date +%H%M%S)
```

---

## 5. 阶段四：验证「关一台照常服务」

### 【宿主机】开观测窗口

```bash
cd ~/jing.work/consul-demo
URL='http://localhost:30081/v1/test?name=ha-{TS}' DURATION_SEC=180 INTERVAL_MS=100 \
  ./k8s/rollout-watch.sh
```

> `30081` 换成你映射到 node1 `8080` 的那条规则。

### 【虚拟机控制台】关掉 node3

**判据**：

| 时刻 | 预期 |
|---|---|
| 关机瞬间 | 最多 1 个请求变慢（约 1 秒，`proxy_connect_timeout`），然后自动转到其他节点 |
| 之后 | 连续 200，不出现 FAIL |
| 汇总 | `失败 0` 或最多 1 次 |

原理：node3 整机消失后 SYN 无人应答，nginx 在 1 秒后判定连接失败，`proxy_next_upstream` 立刻换到 node2 或 node1，同时 `max_fails=1` 把 node3 摘除。**不需要等 k8s 那 40 秒的 `node-monitor-grace-period`**。

### 【虚拟机控制台】开回 node3

判据：约 2 秒内（`fail_timeout=2s` 到期后重新试探）流量重新分到 node3，观测窗口继续 0 失败。

### 对 node2 重复一次

结果应完全一致。

### ⚠️ 不要在这次演练里关 node1

**nginx 装在 node1 上，关掉它等于把入口一起关掉，全站不可用**——这不是 k8s 的问题，是「入口和计算同机」的必然结果，也是单机起步方案的固有单点。

要连 node1 也能关，需要额外一层，二选一：

| 方案 | 做法 | 代价 |
|---|---|---|
| 独立入口机 | 第 4 台只跑 nginx（就是你之前 `.11` 那套） | 多一台机器 |
| keepalived + VIP | 三台都装 nginx，VIP 在主节点间漂移 | 配置复杂，VM 网络要允许 VRRP |

对客户交付来说，起步阶段接受这个单点是合理的；等客户上到 3 台，再补入口高可用。

---

## 6. 阶段五：验证零中断发版（3 台版）

### 【node1】执行

```bash
cd ~/k8s
./deploy.sh                # 自动找最新 tag 并发版
```

配合宿主机上的 `rollout-watch.sh`，判据同样是 `失败 0`。

发版过程中注意 `kubectl get pods -o wide`：新 Pod 应该是 1-1-1 铺开，不是 2-1-0。这靠的是 `app.yml` 里的 `matchLabelKeys: [pod-template-hash]`。

---

## 7. 为什么这套能做到不停机

| 环节 | 机制 | 位置 |
|---|---|---|
| 滚动更新不中断 | `maxUnavailable: 0` + `readinessProbe` + `preStop sleep 5` | `app.yml` |
| 新 Pod 均匀铺开 | `topologySpreadConstraints` + `matchLabelKeys` | `app.yml` |
| 节点挂了能秒级摘除 | `externalTrafficPolicy: Local` + `max_fails=1 fail_timeout=2s` | Service + nginx |
| 加机器不影响存量 | 新节点 join 只扩容可调度池，不重建任何 Pod | k3s 本身 |
| 扩容时流量不断 | 先重分布（`maxUnavailable: 0`）再 `reload`（平滑） | `scale-out.sh` |
| 将来加 server 不用重启 | 起步就用 `--cluster-init`（embedded etcd） | `install-single.sh` |

---

## 8. 排错对照

| 现象 | 原因 | 处理 |
|---|---|---|
| `install-single.sh` 报「本机没有 10.0.3.13」 | `cluster.env` 的 IP 和实际不符 | 改 `NODE1_IP` |
| Pod 一直 `ImagePullBackOff` | 节点拉不到 Docker Hub | 在有网的机器 `docker save` 后 `k3s ctr images import` |
| `join-server.sh` 报连不上 6443 | node1 没起 / 防火墙 | `systemctl is-active k3s`、放行 6443/tcp、8472/udp |
| `scale-out.sh` 说某节点没副本 | 资源不足，Pod 调度不上去 | `kubectl describe node <名>` 看 Allocated resources |
| 关节点后有 1 个请求慢 1 秒 | `proxy_connect_timeout 1s` 在等死节点的 SYN | 正常现象，要更快就降到 500ms |
| 关节点后出现 502 | 该节点 `iptables` 残留指向已删 Pod | 属 `timeout server` 场景，已由 `proxy_next_upstream` 兜住；仍有则调 `preStop` 到 8~10 秒 |
| `nginx -t` 报 upstream 未定义 | `00-upstream-*.conf` 没生成 | 重跑 `scale-out.sh` |
| 多台 Ready 但 Pod 全在 node1 | 加节点不会迁移已有 Pod | 正常，跑 `scale-out.sh` |

---

## 9. 清理

**【每台都执行】**

```bash
sudo /usr/local/bin/k3s-uninstall.sh
sudo apt-get purge -y nginx
sudo rm -f /etc/nginx/conf.d/consul-demo.conf /etc/nginx/conf.d/00-upstream-consul-demo.conf
```
