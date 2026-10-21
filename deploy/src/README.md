# 运行件源文件

这里放的是**要送到服务器上跑的那些东西的源文件**。
改东西改这里，然后到 `../build/` 跑 `./pack.sh` 产出成品。

## 内容

```
src/
├── deploy.sh                入口脚本
├── config.ini.example       配置模板（进交付包）
├── config.ini               本地实跑用的配置（不进交付包、不进仓库）
├── lib/common.sh            三个角色脚本共用
├── roles/
│   ├── center/              注册中心
│   ├── gateway/             网关
│   └── service/             业务应用
└── image/                   应用镜像（由 ../build/build-image.sh 生成）
```

## 关于 config.ini 和 config.ini.example

| 文件 | 进仓库 | 进交付包 | 谁用 |
|---|---|---|---|
| `config.ini.example` | ✅ | ✅ | 模板，服务器上从这里复制出 `config.ini` |
| `config.ini` | ❌（被 .gitignore 挡） | ❌ | 本地开发实跑时的真实配置 |

配置文件特意**不带点号**：带点号的文件 `ls` 看不见，服务器上容易误以为没有配置文件。

服务器上第一次执行任何 `deploy.sh` 命令时，`lib/common.sh` 会发现没有 `config.ini`，
自动从 `config.ini.example` 复制一份。已经存在的 `config.ini` 不会被覆盖。

**改了配置项的含义或默认值，两处都要同步改**：`config.ini.example`（模板）和
`lib/common.sh` 里的 `${VAR:-默认值}`（兜底）。

## 注意

- **这个目录不会整个拖到服务器。** 服务器只收 `../server`，那是按白名单挑出来的。
- 这里可以放只在开发时用得着的东西（比如临时笔记），它不会被带出去。
- 新增运行时要用的文件时，记得同步加进 `../build/pack.sh` 的白名单。

## 流程

```
src/  ──pack.sh──▶  server/  ──拖拽──▶  服务器
(源)                 (成品)             └─首次运行─▶ 自动生成 config.ini
```
