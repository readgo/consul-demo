# 部署说明（服务器上看的）

这个目录里只有运行需要的东西，没有源码、没有开发脚本。

---

## 一句话

中间件装一次，之后不用管。加机器就在新机器上执行一条命令，老机器不用改任何配置。

---

## 怎么放到服务器上

把这个目录整体拖到服务器，建议放到家目录并命名为 `deploy-consul-demo`：

```
~/deploy-consul-demo/
```

WindTerm / FileZilla / scp 都行。放好之后下面所有命令都在这个目录里执行。

---

## 目录内容

```
deploy-consul-demo/
├── README.md        本文件
├── VERSION.txt      这包是什么时候打的
├── deploy.sh        入口，选装哪块
├── config.ini.example  配置模板（不改这个）
├── config.ini          实际用的配置，第一次运行时自动从模板生成
├── lib/common.sh    三个脚本共用
├── roles/
│   ├── center/      注册中心
│   ├── gateway/     网关
│   └── service/     业务应用
└── image/           应用镜像包
```

---

## 三块功能，想装哪块装哪块

| 命令 | 装什么 | 在哪台机器 | 装几次 |
|---|---|---|---|
| `sudo ./deploy.sh center` | 注册中心 | 挑一台固定的 | 一次，以后不用管 |
| `sudo ./deploy.sh gateway` | 网关 | 接流量的那台 | 一次 |
| `sudo ./deploy.sh service` | 业务应用 | 每台业务机 | 每台一次 |
| `sudo ./deploy.sh all` | 三块装同一台 | 单机演示 | 一次 |
| `./deploy.sh status` | 看当前机器装了什么 | 任意 | 随时 |
| `./deploy.sh init` | 只生成 `config.ini`，不装任何东西 | 任意 | 可选 |

前置：装好 docker（含 compose 插件）和 nginx。

---

## 唯一要改的文件：`config.ini`

刚拿到这个包时**没有** `config.ini`，只有模板 `config.ini.example`。执行任意 `deploy.sh` 命令时会自动从模板生成一份 `config.ini`（用默认值），也可以先手动生成：

```bash
./deploy.sh init
```

生成后就可以编辑 `config.ini` 了。**已经存在的 `config.ini` 不会被覆盖**，改多少次都安全。

```bash
# 注册中心在哪。这台就是注册中心就留默认；在别的机器就填那台的内网地址
REGISTRY=http://127.0.0.1:8500

# 本机对外地址。留空自动探测，探测不准才手工填
MY_IP=

# 业务应用端口
APP_PORT=3020

# 网关对外端口
SITE_PORT=8088

# 服务名
SERVICE_NAME=consul-demo
```

> `config.ini` 只影响本机，不会同步到别的机器。加机器时那份 `config.ini` 是新生成的，要单独改 `REGISTRY`。

---

## 单机部署

```bash
sudo ./deploy.sh all

# 让 nginx 认这个目录（手动，只做一次）
echo "include $(pwd)/roles/gateway/conf.d/*.conf;" \
  | sudo tee /etc/nginx/conf.d/consul-demo.conf
sudo nginx -t && sudo nginx -s reload

# 验证
curl -s "http://$(hostname -I | awk '{print $1}'):8088/api/demo/v1/test?name=hello"
```

最后一条返回 `hello:hello` 就成了。

> **顺序**：先跑 `deploy.sh`（它会把后端地址列表生成出来），再 reload nginx。
> 反过来做，nginx 会因为找不到后端而报错。

---

## 双机部署

**第一台**（注册中心 + 网关）：

```bash
sudo ./deploy.sh center
sudo ./deploy.sh gateway

echo "include $(pwd)/roles/gateway/conf.d/*.conf;" \
  | sudo tee /etc/nginx/conf.d/consul-demo.conf
sudo nginx -t && sudo nginx -s reload
```

**第二台**（业务机）：

```bash
./deploy.sh init                                  # 先有 config.ini 才能改
sed -i 's|^REGISTRY=.*|REGISTRY=http://第一台的内网IP:8500|' config.ini
sudo ./deploy.sh service
```

回第一台 reload 一次 nginx，流量就分到两台了。

**第一台的配置文件一个字都没改。**

加第三、第四台同理：拷目录 → 改 `config.ini` 那一行 → `sudo ./deploy.sh service` → 网关 reload。

---

## 加机器 / 删机器

| 动作 | 要改配置吗 | 要做的事 |
|---|---|---|
| 加一台业务机 | 不用 | 新机器上 `sudo ./deploy.sh service`，然后网关 reload 一次 |
| 删一台业务机 | 不用 | 那台执行 `docker rm -f <容器名>`，几秒后自动从列表消失 |
| 同机再加一个实例 | 不用 | `sudo ./deploy.sh service 2`，端口自动变 3021 |

---

## 验收

| # | 命令 | 期望 |
|---|---|---|
| 1 | `./deploy.sh status` | 三块分别显示 Up 或「（本机没装）」 |
| 2 | `curl -s localhost:8500/v1/status/leader` | `"<本机内网IP>:8300"` |
| 3 | `curl -s localhost:8500/v1/catalog/service/consul-demo` | 地址是内网 IP，**不是 127.0.0.1** |
| 4 | `cat roles/gateway/conf.d/backends.conf` | 每台业务机一行 `server` |
| 5 | `curl -s "http://<本机IP>:8088/api/demo/v1/test?name=x"` | `hello:x` |
| 6 | 加一台业务机后再看 `backends.conf` | 自动多一行 |

---

## 常见问题

| 现象 | 怎么办 |
|---|---|
| 找不到 `config.ini` | 正常，包里只带 `config.ini.example`。跑一次 `./deploy.sh init` 就有了 |
| 报「连不上注册中心」 | 3 秒就报，说明地址或端口不通。对照 `config.ini` 里的 `REGISTRY`；远端要放通 8500 |
| 报「还没准备好」 | 能连上但没选出主，等 30 秒再执行 |
| 报到成功，但网关里是 `127.0.0.1` | `config.ini` 里 `MY_IP` 填错了，或探测到虚拟网卡。手工填真实内网地址 |
| 列表变了但访问没变化 | 忘了 reload：`sudo nginx -s reload` |
| 访问 502 | 看 `backends.conf` 有没有 server 行；有就直连那个地址试 `curl <地址>/healthz` |
| 注册报 `permission denied` | `sudo chmod 777 roles/center/data/center` |

---

## 关于 nginx

脚本**不改**宿主机的 nginx 配置，只把配置文件准备好。上面那两条命令需要你自己敲。

为什么不做成自动的：容器里的程序给宿主机 nginx 发重启信号会被系统拦住，硬要做就得往宿主机装常驻服务，那等于改了系统配置。
