# 构建脚本

这个目录**只有脚本**，没有运行件，也不上服务器。
跑脚本产出的 `../server` 才是要拖到服务器上的东西。

## 一句话

**`./pack.sh` → 把 `../server` 整个拖到服务器。**

---

## 1. deploy 下三个目录，各管一段

```
deploy/
├── src/        运行件的源文件（改东西改这里）
├── build/      ← 本目录，构建用的东西全在这里
│   ├── README.md
│   ├── Dockerfile           应用镜像怎么打
│   ├── build-image.sh       调上面的 Dockerfile，打出镜像包
│   └── pack.sh              产出干净的交付目录
└── server/     产出的交付目录，整个拖到服务器
```

一段话概括：**`src` 是原料，`build` 是车间，`server` 是成品。**

| 目录 | 放什么 | 能不能拖到服务器 |
|---|---|---|
| `src/` | 运行件的源代码 | 不要 |
| `build/` | `Dockerfile` + 两个脚本 | 不要，服务器用不上 |
| `server/` | 白名单挑出来的成品 | **就这个** |

> `Dockerfile`、`build-image.sh`、`pack.sh` 三者是一套的：
> 打包脚本调打镜像脚本，打镜像脚本调 `Dockerfile`。
> 所以全放在同一个目录里，不用钻子目录，改哪一环一眼能找到。

---

## 2. 一个命令就够

```bash
./pack.sh
```

它自己会按顺序做两件事：

1. 调 `./build-image.sh`，把应用打成镜像包 ——→ `../src/image/consul-demo-image.tar.gz`
2. 按白名单产出干净的交付目录 ——→ `../server`

然后打开 WindTerm，把 `deploy/server` 这个文件夹拖到服务器，命名为 `deploy-consul-demo`。

### 另外两种跑法

| 命令 | 做什么 | 什么时候用 |
|---|---|---|
| `./pack.sh` | 打镜像 + 产出交付目录 | 默认，改了应用代码、或者不确定该用哪个 |
| `./pack.sh --no-build` | 只用现成的镜像包，产出交付目录 | 只改过 `deploy/src/` 里的脚本或 `config.ini`，应用代码没动 |
| `./pack.sh --build-only` | 只打镜像，不产出交付目录 | 想单独确认镜像能打出来 |

`--no-build` 时如果连镜像包都没有，会直接报错停下，不会产出一份缺镜像的半成品。

---

## 3. 白名单就是唯一真相

`pack.sh` 里写死的清单，决定什么能进 `server/`：

```bash
FILES=(
  deploy.sh  config.ini.example  lib/common.sh
  roles/center/run.sh   roles/center/compose.yaml
  roles/gateway/run.sh  roles/gateway/compose.yaml
  roles/gateway/site.conf  roles/gateway/backends.ctmpl
  roles/service/run.sh  roles/service/compose.yaml
)
DIRS=( roles/center/data/center  roles/gateway/conf.d )
```

外加 `server/README.md`（手写说明）、`server/VERSION.txt`（自动生成）、`image/*.tar.gz`。

**清单外的东西永远进不了 `server/`。** 这是「服务器干净」的保证方式 ——
不靠一条条排除（漏一条就污染），而是靠白名单（没写就是不会过去）。

在 `src/` 里新增一个运行时要用的文件时，**必须同时加进 `FILES`**。

---

## 4. 三个目录里不会互相抄

| | 会不会出现运行件 | 会不会出现脚本 |
|---|---|---|
| `src/` | 会（就是源） | 不会 |
| `build/` | **不会**（只有脚本） | 会（就是脚本） |
| `server/` | 会（就是成品） | 不会 |

之前 `build/` 里同时放了脚本和一份完整运行件，和 `server/` 长得几乎一样，
容易让人分不清哪个是要拖走的。现在分开了。

---

## 5. 项目根已经干净了

`Dockerfile` 原来放在项目根的 `build/` 下，和调用它的脚本隔着老远。
既然只有那一个脚本用它，就挪到 `deploy/build/Dockerfile`，和脚本放一起。

现在项目根只有：`src/` `dist/` `package.json` `package-lock.json` `tsconfig.json` `deploy/`。

构建时 `build-image.sh` 会先 cd 到项目根，再执行：

```bash
docker build -f deploy/build/Dockerfile -t consul-demo:local .
```

`-f` 指文件在哪，末尾的 `.` 指构建上下文是项目根（Dockerfile 里要 COPY `src/`、`package.json`）。

---

## 6. 数据不会被覆盖

`pack.sh` 每次清空 `server/` 重建，但服务器上的这些东西不受影响：

- `roles/center/data/` —— 产物里只有空目录，已有的注册数据不会被删
- `roles/gateway/conf.d/backends.conf` —— 产物里只有空目录，已生成的地址列表不会被清

所以重复上传、重复部署都是安全的。

---

## 7. 改了东西之后的流程

| 改了什么 | 要做的事 |
|---|---|
| 应用代码（项目根的 `src/`） | `./pack.sh` → 拖到服务器 → `sudo ./deploy.sh service` |
| `deploy/src/` 里的脚本或 `config.ini` | `./pack.sh --no-build` → 拖到服务器 → 重启对应角色 |
| 服务器侧说明 | 直接改 `deploy/server/README.md`（`pack.sh` 不会覆盖它） |

---

## 8. 服务器上怎么用

那份说明写在 `deploy/server/README.md` 里，会随成品一起拖过去，
服务器上直接看得到：三块功能怎么装、单机/双机步骤、验收判据、常见问题。
