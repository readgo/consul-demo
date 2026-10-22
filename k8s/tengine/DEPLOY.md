# Tengine 落地 Demo（全新机器，从零到跑通）

适用：一台干净的 Ubuntu 26.04 机器（本文档对应 `10.0.3.11`），装好系统自带 nginx、
无任何自定义配置。全程 7 步，线性执行，不需要判断分支。

最终形态：Tengine 占 80，主动健康检查三个 k3s 节点端口，`/status` 实时看 up/down。

---

## 3 条硬约束（只有这 3 条，其它都是顺带的）

| # | 约束 | 违反的后果 |
|---|---|---|
| 1 | 编译必须显式带 `--with-http_upstream_check_module` | `nginx -t` 报 `unknown directive "check"` |
| 2 | 编译必须带 `-Wno-error` | gcc 15 默认 `-std=gnu23`，隐式声明直接编译失败 |
| 3 | 80 端口只能有一个 owner | Tengine 启动报 `bind() to 0.0.0.0:80 failed (98)` |

---

## 1. 装编译依赖

```bash
sudo apt update
sudo apt install -y build-essential libpcre2-dev zlib1g-dev libssl-dev curl
```

判据：`gcc --version` 输出 ≥ 13（26.04 是 15）。

---

## 2. 取源码

```bash
cd ~
curl -LO https://tengine.taobao.org/download/tengine-3.1.0.tar.gz
tar xf tengine-3.1.0.tar.gz
cd tengine-3.1.0
```

判据：`ls -lh ~/tengine-3.1.0.tar.gz` 约 3~4 MB，解压目录里能看到 `configure`。

---

## 3. 编译安装

```bash
cd ~/tengine-3.1.0

./configure --prefix=/usr/local/tengine \
  --with-http_stub_status_module \
  --with-http_realip_module \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_upstream_check_module \
  --with-cc-opt="-O2 -Wno-implicit-function-declaration -Wno-error"

make -j$(nproc)
sudo make install
```

判据两条，都要过：

```bash
# ① configure 阶段输出里必须有这一行
#    + ngx_http_upstream_check_module was configured

# ② 二进制里真的有模块
strings /usr/local/tengine/sbin/nginx | grep -c upstream_check   # 必须 > 0
```

② 为 0 就是模块没编进去，后面 `check` 指令一定报错。

---

## 4. 写配置（一次性粘贴）

```bash
sudo tee /usr/local/tengine/conf/nginx.conf >/dev/null <<'EOF'
worker_processes auto;
pid logs/tengine.pid;
error_log logs/error.log warn;

events { worker_connections 1024; }

http {
    include mime.types;
    default_type application/octet-stream;
    sendfile on;
    server_tokens off;

    log_format main '$remote_addr [$time_local] "$request" $status '
                    'rt=$request_time up=$upstream_addr st=$upstream_status';
    access_log logs/access.log main;

    upstream consul_demo {
        server 10.0.3.8:30080;
        server 10.0.3.9:30080;
        server 10.0.3.10:30080;

        check interval=1000 rise=2 fall=2 timeout=1000 type=http;
        check_http_send "GET /healthz HTTP/1.0\r\nHost: localhost\r\n\r\n";
        check_http_expect_alive http_2xx http_3xx;

        keepalive 32;
    }

    server {
        listen 80 default_server;
        server_name _;

        location / {
            proxy_pass http://consul_demo;
            proxy_http_version 1.1;
            proxy_set_header Connection        "";
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;

            proxy_connect_timeout 1s;
            proxy_read_timeout    5s;
            proxy_next_upstream       error timeout http_502 http_503;
            proxy_next_upstream_tries 2;
        }

        location = /nginx-health { access_log off; return 200 "ok\n"; }

        location = /status {
            check_status;
            access_log off;
            allow 127.0.0.1;
            allow 10.0.3.0/24;
            deny all;
        }
    }
}
EOF
```

判据：`sudo /usr/local/tengine/sbin/nginx -t -c /usr/local/tengine/conf/nginx.conf`
输出 `syntax is ok` + `test is successful`。

> 此时会报 `bind() to 0.0.0.0:80 failed` 之外无其它错 —— 若报的是 `unknown directive "check"`，
> 说明第 3 步的模块没编进去，回第 3 步。

---

## 5. 注册 systemd 服务

```bash
sudo tee /etc/systemd/system/tengine.service >/dev/null <<'EOF'
[Unit]
Description=Tengine
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/usr/local/tengine/logs/tengine.pid
ExecStartPre=/usr/local/tengine/sbin/nginx -t -c /usr/local/tengine/conf/nginx.conf
ExecStart=/usr/local/tengine/sbin/nginx -c /usr/local/tengine/conf/nginx.conf
ExecReload=/usr/local/tengine/sbin/nginx -s reload -c /usr/local/tengine/conf/nginx.conf
ExecStop=/bin/kill -s QUIT $MAINPID
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
```

判据：`systemctl cat tengine | head -3` 有输出。

---

## 6. 让出 80（全程唯一一次「停」）

```bash
sudo systemctl disable --now nginx
sudo systemctl mask nginx
sudo ss -lntp | grep ':80 '
```

判据：`ss` **没有任何输出**。有输出说明还有别的进程占 80。

---

## 7. 启动并验证

```bash
sudo systemctl enable --now tengine
sudo systemctl status tengine --no-pager
```

判据：`Active: active (running)`。

```bash
curl -s http://127.0.0.1/nginx-health      # ok
curl -s http://127.0.0.1/status            # 三行 10.0.3.8/9/10 全 up
curl -s "http://127.0.0.1/v1/test?name=demo-$(date +%H%M%S)"
```

第三行返回 `hello:demo-<时间戳>` 即转发链路通。

---

## 8. 验证主动健康检查（这一条是 Tengine 的全部意义）

```bash
watch -n1 'curl -s http://127.0.0.1/status | grep -E "10\.0\.3\.(8|9|10)"'
```

另开一台机器，**停掉 k3s-3**（10.0.3.10）。

预期：**2 秒内** `10.0.3.10:30080` 从 `up` 变 `down`，`fall` 计数到 2；
节点起来后 **2 秒内**自动回 `up`。

- 与开源 nginx 被动检查的区别：被动检查要等真实请求失败一次才发现，
  那一次请求会多等 `proxy_connect_timeout`；主动检查在这一秒就摘掉了，请求一次都打不到死节点。
- `type=http` 必须显式写，默认 `tcp` 只探端口通不通，应用返回 500 也会判健康。

---

## 附：日志轮转与回滚

```bash
# 日志轮转（不配会无限增长）
sudo tee /etc/logrotate.d/tengine >/dev/null <<'EOF'
/usr/local/tengine/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0644 root root
    sharedscripts
    postrotate
        [ -f /usr/local/tengine/logs/tengine.pid ] && kill -USR1 $(cat /usr/local/tengine/logs/tengine.pid)
    endscript
}
EOF

# 回滚到系统 nginx
sudo systemctl stop tengine && sudo systemctl disable tengine
sudo systemctl unmask nginx && sudo systemctl enable --now nginx
```

---

## 附：报错对照

| 现象 | 原因 | 处理 |
|---|---|---|
| `unknown directive "check"` | 模块没编进去 | 回第 3 步，确认 configure 输出 |
| `bind() to 0.0.0.0:80 failed (98)` | 系统 nginx 还占着 80 | 回第 6 步 |
| `make` 报 implicit declaration | 少了 `-Wno-error` | 回第 3 步 |
| `configure: error: invalid option "--with-http_upstream_check_module"` | 该版本靠 `--add-module` 挂模块 | 换成 `--add-module=modules/ngx_http_upstream_check_module` |
| `configure: error: HTTP rewrite module requires the PCRE library` | 26.04 只有 pcre2 | 确认装了 `libpcre2-dev`；仍报错则 `--with-pcre=<pcre2 源码目录>` |
| `/status` 403 | 源 IP 不在 `allow` 网段（经 vm-nat 转发时会发生） | 从 .11 本机 curl；或把源 IP 加进放行列表 |

---

## 附：集群侧前提（已在本仓 `k8s/app.yml` 中）

- Service `externalTrafficPolicy: Local` —— 让「探节点端口」等价于「探该节点上的 Pod」，
  否则 kube-proxy 会把探测 DNAT 到别的健康 Pod，探活恒真。
- `topologySpreadConstraints` + `matchLabelKeys: [pod-template-hash]` 保证每个节点 1 个 Pod。
  若退化为 2-1-0，那个 0 的节点会被判 down 并整台摘除。
