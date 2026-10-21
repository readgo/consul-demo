# 发布说明（开发机上看的）

这里的脚本负责一件事：**打 tag 推上去，让 CI 构建镜像**。
构建和推送都在 GitHub 的机器上跑，本地不占 CPU、不占带宽。

---

## 一次性准备

### 1. 配两个仓库密钥

GitHub 仓库 → `Settings` → `Secrets and variables` → `Actions` → `New repository secret`：

| 名称 | 填什么 |
|---|---|
| `DOCKER_USERNAME` | Docker Hub 用户名 |
| `DOCKER_TOKEN` | Docker Hub 的 **Access Token**，不是登录密码 |

Access Token 在 Docker Hub → `Account settings` → `Security` → `New Access Token`，权限选 `Read & Write` 就够。

> 用登录密码也能跑，但 Token 可以单独吊销、可以限定权限，密码泄露就是整个账号。

### 2. 确认镜像命名空间三处一致

Docker Hub 账号和 GitHub 仓库所有者**经常不是同一个**，所以账号不是从密钥里现取，而是显式写死在一个地方：

| 位置 | 写什么 |
|---|---|
| `.github/workflows/release.yml` 的 `env.DOCKERHUB_NAMESPACE` | `wttcvs` |
| `deploy_ci/release/release.sh` 的 `DOCKERHUB_NAMESPACE` 默认值 | `wttcvs` |
| 服务器上 `config.ini` 的 `IMAGE_REPO` | `wttcvs/consul-demo` |

前两处必须等于密钥 `DOCKER_USERNAME` 的值。CI 里有一步会拿密钥跟 `DOCKERHUB_NAMESPACE` 对比，不一致直接失败 —— 否则现象是「构建全绿、服务器拉不到」，很难查。

> 日志里这个账号仍会显示成 `***`：GitHub 是按密钥的**值**打码的，只要这个字符串等于密钥值就必然被打码，跟写法无关。

### 3. 确认工作流在正确的位置

CI 定义在仓库根的 `.github/workflows/release.yml`。**GitHub 只认这个路径**，放在 `deploy_ci/` 里不会执行。

---

## 发一个版本

```bash
cd deploy_ci/release
./release.sh
```

不带参数会按时间生成 tag（`v20261021-104730`），然后打 tag、推 tag、打印构建链接。

| 命令 | 做什么 |
|---|---|
| `./release.sh` | 自动生成 tag 并发布 |
| `./release.sh v1.2.3` | 用指定的 tag |
| `./release.sh --wait` | 发布后一直等到镜像真出现在 Docker Hub 上 |
| `./release.sh --dry-run` | 只打印要做什么，不真打 tag、不推送 |
| `./release.sh --list` | 看已经发过哪些 tag |

推完之后：

- 构建进度：`https://github.com/<owner>/<repo>/actions/workflows/release.yml`
- 镜像地址：`docker pull <DOCKER_USERNAME>/consul-demo:<tag>`

---

## 它会挡住三种情况

**1. 有未提交的改动**

CI 是从 tag 指向的提交构建的，工作区里没提交的东西不会进镜像。脚本会直接停下并列出未提交文件，而不是让你发出去一个少了改动的版本。

**2. tag 不以 `v` 开头**

工作流只对 `v*` 触发。写 `1.2.3` 推上去 CI 不会启动，静默失败最难查，所以这里提前挡。

**3. tag 已存在**

本地或远端已有同名 tag 就停。tag 重推会让人搞不清"线上那个 tag 到底是哪次构建的"。

---

## 发布出去的是什么

| 项 | 值 |
|---|---|
| 镜像 | `<DOCKER_USERNAME>/consul-demo:<tag>` |
| 别名 | `<DOCKER_USERNAME>/consul-demo:latest` |
| 构建文件 | `deploy/build/Dockerfile` |
| 架构 | `linux/amd64`（CI 机器默认架构） |

**Dockerfile 只有一份**，在 `deploy/build/`。`deploy_ci` 不复制它 —— 复制两份迟早会漂移，一边修了另一边忘了。

`latest` 只是方便快速试，**正式部署请钉具体 tag**。`latest` 会被下次发布覆盖，回滚时回不去。

---

## 服务器那边怎么接

`release.sh --wait` 成功后会直接打印该填什么。手工也行：

```bash
# 服务器上
sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=v20261021-104730|' config.ini
sudo ./deploy.sh service
```

---

## 常见问题

| 现象 | 原因 |
|---|---|
| push 了 tag，Actions 页面什么都没有 | tag 不是 `v` 开头，或工作流文件不在 `.github/workflows/` |
| 构建失败在「检查密钥是否配了」 | 两个 secret 名字拼错，或只在 Environment 里配了没在本仓库配 |
| 构建失败在 `docker login` | `DOCKER_TOKEN` 用了密码、过期，或权限只有 Read |
| 构建成功但 Docker Hub 上没有 | 镜像推到了 `DOCKER_USERNAME` 那个账号下，与你查的账号不是同一个。看 `release.yml` 里的 `DOCKERHUB_NAMESPACE`（现在账号不一致会直接构建失败，不再出现这种情况） |
| `--wait` 一直查不到 | 私有仓库查不到（脚本会提示）；公开仓库则是构建还没完 |
| 推送 tag 被拒 | 远端已有同名 tag。`./release.sh` 自动生成的 tag 撞车概率极低，手工指定的才容易撞 |

---

## 和 `deploy/` 那套的区别

| | `deploy/` | `deploy_ci/` |
|---|---|---|
| 镜像怎么来的 | 本地 `docker build` + 存成 tar | CI 构建 + 推 Docker Hub |
| 怎么上服务器 | 交付目录里带一个 60MB 的 tar 包 | 目录里只有文本，服务器自己 `docker pull` |
| 服务器要不要外网 | 不要 | 要（能访问 Docker Hub） |
| 升级怎么做 | 换整个交付包 | 改 `config.ini` 一行 tag |
| 回滚怎么做 | 换回上一个包 | 改回上一个 tag |
| 适合 | 内网、离线、客户不给外网 | 常规迭代 |

两套的 `roles/center` 和 `roles/gateway` 内容相同；差异只在 `roles/service`（一个 `docker load`，一个 `docker pull`）和配置里多两行镜像地址。
