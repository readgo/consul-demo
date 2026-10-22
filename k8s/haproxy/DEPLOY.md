# nginx（入口）+ HAProxy（主动检查）部署步骤

**目标机器**：`10.0.3.11`（Ubuntu 26.04），系统自带 nginx 保持原始状态。

**核心原则**：80 端口一个字节都不改，所有新业务跑在新端口，由主人自行映射到宿主机。

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
client → nginx:8080 ─┬─ /haproxy-status → 127.0.0.1:8404   （状态页）
                     └─ /               → 127.0.0.1:8081   （HAProxy）
                                            └─ 主动检查 1s/fall2/rise2
                                               → 10.0.3.8/9/10:30080
```

---

## 1. 装 HAProxy（装完立刻停，原因见下方「坑 1」）

```bash
sudo apt update
sudo apt install -y haproxy
sudo systemctl stop haproxy 2>/dev/null || true
```

判据：`haproxy -v` 有版本输出。

## 2. 写 HAProxy 配置

```bash
sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<'EOF'
global
    log /dev/log local0
    maxconn 4096

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 1s
    timeout client  60s
    timeout server  60s

frontend fe_consul_demo
    bind 127.0.0.1:8081
    option forwardfor
    default_backend be_consul_demo

backend be_consul_demo
    option httpchk GET /healthz
    http-check expect status 200
    option redispatch
    retries 2
    default-server inter 1s fall 2 rise 2
    server k3s-1 10.0.3.8:30080  check
    server k3s-2 10.0.3.9:30080  check
    server k3s-3 10.0.3.10:30080 check

listen stats
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /haproxy-status
    stats refresh 2s
    stats show-legends
EOF
```

## 3. 校验并启动 HAProxy

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl enable --now haproxy
sudo systemctl status haproxy --no-pager
```

判据：
- 第一行输出 `Configuration file is valid`
- `Active: active (running)`
- `sudo ss -lntp | grep -E '8081|8404'` 两个端口都在监听

## 4. 写 nginx 新入口配置

```bash
sudo tee /etc/nginx/conf.d/consul-demo.conf >/dev/null <<'EOF'
upstream haproxy_local {
    server 127.0.0.1:8081;
    keepalive 64;
}

server {
    listen 8080;
    server_name _;

    access_log /var/log/nginx/consul-demo.access.log;
    error_log  /var/log/nginx/consul-demo.error.log;

    location /haproxy-status {
        proxy_pass http://127.0.0.1:8404;
        proxy_set_header Host $host;
    }

    location / {
        proxy_pass http://haproxy_local;
        proxy_http_version 1.1;
        proxy_set_header Connection        "";
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 1s;
        proxy_read_timeout    60s;

        proxy_next_upstream off;
    }

    location = /nginx-health {
        access_log off;
        return 200 "ok\n";
    }
}
EOF
```

## 5. 校验并 reload nginx（用 reload，不用 restart）

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo ss -lntp | grep -E ':80 |:8080 '
```

判据：
- `nginx: configuration file /etc/nginx/nginx.conf test is successful`
- 80 和 8080 都在监听
- **reload 不会断掉 80 上已有的连接**，原始站点无影响

## 6. 本机三层验证

```bash
# ① HAProxy 直连（绕过 nginx）
curl -s http://127.0.0.1:8081/v1/test?name=hp-$(date +%H%M%S)

# ② 经 nginx 新入口
curl -s http://127.0.0.1:8080/nginx-health
curl -s http://127.0.0.1:8080/v1/test?name=ng-$(date +%H%M%S)

# ③ 状态页
curl -s http://127.0.0.1:8080/haproxy-status | grep -E 'k3s-[123]'

# ④ 原始 80 是否纹丝不动
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
```

判据：①② 返回 `hello:hp-<ts>` / `hello:ng-<ts>`；③ 三台 `UP`；④ 仍是原始欢迎页的 200。

## 7. 宿主机端口映射（在宿主机/虚拟化软件里做，不是 .11 上）

新增或修改一条**端口转发**：

| 宿主机端口 | 目标 | 说明 |
|---|---|---|
| 30081（或另开 30082） | `10.0.3.11:8080` | 新入口，指向 nginx 的 8080 |

> 8081 和 8404 绑的是 `127.0.0.1`，**不要映射**，映射了也连不上（这是故意的，防止绕过 nginx）。

宿主机验证：

```bash
curl -s "http://localhost:30081/v1/test?name=host-$(date +%H%M%S)"
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30081/haproxy-status
```

浏览器打开 `http://localhost:30081/haproxy-status` 看状态页。

## 8. 验证主动检查（这套架构的全部意义）

```bash
# .11 上盯状态页，每 2 秒刷新
watch -n1 'curl -s http://127.0.0.1:8080/haproxy-status | grep -E "k3s-[123]"'
```

另开一台机器，**停掉 k3s-3**（10.0.3.10）。

判据：**2 秒内** `k3s-3` 状态从 `UP` 变 `DOWN`，`check fall` 计数到 2；
节点起来后 2 秒内自动回 `UP`。

期间 `curl 8080` 应该一直 200，且**没有一次请求落到死节点**。

## 9. 零中断复验

宿主机执行：

```bash
cd ~/jing.work/consul-demo
URL='http://localhost:30081/v1/test?name=jing-{TS}' \
DURATION_SEC=180 INTERVAL_MS=100 \
./k8s/rollout-watch.sh
```

期间交替停/起 k3s-3。判据：汇总 `失败 0`，退出码 0。

---

## 三个必须知道的坑

**坑 1：Ubuntu 的 haproxy 默认配置就绑 `*:80`**

`apt install haproxy` 装完会自动启动，而它默认的 `haproxy.cfg` 里是 `bind *:80`，
跟系统 nginx 直接撞车 → haproxy 启动失败。所以第 1 步装完立刻 `stop`，
先把配置换成 8081 再启动。乱序执行的话会看到 `systemctl status haproxy` 一直是 failed。

**坑 2：`proxy_next_upstream` 不关，请求数会翻倍**

nginx 的上游只有一个（HAProxy）。如果保留 `proxy_next_upstream error timeout`，
一次连接失败会被 nginx 重发 + HAProxy 的 `retries 2` 再重发，一个客户端请求变 4 个后端请求。
重试职责必须**只留给 HAProxy**，因为它知道哪台后端健康。

**坑 3：`timeout client` / `timeout server` 会切 60s 业务**

HAProxy 的三个超时和 nginx 的 `proxy_read_timeout` 是**串联**的，最短的那个决定上限：

| 层 | 配置项 | demo 值 | 真实 60s 业务应为 |
|---|---|---|---|
| nginx → HAProxy | `proxy_read_timeout` | 60s | ≥ 65s |
| HAProxy → 后端 | `timeout server` | 60s | ≥ 65s |
| HAProxy → 客户端 | `timeout client` | 60s | ≥ 65s |

只改一处没用，其余几处会先把连接断掉。

---

## 回滚（只删新增文件，80 从未被碰过）

```bash
sudo rm -f /etc/nginx/conf.d/consul-demo.conf
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl disable --now haproxy
```

删完 8080 消失，80 上的原始站点始终没变。

---

## 报错对照

| 现象 | 原因 | 处理 |
|---|---|---|
| `haproxy -c` 报 `cannot bind socket (Address already in use) [0.0.0.0:80]` | 还在用默认配置 | 回第 2 步覆盖配置 |
| haproxy 起不来，`ss` 看不到 8081 | 配置没写对或被默认配置覆盖 | `haproxy -c` 看具体行号 |
| `curl 8080` 502 | HAProxy 后端全 down | 看 `/haproxy-status`，检查 k3s 节点和 `externalTrafficPolicy: Local` |
| `/haproxy-status` 404 | haproxy 的 `stats uri` 与 nginx 的 location 前缀不一致 | 两边都改成 `/haproxy-status` |
| 状态页一直是 UP，但业务已经 502 | 只写了 `option httpchk`，没写 `http-check expect status 200` | 补上 expect |
| 停节点后 nginx 返回 503 | 三个后端全被摘了 | 检查 Pod 是否 1-1-1 分布 |
