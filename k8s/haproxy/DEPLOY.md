# nginx（入口）+ HAProxy（主动检查）部署

**目标机器**：`10.0.3.11`（Ubuntu 26.04），系统自带 nginx 保持原始状态。

**原则**：80 端口一个字节都不改，所有新业务跑在新端口，由主人自行映射到宿主机。

---

## 端口规划

| 端口 | 归属 | 绑定地址 | 是否对外 |
|---|---|---|---|
| 80 | 系统 nginx 原始配置 | `0.0.0.0` | 保持原样，不动 |
| 8080 | nginx 新增 server（新入口） | `0.0.0.0` | 走宿主机映射 |
| 8081 | HAProxy 前端 | `127.0.0.1` | 否，只给本机 nginx |
| 8404 | HAProxy stats | `127.0.0.1` | 否，经 nginx 的 `/haproxy-status` 暴露 |

链路：

```
client → nginx:8080 ─┬─ /haproxy-status → 127.0.0.1:8404
                     └─ /               → 127.0.0.1:8081 (HAProxy)
                                            └─ 主动检查 500ms/fastinter200ms/fall2
                                               → 10.0.3.8/9/10:30080
```

## 文件映射

| 仓库文件 | 复制到 .11 的位置 |
|---|---|
| `k8s/haproxy/haproxy.cfg` | `/etc/haproxy/haproxy.cfg` |
| `k8s/nginx/consul-demo.conf` | `/etc/nginx/conf.d/consul-demo.conf` |

两个文件用 WindTerm 的 SFTP 上传到 `.11` 的 `~/`，再执行 `install` 复制。

---

## 1. 装 HAProxy，装完立刻停

```bash
sudo apt update
sudo apt install -y haproxy
sudo systemctl stop haproxy 2>/dev/null || true
```

必须先停：Ubuntu 默认的 `haproxy.cfg` 里就是 `bind *:80`，跟 nginx 直接撞车，
装完自动启动会失败并反复重启。

**判据**：`haproxy -v` 有版本输出。

## 2. 放配置文件

```bash
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.orig

sudo install -m 644 ~/haproxy.cfg      /etc/haproxy/haproxy.cfg
sudo install -m 644 ~/consul-demo.conf /etc/nginx/conf.d/consul-demo.conf
```

用 `install` 而不是 `cp`：一次把权限设成 644，避免 nginx 读不到。

**判据**：`grep -n timeout.connect /etc/haproxy/haproxy.cfg` 显示 `300ms`。

## 3. 校验并启动 HAProxy

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl enable --now haproxy
sudo systemctl status haproxy --no-pager
sudo ss -lntp | grep -E '8081|8404'
```

**判据**：`Configuration file is valid` → `active (running)` → 8081、8404 都在监听。

## 4. nginx 加载新配置

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo ss -lntp | grep -E ':80 |:8080 '
```

**判据**：`test is successful`，80 和 8080 同时在监听。用 `reload` 不用 `restart`，
80 上已有连接不断。

## 5. 本机三层验证

```bash
curl -s http://127.0.0.1:8081/v1/test?name=hp-$(date +%H%M%S)
curl -s http://127.0.0.1:8080/v1/test?name=ng-$(date +%H%M%S)
curl -s http://127.0.0.1:8080/nginx-health
curl -s http://127.0.0.1:8080/haproxy-status | grep -E 'k3s-[123]'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
```

**判据**：前两条返回 `hello:hp-<ts>` / `hello:ng-<ts>`；状态页三台全 `UP`；
最后一条仍是 200 —— 这是「80 没被动过」的证据。

## 6. 宿主机：加端口转发

在虚拟化软件里把 `30081` 的目标从 `.11:80` 改成 `.11:8080`，或另开 `30082 → .11:8080`。

8081 与 8404 绑的是 `127.0.0.1`，**不要映射**，映射了也连不上（故意的，防止绕过 nginx）。

```bash
# 宿主机
curl -s "http://localhost:30081/v1/test?name=host-$(date +%H%M%S)"
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30081/haproxy-status
```

浏览器看状态页：`http://localhost:30081/haproxy-status`

## 7. 验证主动检查

```bash
watch -n1 'curl -s http://127.0.0.1:8080/haproxy-status | grep -E "k3s-[123]"'
```

另开一台机器停掉 k3s-3（10.0.3.10）。

**判据**：**0.7 秒内** `k3s-3` 从 `UP` 变 `DOWN`（`fastinter 200ms` 的功劳）；开机 1 秒内回 `UP`。

## 8. 零中断复验

```bash
# 宿主机
cd ~/jing.work/consul-demo
URL='http://localhost:30081/v1/test?name=jing-{TS}' \
DURATION_SEC=180 INTERVAL_MS=100 \
./k8s/rollout-watch.sh
```

期间交替停/起 k3s-3。**判据**：汇总 `失败 0`，退出码 0。

---

## 三个坑

### 坑 1：Ubuntu 的 haproxy 默认配置就绑 `*:80`

`apt install haproxy` 装完会自动启动，默认 `haproxy.cfg` 是 `bind *:80`，跟 nginx 撞车。
必须装完立刻 `stop`，先换配置再启动。乱序执行会看到 `systemctl status haproxy` 一直是 failed。

### 坑 2：漏的那 1 次不是连接超时，是「TCP 连上了但一个字节都不回」

实测记录：174 次请求挂 1 次，`curl rc=28`，报 `Operation timed out after 3002
milliseconds with 0 bytes received`，中断 3.0s。

`0 bytes received` 是关键证据 —— 说明 **TCP 连接是通的**，只是对方永远不回数据。
所以凶手不是 `timeout connect`，而是 `timeout server`。

机制：Pod 被删除后，kube-proxy 的 iptables 规则还会残留 1~2 秒。这期间请求打到
`10.0.3.10:30080`，**连接由 kube-proxy 接受（立即成功）**，然后 DNAT 到一个已经
不存在的 Pod IP —— 于是进入黑洞：连得上，没有响应。

这就是为什么「缩短 `timeout connect`」完全无效：连接根本没失败。

正确配置：

| 层 | 参数 | 值 | 作用 |
|---|---|---|---|
| HAProxy | `timeout server` | `2s` | **核心**：2s 内没响应就判失败，轮得到重试 |
| HAProxy | `retry-on` | `conn-failure empty-response response-timeout` | 让「空响应/响应超时」也能重试，默认只重试连接失败 |
| HAProxy | `retries` + `option redispatch` | `3` | 换一台重试 |
| HAProxy | `inter` / `fastinter` | `500ms` / `200ms` | 摘除窗口从 2s 压到约 0.7s |
| nginx | `proxy_next_upstream_tries` | `2` | 只留 1 次兜底重发 |

**代价必须说清**：`timeout server 2s` 意味着超过 2 秒的业务会被切断。
demo 的 `/v1/test` 是 3ms，没问题；真实的长接口（60s 那种）不能共用这个 backend，
必须按路径分流到另一个 backend：

```haproxy
frontend fe_consul_demo
    bind 127.0.0.1:8081
    acl is_slow path_beg /v1/long-task
    use_backend be_slow       if is_slow
    default_backend be_fast

backend be_slow
    timeout server 300s       # 长业务：只保命，不做快速失败转移
    server k3s-1 10.0.3.8:30080  check
    ...
```

「快接口快速失败转移」和「长接口不被打断」在物理上是互斥的，只能靠分流，
不能靠一个超时值同时满足。

若业务有非幂等 POST，把 nginx 的兜底改成按方法区分：

```nginx
map $request_method $upstream_retry {
    GET     error timeout http_502 http_503;
    HEAD    error timeout http_502 http_503;
    default off;
}
# location 里改用：proxy_next_upstream $upstream_retry;
```

### 坑 3：`timeout client` / `timeout server` 会切 60s 业务

三层超时是**串联**的，最短的那个决定上限：

| 层 | 配置项 | demo 值 | 真实 60s 业务应为 |
|---|---|---|---|
| nginx → HAProxy | `proxy_read_timeout` | 60s | ≥ 65s |
| HAProxy → 后端 | `timeout server` | **2s**（见坑 2） | 长接口单开 backend，300s |
| HAProxy → 客户端 | `timeout client` | 60s | ≥ 65s |

只改一处没用，其余几处会先把连接断掉。`timeout connect` 是例外，它只负责握手，越短越好。

---

## 回滚（只删新增文件，80 从未被碰）

```bash
sudo rm -f /etc/nginx/conf.d/consul-demo.conf
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl disable --now haproxy
```

---

## 报错对照

| 现象 | 原因 | 处理 |
|---|---|---|
| `cannot bind socket (Address already in use) [0.0.0.0:80]` | 还在用 haproxy 默认配置 | 回第 2 步 |
| `curl 8080` 返回 502 | 三个后端全 down | 看 `/haproxy-status`，查节点与 `externalTrafficPolicy: Local` |
| `/haproxy-status` 404 | `stats uri` 与 nginx location 前缀不一致 | 两边都改成 `/haproxy-status` |
| 状态页一直 UP 但业务 502 | 缺 `http-check expect status 200`，302 被当健康 | 补上 |
| 停节点后偶发 1 次超时 | `timeout connect` 太长，重试没跑完 | 见坑 2 |
| 80 访问变了 | 有人改了 sites-enabled | `git` 里没有该文件，检查是否有其他 conf |
