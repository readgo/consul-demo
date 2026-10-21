# deploy_ci：镜像走 CI，服务器拉下来跑

同一套应用有两种交付方式，互不影响：

| | `deploy/` | `deploy_ci/`（本目录） |
|---|---|---|
| 镜像怎么来 | 本地 `docker build`，存成 60MB 的 tar 包 | GitHub Actions 构建，推到 Docker Hub |
| 服务器怎么拿 | 交付包里带着 tar，`docker load` | 服务器自己 `docker pull` |
| 服务器要不要外网 | 不要 | 要 |
| 升级 | 换整个交付包 | 改 `config.ini` 里一行 tag + 重跑 `service` |
| 回滚 | 换回上一个包 | 改回上一个 tag |
| 适合 | 内网、离线、客户不给外网 | 常规迭代 |

---

## 目录

```
deploy_ci/
├── README.md        本文件
├── release/         发布侧（开发机上用）
│   ├── release.sh     打 tag 触发 CI 构建
│   └── README.md      密钥怎么配、tag 规则、常见问题
└── server/          服务器侧（拷到服务器上用）
    ├── deploy.sh
    ├── config.ini.example
    ├── lib/common.sh
    └── roles/{center,gateway,service}/
```

CI 定义在仓库根的 `.github/workflows/release.yml` —— GitHub 只认那个路径，放在本目录里不会执行。

---

## 完整一轮

**开发机：**

```bash
git add -A && git commit -m "改了什么" && git push
deploy_ci/release/release.sh --wait
```

看到 `镜像已就绪` 之后，它会打印该填的 tag。

**服务器：**

```bash
sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=v20261021-104730|' config.ini
sudo ./deploy.sh service
```

脚本会打印 `版本已切换：旧tag -> 新tag`。

---

## 设计上的几个取舍

**1. 两套目录完全独立，不互相引用**

`deploy_ci/server` 里的 `deploy.sh`、`common.sh`、三个角色都是自己的一份。改一边不会影响另一边，代价是公共文件要手工同步。如果哪天改公共逻辑，记得两边都改 —— 或者那时再考虑合并。

**2. Dockerfile 只有一份**

在 `deploy/build/Dockerfile`。`deploy_ci` 不复制它 —— 镜像构建文件复制两份，迟早一边修了另一边忘了，最后两个镜像行为不一致。

**3. 发布必须打 tag，不接受"发当前工作区"**

CI 从 tag 指向的提交构建，工作区未提交的改动不会进镜像是静默的坑。`release.sh` 发现有未提交内容直接停，不让人发一个残版本。

**4. 服务器侧钉 tag，不追 `latest`**

`latest` 会被下次发布覆盖，回滚时回不去。`status` 会打印容器实际用的镜像和 `config.ini` 里配的是否一致。

**5. 服务器侧不编译任何东西**

`server/` 里一个 `.ts` 都没有，也没有 `image/` 目录 —— 整个包只有几十 KB 文本。服务器上"这个文件服务器自己会用吗"答案是"是"，才留着。

---

## 前置条件

| 项 | 要求 |
|---|---|
| 服务器能访问 | Docker Hub（`docker pull hello-world` 能过） |
| GitHub 仓库密钥 | `DOCKER_USERNAME`、`DOCKER_TOKEN` |
| 工作流位置 | `.github/workflows/release.yml` |
| 服务器已装 | docker + compose 插件、nginx（网关那台） |

密钥没配时，构建第一步就会报「缺少仓库密钥」，不会等到 `docker login` 才给一句 `unauthorized`。
