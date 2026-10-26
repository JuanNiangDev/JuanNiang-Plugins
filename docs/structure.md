# 仓库结构与工作流

## 仓库架构

```
JuanNiang-Plugins/
│
├── plugins.json                ← 元数据分片索引
│
├── tool/                       ← CLI 源码（Go，二进制 `hago` 需 make build 生成，不入库）
│   ├── main.go                    命令路由 + 美化输出
│   ├── init.go                    hago init 实现
│   ├── pack.go                    hago pack 实现
│   ├── scan.go                    hago scan 实现
│   ├── validate.go                hago validate 实现（5 件套 + config schema 校验）
│   └── paths.go                   自动定位仓库根目录
│
├── template/                   ← 模板文件（Go text/template）
│   ├── pluggin.yaml               {{.Name}} {{.Author}} 模板变量
│   ├── main.lua                   插件入口模板
│   ├── config.yaml                动态配置声明模板
│   ├── README.md                  插件说明模板
│   └── avatar.png                 默认图标（hago init 复制到新插件）
│
├── plugins/                    ← 插件源码（工作目录）
│   ├── sdk/
│   │   └── jn.lua                 仓库内的 SDK 副本（无 pluggin.yaml，scan 不收录；引擎按目录名 sdk 显式跳过）
│   └── <plugin-name>/
│       ├── pluggin.yaml           元数据 · 必选
│       ├── main.lua               入口   · 必选
│       ├── config.yaml            动态配置声明 · 建议（validate --strict 要求）
│       ├── README.md              说明文档 · 建议（validate --strict 要求）
│       ├── avatar.png             图标 · 建议（validate --strict 要求）
│       ├── jn.lua                 SDK    · 可选（hago init 自动复制）
│       └── 其他素材                 · 可选（图片、词库 txt 等）
│
├── metadata/                   ← 分片元数据（hago scan 生成）
│   ├── chunk_1.json               [PluginEntry, ...] 最多 300 条
│   └── chunk_2.json
│
├── sdk/                        ← SDK 文件
│   └── jn.lua
│
├── dist/                       ← hago pack 产出的 zip（.gitignore 忽略，夜间 workflow 强制跟踪）
│   ├── <plugin-name>.zip
│   └── ...
│
├── .github/workflows/
│   ├── plugin-review.yml          PR 校验（validate --strict + 版本递增检查）
│   └── metadata-update.yml        夜间 scan + pack --all + 强制提交
│
├── docs/                       ← 文档
│   ├── README.md
│   ├── structure.md
│   ├── plugin-development.md
│   ├── redrock-plugins.md
│   ├── avatar-style.md
│   ├── avatar-validate.py
│   └── webhook-cronjob.md
│
├── AGENTS.md                   ← Agent 会话工作指南
├── CONTRIBUTING.md             ← 贡献指南
├── Makefile                    ← 构建/打包/校验入口
├── LICENSE
└── README.md                   ← 顶层说明
```

> `hago` 二进制被 `.gitignore:6` 忽略、`git ls-files` 查不到，使用前必须先 `make build` 生成。

## 数据流

```
pluggin.yaml               hago scan              chunk_n.json
   (每个插件)    ──────────→  读取并索引   ──────────→   (每片 ≤300 条)
                                  │
                                  ▼
                            plugins.json
                     {total, chunks, updated_at}
```

### PluginEntry 结构

每条 chunk 记录包含（`tool/scan.go:27-36`）：

```json
{
  "name": "welcome",
  "version": "1.0.0",
  "author": "JuanNiang",
  "description": "入群欢迎插件",
  "path": "welcome",
  "image": "welcome/avatar.png",
  "has_config": true,
  "has_readme": true
}
```

- `name` / `version` / `author` / `description` — 从 `pluggin.yaml` 读取
- `path` — 插件在 `plugins/` 下的相对路径
- `image` — 图标相对路径，按 `avatar.png > logo.png > logo.jpg > icon.png` 优先级查找（`tool/scan.go:78-84`），无则省略
- `has_config` / `has_readme` — 是否含 `config.yaml` / `README.md`（`tool/scan.go:34-35`、`:85-91`）

### plugins.json 结构

```json
{
  "total": 24,
  "chunks": [
    "chunk_1.json"
  ],
  "updated_at": "2026-09-19T05:35:52Z"
}
```

- `total` — 插件总数
- `chunks` — 分片文件名列表（按序号排列）
- `updated_at` — 最近一次 scan 时间（RFC3339，`tool/scan.go:122`）

### 分片策略

- 每片最多 **300 条** 记录（`chunkSize` 常量，`tool/scan.go:18`）
- 插件按名称字母序（不区分大小写）排列后切片
- 分片从 1 开始编号（`chunk_1.json`）
- `hago scan` 全量重建所有分片和索引

## hago 工作流

### init

```
用户: hago init my-plugin
  ↓
终端: 📝 作者名 → 📝 简介
  ↓
模板渲染: template/pluggin.yaml → plugins/my-plugin/pluggin.yaml
          template/main.lua     → plugins/my-plugin/main.lua
          template/config.yaml  → plugins/my-plugin/config.yaml
          template/README.md    → plugins/my-plugin/README.md
  ↓
SDK 复制: sdk/jn.lua           → plugins/my-plugin/jn.lua
图标复制: template/avatar.png   → plugins/my-plugin/avatar.png
  ↓
输出: ✅ 插件创建成功 + 目录路径
```

### pack

```
用户: hago pack my-plugin（或 make pack NAME=my-plugin / pack --all / "redrock_*"）
  ↓
遍历: plugins/my-plugin/ 下所有文件（跳过 .zip）
  ↓
压缩: 创建 dist/my-plugin.zip
      · 内部路径为裸文件名（filepath.Rel(srcDir, path)，不带插件目录前缀）
      · 使用 Deflate 压缩 + 固定时间戳（可复现打包）
  ↓
输出: ✅ 打包完成 + 文件大小
```

> ⚠ 因为 zip 内部是裸文件名，经 `POST /api/v1/plugins/upload` 上传时服务端在根级找到 `pluggin.yaml`，推断出的目录名是 `.`，最终退化为临时文件名 `pluggin-<随机数>`，插件会被装成 `pluggin-<随机数>/`（主仓库 `internal/api/service/service.go:1227-1240`）。商店安装按元数据 `path` 安装，不受影响。

### scan

```
用户: hago scan（或 make scan）
  ↓
遍历: plugins/ 下所有子目录
      · 跳过非目录
      · 读取 pluggin.yaml
      · 查找图标 (avatar.png > logo.png > logo.jpg > icon.png)
      · 标记 has_config / has_readme
  ↓
排序: 按插件名不区分大小写排列
  ↓
分片: 每 300 条写入 metadata/chunk_N.json
  ↓
索引: 写入 plugins.json（含 updated_at）
  ↓
输出: ✅ 扫描完成 + 统计信息
```

### validate

```
用户: hago validate my-plugin --strict（或 make validate NAME=my-plugin）
  ↓
必需文件: pluggin.yaml / main.lua
建议文件: config.yaml / README.md / avatar.png（--strict 下缺失报错）
  ↓
字段: name / version 非空；version 建议 x.y.z
  ↓
config.yaml schema: type ∈ bool|string|list，key 非空
  ↓
输出: ✅ 校验通过 / 错误与警告列表
```

## paths.go 仓库定位逻辑

`hago` 从**任意目录**执行都能找到正确的仓库根目录（`tool/paths.go:10-39`）：

1. 从可执行文件所在目录开始，向上逐级查找包含 `plugins.json` 的目录
2. 未找到则从当前工作目录向上查找
3. 回退到 `.`（当前目录）

所有路径函数（`pluginsDir()` / `metadataDir()` / `templateDir()` / `sdkDir()` / `distDir()`）都基于此定位。

## dist/ 的定位

- `dist/` 在 `.gitignore:5` 中被忽略，贡献者本地 `git add dist/` 不会生效。
- 夜间 `metadata-update.yml` 执行 `hago scan` + `hago pack --all` 后，用 `git add -f metadata/ plugins.json dist/`（`.github/workflows/metadata-update.yml:46`）强制跟踪并提交，商店才能从仓库直接下载 zip。
- 因此 PR 只需提交 `plugins/` 源码，不要手改 `metadata/`、`plugins.json` 或 `dist/`。
