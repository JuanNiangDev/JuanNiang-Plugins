# 仓库结构与工作流

## 仓库架构

```
JuanNiang-Plugins/
│
├── hago                        ← CLI 入口二进制
├── plugins.json                ← 元数据分片索引
│
├── tool/                       ← CLI 源码（Go）
│   ├── main.go                    命令路由 + 美化输出
│   ├── init.go                    hago init 实现
│   ├── pack.go                    hago pack 实现
│   ├── scan.go                    hago scan 实现
│   └── paths.go                   自动定位仓库根目录
│
├── template/                   ← 模板文件（Go text/template）
│   ├── pluggin.yaml               {{.Name}} {{.Author}} 模板变量
│   └── main.lua                   插件入口模板
│
├── plugins/                    ← 插件源码（工作目录）
│   └── <plugin-name>/
│       ├── pluggin.yaml           元数据 · 必选
│       ├── main.lua               入口   · 必选
│       ├── jn.lua                 SDK    · 可选（hago init 自动复制）
│       └── *.png/*.jpg            素材   · 可选（scan 自动识别为 logo）
│
├── metadata/                   ← 分片元数据（hago scan 生成）
│   ├── chunk_1.json               [PluginEntry, ...] 最多 300 条
│   └── chunk_2.json
│
├── sdk/                        ← SDK 文件
│   └── jn.lua
│
└── docs/                       ← 文档
```

## 数据流

```
plugin.yaml                hago scan              chunk_n.json
   (每个插件)    ──────────→  读取并索引   ──────────→   (每片 ≤300 条)
                                  │
                                  ▼
                            plugins.json
                           {total, chunks}
```

### PluginEntry 结构

每条 chunk 记录包含：

```json
{
  "name": "welcome",
  "version": "1.0.0",
  "author": "JuanNiang",
  "description": "入群欢迎插件",
  "path": "welcome",
  "image": "welcome/logo.png"
}
```

- `name` / `version` / `author` / `description` — 从 `pluggin.yaml` 读取
- `path` — 插件在 `plugins/` 下的相对路径
- `image` — 插件目录下 `logo.png` / `logo.jpg` / `icon.png` 的相对路径（按优先级查找，无则省略）

### plugins.json 结构

```json
{
  "total": 42,
  "chunks": ["chunk_1.json", "chunk_2.json"]
}
```

- `total` — 插件总数
- `chunks` — 分片文件名列表（按序号排列）

### 分片策略

- 每片最多 **300 条** 记录（`chunkSize` 常量）
- 插件按名称字母序排列后切片
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
  ↓
SDK 复制: sdk/jn.lua           → plugins/my-plugin/jn.lua
  ↓
输出: ✅ 插件创建成功 + 目录路径
```

### pack

```
用户: hago pack my-plugin
  ↓
遍历: plugins/my-plugin/ 下所有文件
  ↓
压缩: 创建 plugins/my-plugin.zip
      · 内部路径为 my-plugin/<文件名>（符合 upload API 规范）
      · 使用 Deflate 压缩
  ↓
输出: ✅ 打包完成 + 文件大小
```

### scan

```
用户: hago scan
  ↓
遍历: plugins/ 下所有子目录
      · 跳过非目录
      · 读取 pluggin.yaml
      · 查找 logo (logo.png/jpg > icon.png)
  ↓
排序: 按插件名不区分大小写排列
  ↓
分片: 每 300 条写入 metadata/chunk_N.json
  ↓
索引: 写入 plugins.json
  ↓
输出: ✅ 扫描完成 + 统计信息
```

## paths.go 仓库定位逻辑

`hago` 从**任意目录**执行都能找到正确的仓库根目录：

1. 从可执行文件所在目录开始，向上逐级查找包含 `plugins.json` 的目录
2. 未找到则从当前工作目录向上查找
3. 回退到 `.`（当前目录）

所有路径函数（`pluginsDir()` / `metadataDir()` / `templateDir()`）都基于此定位。
