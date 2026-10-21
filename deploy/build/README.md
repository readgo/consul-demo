# 构建工具

`deploy/` 下只有两个目录：**`build/`（车间）和 `server/`（成品）**。

```
deploy/
├── build/                   ← 本目录：只有构建工具，没有部署脚本
│   ├── Dockerfile              应用镜像怎么打
│   ├── build-image.sh          调 Dockerfile，导出镜像包
│   ├── pack.sh                 打镜像 + 校验成品目录
│   └── README.md
└── server/                  ← 部署件的唯一源，也是要拖到服务器的那一份
    ├── deploy.sh
    ├── config.ini.example
    ├── lib/common.sh
    ├── roles/{center,gateway,service}/
    ├── image/*.tar.gz          产物（build-image.sh 生成）
    ├── VERSION.txt             产物（pack.sh 生成）
    └── README.md
```

**部署脚本没有第二份。** 要改 `deploy.sh`、`run.sh`、`compose.yaml`，直接改 `server/` 里的，改完就是生效版本，不需要任何复制动作。

---

## 一句话

**改 `server/` 里的脚本（或改项目根 `src/` 的代码）→ `./pack.sh` → 把 `server` 整个拖到服务器。**

---

## `pack.sh` 只做两件事

```bash
./pack.sh                 # 打镜像 + 校验（最常用）
./pack.sh --no-build      # 应用代码没动，只校验
./pack.sh --build-only    # 只打镜像
```

1. **打镜像** —— 调 `build-image.sh`，产物直接落在 `../server/image/consul-demo-image.tar.gz`（不另存一份）；
2. **校验成品目录** —— 见下一节，然后写 `VERSION.txt`。

**它不清空、不复制任何部署件。** 你放在 `server/` 里的东西原样就在那儿。

**nginx 配置不随包走。** 仓库里只有一份 `nginx/consul-demo.conf`，由人手动复制到宿主机
nginx 的 include 目录（`config.ini` 里的 `NGINX_CONF_DIR`）。成品目录里出现 `nginx/`，
`pack.sh` 会报错中止。

---

## 校验：成品目录里只能有服务器自己会用的文件

`server/` 既是唯一源、又是交付物，所以干净只能靠反向检查——`pack.sh` 扫一遍，发现下面这些就**中止**（退出码 1）：

| 检查 | 拦什么 | 为什么 |
|---|---|---|
| 必需清单 | `deploy.sh`、`config.ini.example`、`lib/common.sh`、`roles/*/{run.sh,compose.yaml}`、`backends.ctmpl` | 缺一个服务器上就装不起来 |
| 构建工具 | `pack.sh`、`build-image.sh`、`Dockerfile`、`Makefile` | 服务器不会用 |
| 本机配置 | `config.ini` | 含本机地址，带上服务器会覆盖那边该自动生成的那份 |
| 开发文档 | 除 `README.md` 外的任何 `*.md` | 服务器只看 README |
| 源码 | `*.ts`、`package.json`、`package-lock.json`、`tsconfig.json` | 跑的是镜像，不是源码 |
| nginx 配置 | `nginx/` 整个目录 | nginx 配置不随包走，由人手动复制到 include 目录 |

被拦时不要绕过，删掉那些文件重跑。`config.ini` 删了零损失——`deploy.sh` 下次运行会自动从 `config.ini.example` 生成。

---

## 改了东西之后

| 改了什么 | 要做的事 |
|---|---|
| 应用代码（项目根 `src/`） | `./pack.sh` → 拖 `server` → `sudo ./deploy.sh service` |
| 部署脚本（`server/deploy.sh`、`server/roles/*/run.sh`、`compose.yaml`） | `./pack.sh --no-build` → 拖 `server` → 重启对应角色 |
| nginx 配置（仓库根 `nginx/consul-demo.conf`） | 手动复制到 `~/nginx/conf.d/` → `sudo nginx -t && sudo nginx -s reload`（跟打包无关） |
| 服务器侧说明 | 直接改 `server/README.md` |

`./pack.sh --no-build` 时如果连镜像包都没有，会直接报错，不会吐出半成品。

---

## `config.ini` 和 `config.ini.example`

| 文件 | 进仓库 | 进交付 | 谁用 |
|---|---|---|---|
| `config.ini.example` | ✅ | ✅ | 模板，第一次运行时自动复制成 `config.ini` |
| `config.ini` | ❌（.gitignore 挡） | ❌（`pack.sh` 拦） | 本机实跑时的真实配置 |

配置文件特意**不带点号**：带点号的文件 `ls` 看不见，服务器上容易误以为没有配置文件。

服务器上第一次执行任何 `deploy.sh` 命令时，`lib/common.sh` 会发现没有 `config.ini`，自动从模板复制一份；已存在的不会被覆盖。

**改了配置项的含义或默认值，两处都要同步改**：`server/config.ini.example`（模板）和 `server/lib/common.sh` 里的 `${VAR:-默认值}`（兜底）。

---

## 为什么不再用「白名单复制」

早先的做法是：源放 `build/`，`pack.sh` 按白名单挑件复制进 `server/`。代价是**同一批脚本存在两份**——改一次要改两处，还得记得重新打包，`server/` 里那份是死的副本。

现在 `server/` 就是源，数据只有一份。干净的保证从「结构性（进不去）」换成「检查性（打包时报错）」，换到的是零重复。

---

## 项目根只放程序

`Dockerfile` 归构建工具，所以它在本目录，不在项目根。

```bash
docker build -f deploy/build/Dockerfile -t consul-demo:local .   # 上下文是项目根
```

项目根现在是：`src/` `dist/` `package.json` `package-lock.json` `tsconfig.json` `deploy/` `deploy_ci/` `nginx/`。

---

## 运行时数据不会被覆盖

`pack.sh` 不删任何东西，服务器上的这些也各自独立：

- `roles/center/data/` —— 产物里只有空目录，注册数据不受影响
- `$NGINX_CONF_DIR/backends.conf` —— generator 直接写到 nginx 的配置目录，不在部署目录里留副本

重复上传、重复部署都安全。
