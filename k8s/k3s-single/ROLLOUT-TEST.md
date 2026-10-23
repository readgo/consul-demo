# 滚动更新验证 · 五步操作卡

不看脚本、不猜逻辑，就是五步。每一步都写清楚：**在哪台敲 / 敲什么 / 该看到什么 / 怎么判通过**。

机器代号：

| 代号 | 是谁 | 提示符长这样 |
|---|---|---|
| **宿主机** | 你本地这台（跑观测脚本、有映射端口） | `jing@jing-office-PC:~$` |
| **node1** | k3s 那台虚拟机 | `jing@k3s-t1:~$` |

`kubectl` 都在 **node1** 上敲（宿主机没配 kubeconfig）。若提示找不到 `kubectl`，换成 `sudo k3s kubectl`。

---

## 第 1 步 · 更新前，当前是哪个版本

**【node1】**

```bash
kubectl -n default get deploy consul-demo \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"  就绪 "}{.status.readyReplicas}/{.spec.replicas}{"\n"}'

kubectl -n default get pods -o wide

# 当前 Pod 实际落盘的镜像 digest（第 4 步要拿来对照）
kubectl -n default get pods -l app=consul-demo \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' \
  | awk -F'sha256:' 'NF>1{print substr($2,1,12)}' | sort -u
```

**该看到**（以实际 tag 为准）：

```
wttcvs/consul-demo:v20261022-172323  就绪 3/3
NAME                           READY   STATUS    NODE
consul-demo-7c9f8b6d4-abcde    1/1     Running   k3s-t1
consul-demo-7c9f8b6d4-fghij    1/1     Running   k3s-t1
consul-demo-7c9f8b6d4-klmno    1/1     Running   k3s-t1
```

**记住三样东西**，后面第 4 步要对照：
- 当前 tag：`v20261022-172323`
- Pod 名的中间那段（ReplicaSet 哈希）：`7c9f8b6d4`
- 镜像 digest 前 12 位：`a71e0b93c4f2`（最后那条命令只输出一行，说明三个 Pod 用的是同一个镜像）

**判据**：`就绪 3/3`，三个 Pod 全 `Running`、全 `1/1`。不是这样就先别往下走。

---

## 第 2 步 · 起测试脚本（它会一直打请求）

**【宿主机】**，单独开一个窗口，让它一直跑：

```bash
cd ~/jing.work/consul-demo
URL='http://localhost:30084/v1/test?name=jing-{TS}' DURATION_SEC=300 INTERVAL_MS=100 \
  ./k8s/rollout-watch.sh
```

**它在干什么**：每 100ms 发一次 `GET /v1/test`，把状态码、耗时、响应体记下来；连续失败会聚合成「中断区间」。跑 300 秒或你按 `Ctrl+C` 时打印汇总。

**该看到**：一行行绿色的 `200`，行尾计数在涨：

```
[    0.0s] 2026-10-23 10:44:01.123  200   5ms  hello:jing-20261023-104401-124  1/1
[    0.1s] 2026-10-23 10:44:01.230  200   2ms  hello:jing-20261023-104401-231  2/2
```

**判据**：计数一直在涨、没有红色 `FAIL`。**这个窗口从现在起不要关，也不要按 `Ctrl+Z`。**

---

## 第 3 步 · 触发更新

**【node1】**，另开一个窗口（第 2 步那个窗口保持不动）。

先确认要用哪个 tag——两个选择：

```bash
# (a) 你有新 tag：换成它
kubectl -n default set image deploy/consul-demo \
  app=wttcvs/consul-demo:v20261023-110000

# (b) 暂时没有新 tag：先用「重建 Pod」代替，验证的是同一条滚动路径
kubectl -n default rollout restart deploy/consul-demo
```

然后盯着它滚完：

```bash
kubectl -n default rollout status deploy/consul-demo --timeout=180s
# 想看到 Pod 一个个换掉，另开一个：kubectl -n default get pods -w
```

**该看到**：

```
deployment "consul-demo" successfully rolled out
```

**判据**：出现上面这行。如果卡住不动超过 3 分钟，**先别管第 4 步**，跳到本文末尾「卡住怎么办」。

---

## 第 4 步 · 更新后，真的换成新版本了吗

**【node1】**

```bash
# ① Deployment 里写的镜像
kubectl -n default get deploy consul-demo \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# ② 每个 Pod 实际跑的镜像 + 实际落盘的 digest（这才是硬证据）
kubectl -n default get pods -l app=consul-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].image}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}' \
  | awk -F'\t' '{ id=$3; sub(/^.*sha256:/,"",id); printf "%-34s %-42s %s\n", $1, $2, substr(id,1,12) }'

# ③ 新旧 ReplicaSet 各剩多少副本
kubectl -n default get rs -l app=consul-demo
```

**为什么要看 digest**：`image` 那一列只是把 Deployment 里写的字符串抄了一遍，改完 Deployment 它立刻就变，**证明不了 Pod 真的换了**。`imageID` 是容器运行时实际落盘的镜像摘要，老版本和新版本一定不同。

**该看到**：① 和 ② 里的 tag 一致，都是新 tag；三行 digest 前 12 位**互相相同**、且和第 1 步记下的不同；③ 里新 ReplicaSet 是 `3`，旧的全是 `0`。

```
wttcvs/consul-demo:v20261023-110000

consul-demo-5d7f9c8b6-abcde   wttcvs/consul-demo:v20261023-110000   3f9a1c7b28de
consul-demo-5d7f9c8b6-fghij   wttcvs/consul-demo:v20261023-110000   3f9a1c7b28de
consul-demo-5d7f9c8b6-klmno   wttcvs/consul-demo:v20261023-110000   3f9a1c7b28de

NAME                     DESIRED   CURRENT   READY   AGE
consul-demo-5d7f9c8b6    3         3         3       1m     ← 新的
consul-demo-7c9f8b6d4    0         0         0       2h     ← 旧的，已归零
```

**判据**：三条都符合。只改 Deployment 而 Pod 的 digest 没变，= 没真发出去（镜像拉不下来时就是这样）。

---

## 第 5 步 · 确认测试脚本 0 失败

**【宿主机】**，回到第 2 步那个窗口，按 `Ctrl+C`（或等 300 秒自己结束）。

**该看到**：

```
════════════════════ 验证结果 ════════════════════
总请求       : 812
成功         : 812
失败         : 0  (0.00%)
最大响应耗时 : 43 ms

✓ 全部请求成功，滚动更新期间服务无中断
```

**判据**：`失败 : 0`。**不是 0 就往下看。**

---

## 失败/卡住怎么办

| 现象 | 含义 | 下一步 |
|---|---|---|
| 第 2 步一行都没有 / 立刻报错 | 入口不通，跟滚动更新无关 | `curl -sv http://localhost:30084/nginx-health`；看 node1 上 `systemctl status nginx` |
| 第 3 步卡住，Pod 显示 `ImagePullBackOff` | 新 tag 的镜像没拉到 node1 | node1 上 `sudo k3s crictl pull wttcvs/consul-demo:<tag>`；拉不动就是网络，用 `k3s ctr images import` 导入 |
| 第 3 步卡住，Pod 显示 `0/1 Running` | 起来了但健康检查不过 | `kubectl -n default describe pod <名字>`，看 Events 和 Probe 失败原因 |
| 第 4 步 Pod 还是旧 tag | 镜像拉不下来，默认 `IfNotPresent` 不会重拉 | 同上，先 `crictl pull` 再重试 |
| 第 5 步有几次 `FAIL 502` | 摘流量的瞬间有残留连接 | 看失败是否集中在 1~2 个请求、持续 <1 秒；`preStop` 从 5 秒加到 8 秒 |

---

## 附：三条命令版（已经熟了就用这个）

```bash
# 宿主机 窗口A
cd ~/jing.work/consul-demo && URL='http://localhost:30084/v1/test?name=jing-{TS}' \
  DURATION_SEC=300 INTERVAL_MS=100 ./k8s/rollout-watch.sh

# node1 窗口B
kubectl -n default get deploy consul-demo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n default set image deploy/consul-demo app=wttcvs/consul-demo:<新tag>
kubectl -n default rollout status deploy/consul-demo --timeout=180s
kubectl -n default get pods -l app=consul-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].image}{"\n"}{end}'
```
