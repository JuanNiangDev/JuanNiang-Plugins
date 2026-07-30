# JuanNiang-Plugins

JuanNiang-Neo 官方插件仓库，用于托管、分发和索引 Lua 插件。

## 简介

本仓库是 [JuanNiang-Neo](https://github.com/JuanNiangDev/JuanNiang-Neo) QQ 机器人的插件中心。每个插件是一个包含 `pluggin.yaml` 和 `main.lua` 的独立目录，通过脚手架 CLI 工具 `hago` 管理生命周期。

### 核心特性

- **脚手架工具** `hago`：一键创建、打包、索引插件
- **元数据分片**：`metadata/chunk_n.json` 每片 300 条，`plugins.json` 索引所有分片
- **模板化生成**：`template/` 下的 Go template 确保插件结构统一
- **SDK 内置**：`sdk/jn.lua` 提供 IDE 代码提示和标准 API

## 目录结构

```
JuanNiang-Plugins/
├── docs/               ← 你在这里
│   ├── README.md          本文件：仓库概述
│   ├── structure.md       仓库结构与工作流
│   └── plugin-dev.md      插件开发指南
├── sdk/
│   └── jn.lua             Lua SDK（类型注解 + API 参考）
├── metadata/              hago scan 生成的插件元数据
│   ├── chunk_1.json       第 1 片（最多 300 条）
│   ├── chunk_2.json       第 2 片
│   └── ...
├── plugins/               所有插件源码（每个插件一个目录）
│   ├── welcome/
│   │   ├── pluggin.yaml   插件清单
│   │   ├── main.lua       入口脚本
│   │   └── jn.lua         (可选) SDK 副本，IDE 提示用
│   └── ...
├── template/              脚手架模板（Go text/template）
│   ├── pluggin.yaml
│   └── main.lua
├── tool/                  hago CLI 源码（Go）
│   ├── main.go            入口 + 帮助
│   ├── init.go            init 命令
│   ├── pack.go            pack 命令
│   ├── scan.go            scan 命令
│   └── paths.go           仓库根目录自动定位
├── plugins.json           分片索引文件
├── hago                   CLI 二进制
└── README.md              顶层说明
```

## 快速开始

### 构建 CLI

```bash
cd tool && go build -o ../hago .
```

### 创建插件

```bash
./hago init my-plugin
```

交互式输入作者和简介，自动在 `plugins/my-plugin/` 生成：
- `pluggin.yaml` — 插件元数据
- `main.lua` — 插件入口
- `jn.lua` — SDK 副本

### 打包插件

```bash
./hago pack my-plugin
```

生成 `plugins/my-plugin.zip`，可直接在 JuanNiang-Neo Web 面板上传。

### 更新元数据

```bash
./hago scan
```

扫描 `plugins/` 下所有插件，生成 `metadata/chunk_n.json` 和 `plugins.json`。

## 给 Agent 开发者的指引

如果你是另一个 Agent 来开发或维护此仓库：

1. **阅读顺序**：先读 `docs/structure.md` 理解仓库结构，再读 `docs/plugin-dev.md` 了解插件规范
2. **脚手架优先**：用 `hago init` 创建插件，不要手动创建目录和文件
3. **提交前打包**：用 `hago pack` 打包，用 `hago scan` 更新索引
4. **模板驱动**：`template/` 是生成源头，修改插件结构应改模板而非手改每个插件
