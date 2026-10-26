# JuanNiang-Plugins

JuanNiang-Neo 官方插件仓库，用于托管、分发和索引 Lua 插件。

## 简介

本仓库是 [JuanNiang-Neo](https://github.com/JuanNiangDev/JuanNiang-Neo) QQ 机器人的插件中心。每个插件是一个独立目录（新格式 5 件套：`main.lua` / `pluggin.yaml` / `config.yaml` / `README.md` / `avatar.png`），通过脚手架 CLI 工具 `hago` 管理生命周期。

### 核心特性

- **脚手架工具** `hago`：一键创建、打包、索引、校验插件（源码在 `tool/`，二进制不入库）
- **元数据分片**：`metadata/chunk_n.json` 每片 300 条，`plugins.json` 索引所有分片
- **模板化生成**：`template/` 下的 Go template 确保插件结构统一
- **SDK 内置**：`sdk/jn.lua` 提供 IDE 代码提示和标准 API

## 目录结构

```
JuanNiang-Plugins/
├── docs/               ← 你在这里
│   ├── README.md              本文件：仓库概述
│   ├── structure.md           仓库结构与工作流
│   ├── plugin-development.md  插件开发指南（JuanNiang-Neo 插件系统完整参考）
│   ├── redrock-plugins.md     Redrock 系列插件全集
│   ├── avatar-style.md        插件头像风格指南
│   ├── avatar-validate.py     头像 alpha 通道校验脚本
│   └── webhook-cronjob.md     Webhook / CronJob 触发插件
├── sdk/
│   └── jn.lua             Lua SDK（类型注解 + API 参考）
├── metadata/              hago scan 生成的插件元数据
│   ├── chunk_1.json       第 1 片（最多 300 条）
│   ├── chunk_2.json       第 2 片
│   └── ...
├── plugins/               所有插件源码（每个插件一个目录）
│   ├── sdk/               仓库内的 SDK 副本目录（无 pluggin.yaml，非插件）
│   ├── welcome/
│   │   ├── pluggin.yaml   插件清单
│   │   ├── main.lua       入口脚本
│   │   ├── config.yaml    动态配置声明
│   │   ├── README.md      插件说明
│   │   ├── avatar.png     图标
│   │   └── jn.lua         (可选) SDK 副本，IDE 提示用
│   └── ...
├── template/              脚手架模板（Go text/template）
│   ├── main.lua
│   ├── pluggin.yaml
│   ├── config.yaml
│   ├── README.md
│   └── avatar.png
├── tool/                  hago CLI 源码（Go）
│   ├── main.go            入口 + 命令路由
│   ├── init.go            init 命令
│   ├── pack.go            pack 命令
│   ├── scan.go            scan 命令
│   ├── validate.go        validate 命令
│   └── paths.go           仓库根目录自动定位
├── .github/workflows/     plugin-review.yml（PR 校验）+ metadata-update.yml（夜间元数据/打包）
├── dist/                  hago pack 产出的 zip（夜间 workflow 用 git add -f 强制跟踪）
├── plugins.json           分片索引文件
├── AGENTS.md              Agent 会话工作指南
├── CONTRIBUTING.md        贡献指南
├── Makefile               构建/打包/校验快捷入口
├── LICENSE
└── README.md              顶层说明
```

> `hago` 二进制**不在仓库中**（`.gitignore:6` 忽略），需先 `make build` 生成。

## 快速开始

### 构建 CLI

```bash
make build          # 等价于 cd tool && go build -o ../hago .
```

### 创建插件

```bash
make init NAME=my-plugin     # 或 ./hago init my-plugin
```

交互式输入作者和简介，自动在 `plugins/my-plugin/` 生成 5 件套（另附 `jn.lua`）：
- `pluggin.yaml` — 插件元数据
- `main.lua` — 插件入口
- `config.yaml` — 动态配置声明
- `README.md` — 插件说明
- `avatar.png` — 图标（默认复制 `template/avatar.png`）
- `jn.lua` — SDK 副本（IDE 提示用）

### 打包插件

```bash
make pack NAME=my-plugin     # 或 ./hago pack my-plugin
```

生成 `dist/my-plugin.zip`（不是 `plugins/` 下），可直接在 JuanNiang-Neo Web 面板上传。

> ZIP 内部条目是**裸文件名**（`pluggin.yaml`、`main.lua`…，不带插件目录前缀，见 `tool/pack.go:150-155`）。因此经 `POST /api/v1/plugins/upload` 上传时，服务端从根级 `pluggin.yaml` 推断插件名会失败，最终装成 `pluggin-<随机数>/`（主仓库 `internal/api/service/service.go:1227-1240`）；商店安装按元数据 `path` 安装，不受影响。

### 更新元数据

```bash
make scan                    # 或 ./hago scan
```

扫描 `plugins/` 下所有插件，生成 `metadata/chunk_n.json` 和 `plugins.json`。

## 给 Agent 开发者的指引

如果你是另一个 Agent 来开发或维护此仓库：

1. **阅读顺序**：先读 `docs/structure.md` 理解仓库结构，再读 `docs/plugin-development.md` 了解插件规范
2. **脚手架优先**：用 `make init NAME=<name>` 创建插件，不要手动创建目录和文件
3. **PR 只需提交 `plugins/` 源码**：`metadata/`、`plugins.json` 与 `dist/` 由夜间 `metadata-update.yml` 自动重建并提交（`dist/` 在 `.gitignore` 里，workflow 用 `git add -f` 强制跟踪，贡献者本地 `git add dist/` 会被忽略）
4. **模板驱动**：`template/` 是生成源头，修改插件结构应改模板而非手改每个插件
5. **提交前校验**：`make validate NAME=<name>`（内部执行 `./hago validate <name> --strict`），与 CI `plugin-review.yml` 一致
