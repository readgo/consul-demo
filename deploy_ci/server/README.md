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
    ├── gateway/        网关（生成 backends.conf 到 nginx 的配置目录）
    └── service/        业务应用
```

没有 `image/` 目录 —— 这是与离线 tar 包那套唯一的区别。

> nginx 的配置**不在这个目录里**。`deploy.sh gateway` 会自己判定目标目录，
> 里面缺 `consul-demo.conf` / `backends.conf` 就各生成一份。判定规则见下文
> 「nginx 配置目录怎么定」。

---

## 装哪块

| 命令 | 装什么 | 在哪台机器 | 装几次 |
|---|---|---|---|
| `sudo ./deploy.sh center` | 注册中心 | 挑一台固定的 | 一次，以后不用管 |
| `sudo ./deploy.sh gateway` | 地址表生成器（转发由该机的 nginx 做） | 装 nginx 的那台 | 一次 |
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
IMAGE_REPO=wttcvs/consul-demo
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

# nginx 的配置目录。留空 = 自动判定（一般不用填）
NGINX_CONF_DIR=

# 服务名
SERVICE_NAME=consul-demo
```

> `config.ini` 只影响本机，不会同步到别的机器。加机器时那份是新生成的，要单独改 `REGISTRY`。

**`IMAGE_TAG` 别长期用 `latest`。** 出问题时 `status` 会告诉你线上是哪个版本，前提是你钉了具体 tag。

### nginx 配置目录怎么定

`NGINX_CONF_DIR` 留空时，脚本按两条规则自己算：

| 顺序 | 规则 | 结果举例 |
|---|---|---|
| 1 | 默认 `<当前用户家目录>/nginx/conf.d` | `sudo` 执行时按 `SUDO_USER` 的真实家目录算，不是 `/root` |
| 2 | 若 nginx **没有 include** 这个默认目录，改用 nginx 自己的 `conf.d` | 从 `nginx.conf` 的 `include` 里推，推不出按 `/etc/nginx/conf.d` |

判定只读 `/etc/nginx/nginx.conf`（路径取自 `nginx -V` 的 `--conf-path`），**不改它**。
`deploy.sh gateway` 会打印实际用的目录和来源：

```
    目录    /home/jing/nginx/conf.d
    来源    默认目录（nginx 已 include）
```

想固定到别处再填：相对路径按部署目录算，也可以写绝对路径。

### 缺的配置自动补

拿到目录后，脚本只补**不存在**的文件，已存在的一律不动：

| 文件 | 缺了会怎样 | 补的方式 |
|---|---|---|
| `consul-demo.conf` | nginx 没有站点配置，`proxy_pass` 无从上手 | 按 `SITE_PORT` / `SERVICE_NAME` 生成一份 |
| `backends.conf` | **`nginx -t` 照样通过**，但 `proxy_pass http://consul-demo/` 会被当成域名去解析，请求 502 或者莫名打到别的主机上——实测最容易误判的一类 | 先查注册中心；没有实例就写一条 `down` 占位（能过 `-t`、请求返回 502），generator 起来后接管 |

---

## 单机部署

```bash
sudo ./deploy.sh all
# 它会判定 nginx 配置目录，把 backends.conf 写进去，缺 consul-demo.conf 也一并生成，
# 最后调用 nginx 自己的命令 reload（nginx 没在跑就启动），不需要你敲 nginx。

# 唯一可能要手动的一件事（只做一次）：如果 deploy.sh gateway 打印了「待办」，
# 说明这个目录还没被 include，到 /etc/nginx/nginx.conf 的 http {} 里加一行：
#     include /home/jing/nginx/conf.d/*.conf;
# 没打印「待办」就说明已经 include 过了，什么都不用做。

# 验证
curl -s "http://$(hostname -I | awk '{print $1}'):8088/api/demo/v1/test?name=hello"
```

最后一条返回 `hello:hello` 就成了。

> **顺序**：`deploy.sh` 内部已经处理好了「先有地址表、再 reload」这个顺序，
> 不用你操心。

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
# 网关这一步会自动 reload nginx（没在跑就启动），不需要手敲 nginx 命令。
# 站点配置缺了会自动生成，不用再 cp 仓库根那份。
```

**第二台**（业务机）：

```bash
./deploy.sh init                                  # 先有 config.ini 才能改
sed -i 's|^REGISTRY=.*|REGISTRY=http://第一台的内网IP:8500|' config.ini
sudo ./deploy.sh service
```

不用回第一台做任何事：新实例报到后，第一台的 generator 会在 1~2 秒内重写地址表，
然后自己给 nginx 发 HUP 平滑重载，流量立刻分到两台。**第一台的配置文件一个字都没改。**

---

## 加机器 / 删机器

| 动作 | 要改配置吗 | 要做的事 |
|---|---|---|
| 加一台业务机 | 不用 | 新机器上 `sudo ./deploy.sh service` 就够了，1~2 秒后网关自动认到 |
| 删一台业务机 | 不用 | 那台执行 `docker rm -f <容器名>`，1~2 秒后自动从列表消失并重载 |
| 同机再加一个实例 | 不用 | `sudo ./deploy.sh service 2`，端口自动变 3021 |

---

## 验收

| # | 命令 | 期望 |
|---|---|---|
| 1 | `./deploy.sh status` | 三块分别显示 Up 或「（本机没装）」，业务应用下面多一行 `镜像` |
| 2 | `./deploy.sh status` 最后一行 | `config.ini 里配的是 wttcvs/consul-demo:<tag>`，与容器实际镜像一致 |
| 3 | `curl -s localhost:8500/v1/status/leader` | `"<本机内网IP>:8300"` |
| 4 | `curl -s localhost:8500/v1/catalog/service/consul-demo` | 地址是内网 IP，**不是 127.0.0.1** |
| 5 | `cat $NGINX_CONF_DIR/backends.conf`（`deploy.sh gateway` 会打印实际路径） | 每台业务机一行 `server` |
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
| 列表变了但访问没变化 | 看 `docker logs consul-demo-generator` 有没有 `[reload]` 那行：**没有** → 宿主 nginx 没在跑，执行一次 `./deploy.sh gateway`；**有** → 信号已发到，是配置本身有问题，手工 `sudo nginx -t` 看报错（多半是 upstream 名和 `proxy_pass` 不一致，这种情况 `-t` 不报错但请求 502） |
| 访问 502 | 先看 `backends.conf` 里是不是只有 `127.0.0.1:1 down` 占位（占位只是为了让 `-t` 过，照样 502）；有真实地址就直连试 `curl <地址>/healthz` |
| 升级后行为没变 | `docker inspect` 看容器镜像 tag 是不是新的；`docker compose` 可能用了本地旧镜像，重跑 `service` 会强制拉取 |
| 注册报 `permission denied` | `sudo chmod 777 roles/center/data/center` |

---

## 关于 nginx

**边界：不动 `nginx.conf` 和它本身的任何文件，只往它的 include 目录里放生成的配置，再让它生效。**

| 谁 | 做什么 |
|---|---|
| `deploy.sh gateway` | 判定目录；缺 `consul-demo.conf` 就生成；缺 `backends.conf` 就补一份（查注册中心，查不到写 down 占位） |
| `deploy.sh gateway` | 起 generator（常驻），之后 `backends.conf` 由它持续重写 |
| `deploy.sh gateway` | **先 `nginx -t`，通过后 reload；nginx 没在跑就启动它**（`lib/common.sh` 的 `nginx_apply`） |
| generator 容器（常驻） | **地址表一变就自己给 nginx 发 HUP**（`roles/gateway/reload-nginx.sh`），平滑重载——加节点、删节点都不用碰人 |
| 你，手动一次（仅当脚本提示「待办」） | 在 `/etc/nginx/nginx.conf` 的 `http {}` 里加 `include <那个目录>/*.conf;` |

默认算出来的目录就是这个结构，开箱可用（`sudo` 执行时按真实用户家目录算）：

```
~/server                  部署目录（deploy.sh 在这里）
~/nginx/conf.d/           include 目录
  ├── consul-demo.conf         缺了自动生成（listen 8088 + proxy_pass）
  └── backends.conf            缺了自动补，之后由 generator 持续重写
```

想要**手动版本**的站点配置，仓库根 `nginx/consul-demo.conf` 就是默认值样品，`cp` 过去即可；
只要目标文件已存在，脚本不会再覆盖。

脚本**不改** `nginx.conf` 和它本身的任何文件，只往 include 目录里放配置，再用
`nginx -t` / `nginx -s reload`（没在跑就启动）让它生效。

**为什么会有「启动了没 reload」这种坑**：`nginx -t` 是纯语法检查，永远能通过；
`nginx -s reload` 需要读 pid 文件，nginx 没在跑时报
`invalid PID number "" in "/run/nginx.pid"`——看着像配置问题，其实是服务根本没启动。
`nginx_apply` 先判断 pid 文件里那个进程是否还活着，没在跑就直接启动，避免这个误判。

**容器凭什么叫得动宿主 nginx**：`generator` 用 `pid: host` 共享宿主的 pid 命名空间，
加 `cap_add: [KILL]` 和 `security_opt: [apparmor=unconfined]`，再把宿主 `/run` 只读挂到
`/hostrun` 读 pid 文件。三个条件缺一个，容器日志里就会出现
`[reload] 给 nginx 发 HUP 失败（pid xxx）`——这是权限问题，不是地址表问题。
