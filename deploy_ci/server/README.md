# 部署说明（服务器上看的 · 拉镜像版）

这个目录里**只有文本文件**，没有源码、没有开发脚本、没有镜像包。
镜像由 CI 构建好推到 Docker Hub，服务器只负责拉下来跑。

---

## 一句话

中间件装一次，之后不用管。升级 = 改 `config.ini` 里的一行 `IMAGE_TAG`，再执行一次 `service`。

---

## 怎么放到服务器上

整个目录只有几十 KB，直接拷到服务器家目录，建议命名为 `deploy-consul-demo`：

```
~/deploy-consul-demo/
```

WindTerm / FileZilla / scp 都行。放好之后下面所有命令都在这个目录里执行。

> 服务器要能访问 Docker Hub。拉不动的话先确认：`docker pull hello-world`

---

## 目录内容

```
deploy-consul-demo/
├── README.md           本文件
├── deploy.sh           入口，选装哪块
├── config.ini.example  配置模板（不改这个）
├── config.ini          实际用的配置，第一次运行时自动从模板生成
├── lib/common.sh       三个脚本共用
└── roles/
    ├── center/         注册中心
    ├── gateway/        网关
    └── service/        业务应用
```

没有 `image/` 目录 —— 这是与离线 tar 包那套唯一的区别。

---

## 装哪块

| 命令 | 装什么 | 在哪台机器 | 装几次 |
|---|---|---|---|
| `sudo ./deploy.sh center` | 注册中心 | 挑一台固定的 | 一次，以后不用管 |
| `sudo ./deploy.sh gateway` | 网关 | 接流量的那台 | 一次 |
| `sudo ./deploy.sh service` | 业务应用 | 每台业务机 | 每台一次 |
| `sudo ./deploy.sh all` | 三块装同一台 | 单机演示 | 一次 |
| `sudo ./deploy.sh pull` | 只拉镜像，不启动 | 任意 | 可选，提前拉省时间 |
| `./deploy.sh status` | 看当前跑着什么、哪个版本 | 任意 | 随时 |
| `./deploy.sh init` | 只生成 `config.ini` | 任意 | 可选 |

前置：装好 docker（含 compose 插件）和 nginx。

---

## 唯一要改的文件：`config.ini`

刚拿到这个包时**没有** `config.ini`，只有模板 `config.ini.example`。执行任意 `deploy.sh` 命令时会自动从模板生成一份，也可以先手动生成：

```bash
./deploy.sh init
```

**已经存在的 `config.ini` 不会被覆盖**，改多少次都安全。

```bash
# 镜像从哪拉。IMAGE_REPO 必须和发布时用的 Docker Hub 账号一致
IMAGE_REPO=readgo/consul-demo
IMAGE_TAG=v20261021-104730

# 私有仓库才填，公开仓库留空。填了 token 记得 chmod 600 config.ini
#DOCKER_USERNAME=
#DOCKER_TOKEN=

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

> `config.ini` 只影响本机，不会同步到别的机器。加机器时那份是新生成的，要单独改 `REGISTRY`。

**`IMAGE_TAG` 别长期用 `latest`。** 出问题时 `status` 会告诉你线上是哪个版本，前提是你钉了具体 tag。

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

## 升级到新版本

发布那边（`deploy_ci/release/release.sh`）跑完会打印一个新的 tag，形如 `v20261021-104730`。服务器上：

```bash
sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=v20261021-104730|' config.ini
sudo ./deploy.sh service
```

脚本会先拉新镜像、清掉旧容器、起新的，最后打印 `版本已切换：旧 -> 新`。

**逐台升级**，不要几台一起动 —— 注册中心里始终留着一台旧版本在服务，网关的地址列表不会空。

## 回滚

tag 是不可变的，所以回滚就是把 `IMAGE_TAG` 改回上一个值，再跑一次 `service`：

```bash
sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=v20261020-183000|' config.ini
sudo ./deploy.sh service
```

比用 `latest` 靠谱得多 —— `latest` 会被覆盖，回不去。

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

回第一台 reload 一次 nginx，流量就分到两台了。**第一台的配置文件一个字都没改。**

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
| 1 | `./deploy.sh status` | 三块分别显示 Up 或「（本机没装）」，业务应用下面多一行 `镜像` |
| 2 | `./deploy.sh status` 最后一行 | `config.ini 里配的是 readgo/consul-demo:<tag>`，与容器实际镜像一致 |
| 3 | `curl -s localhost:8500/v1/status/leader` | `"<本机内网IP>:8300"` |
| 4 | `curl -s localhost:8500/v1/catalog/service/consul-demo` | 地址是内网 IP，**不是 127.0.0.1** |
| 5 | `cat roles/gateway/conf.d/backends.conf` | 每台业务机一行 `server` |
| 6 | `curl -s "http://<本机IP>:8088/api/demo/v1/test?name=x"` | `hello:x` |
| 7 | `docker inspect --format '{{.Config.Image}}' consul-demo-3020` | 就是 `config.ini` 里那个 tag |

---

## 常见问题

| 现象 | 怎么办 |
|---|---|
| 找不到 `config.ini` | 正常，包里只带 `.example`。跑一次 `./deploy.sh init` 就有了 |
| 拉镜像报 `manifest unknown` | tag 写错了，或 CI 还没构建完。去 `https://hub.docker.com/r/<IMAGE_REPO>` 看 tag 列表 |
| 拉镜像报 `unauthorized` | 仓库是私有的。`config.ini` 里补 `DOCKER_USERNAME` / `DOCKER_TOKEN` |
| 报「连不上注册中心」 | 3 秒就报，说明地址或端口不通。对照 `REGISTRY`；远端要放通 8500 |
| 报「还没准备好」 | 能连上但没选出主，等 30 秒再执行 |
| 报到成功，但网关里是 `127.0.0.1` | `MY_IP` 填错了，或探测到虚拟网卡。手工填真实内网地址 |
| 列表变了但访问没变化 | 忘了 reload：`sudo nginx -s reload` |
| 访问 502 | 看 `backends.conf` 有没有 server 行；有就直连那个地址试 `curl <地址>/healthz` |
| 升级后行为没变 | `docker inspect` 看容器镜像 tag 是不是新的；`docker compose` 可能用了本地旧镜像，重跑 `service` 会强制拉取 |
| 注册报 `permission denied` | `sudo chmod 777 roles/center/data/center` |

---

## 关于 nginx

脚本**不改**宿主机的 nginx 配置，只把配置文件准备好。上面那两条命令需要你自己敲。

为什么不做成自动的：容器里的程序给宿主机 nginx 发重启信号会被系统拦住，硬要做就得往宿主机装常驻服务，那等于改了系统配置。
