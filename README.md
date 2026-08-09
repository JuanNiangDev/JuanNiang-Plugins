# JuanNiang Plugin Repository

JuanNiang-Neo 的官方插件仓库。

## 贡献规则（分支保护）

本仓库对主分支（`main`）启用了分支保护，**禁止直接向主分支提交代码**：

- **仓库内贡献者（读写权限）**：所有代码修改必须在**新建的分支**（如 `feature/xxx`、`fix/xxx`）上进行，然后通过 **Pull Request** 合并到主分支；直接 push 到 `main` 会被拒绝。
- **Fork 贡献者**：请在自 fork 的仓库中**新建分支**开发，再向本仓库发起 Pull Request；**禁止从 fork 仓库的主分支（`main`/`master`）直接发起 PR**，此类 PR 将被拒绝。
- 主分支的合并只能通过 Pull Request 完成。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 目录结构

```
JuanNiang-Plugins/
├── docs/           # 文档
├── sdk/            # jn.lua SDK（供 IDE 代码提示）
│   └── jn.lua
├── metadata/       # 插件元数据（分片存储，每片 300 条）
│   ├── chunk_1.json
│   ├── chunk_2.json
│   └── ...
├── plugins/        # 插件源码
│   ├── welcome/
│   ├── rich-demo/
│   └── ...
├── template/       # 脚手架模板
│   ├── pluggin.yaml
│   └── main.lua
├── tool/           # CLI 脚手架工具（Go）
├── plugins.json    # 分片索引
├── hago            # CLI 二进制
└── README.md
```

## 脚手架使用

```bash
# 构建 CLI
cd tool && go build -o ../hago .

# 创建新插件
./hago init my-plugin

# 打包插件
./hago pack my-plugin

# 扫描仓库，更新元数据
./hago scan
```

## 插件格式

每个插件是一个目录，包含以下文件（新格式 5 件套）：

```
plugins/<name>/
├── main.lua       # 插件入口（Lua 程序）
├── pluggin.yaml   # 插件元数据
├── config.yaml    # 动态配置声明（type: bool/string/list）
├── README.md      # 插件说明文档
└── avatar.png     # 插件图标
```

详见 [JuanNiang-Neo 插件开发文档](https://github.com/JuanNiangDev/JuanNiang-Neo/blob/main/docs/plugin-development.md) 与 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 审核流程

提交 PR 后 CI 自动校验格式与版本（见 `.github/workflows/plugin-review.yml`），维护者 Review + Merge 后，每晚 UTC 16:00 自动更新元数据（见 `.github/workflows/metadata-update.yml`）。
