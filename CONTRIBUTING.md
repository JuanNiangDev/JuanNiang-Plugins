# 贡献指南（Contributing）

欢迎向 JuanNiang 插件仓库贡献插件！本文档说明如何提交新插件、更新已有插件，以及审核流程。

## 分支与提交规则

本仓库对主分支（`main`）启用了分支保护，**禁止直接向主分支提交代码**：

- **仓库内贡献者（读写权限）**：所有修改必须在**新建的分支**（如 `feature/xxx`、`fix/xxx`）上进行，通过 **Pull Request** 合并到 `main`；直接 push 会被拒绝。
- **Fork 贡献者**：请在 fork 中**新建分支**开发后再发起 PR；**禁止从 fork 的主分支（`main`/`master`）直接发起 PR**，此类 PR 将被拒绝。
- 主分支合并一律走 Pull Request。

## 插件格式（新格式 5 件套）

每个插件位于 `plugins/<name>/` 目录，必须包含：

| 文件 | 必填 | 说明 |
|------|------|------|
| `main.lua` | ✅ | 插件入口（默认入口文件） |
| `pluggin.yaml` | ✅ | 插件元数据（name/version/author/description/entry/permissions/system/enabled） |
| `config.yaml` | ✅ | 动态配置声明（可选配置项为空时写 `configs: []`） |
| `README.md` | ✅ | 说明文档（商店详情页渲染） |
| `avatar.png` | ✅ | 图标（商店网格卡片展示，建议正方形） |

### `config.yaml` 声明格式

```yaml
configs:
  - key: <key>
    type: bool|string|list
    label: 展示名
    description: 说明
    default: <默认值>
    value: <用户当前值，可省略>
```

- `type: bool` → Web 面板开关
- `type: string` → Web 面板单行输入框
- `type: list` → Web 面板可增删的多项输入框

插件内通过 `jn.config.get("key")` 读取配置（`value` 优先，回退 `default`）。

## 提交新插件

1. **Fork** 本仓库。
2. 在 `plugins/<name>/` 创建 5 件套。
3. 本地校验：
   ```bash
   make build                  # 编译 hago 工具
   ./hago validate <name> --strict
   ```
4. 提交 PR，CI 会自动校验格式与版本。

## 更新已有插件

- 修改 `plugins/<name>/` 下文件时，**必须递增** `pluggin.yaml` 的 `version`（CI 会检查）。
- 更新后运行 `./hago validate <name> --strict` 确认无误。

## 审核流程（PR 即审核）

1. CI（`plugin-review.yml`）自动运行：
   - 校验格式（必需文件 / config.yaml schema / 版本递增）
   - 失败时在 PR 留言提示
2. 维护者（见 `.github/CODEOWNERS`）**Review + Merge**。
3. Merge 后，每晚 UTC 16:00 的 `metadata-update.yml`（或手动触发）自动重新 `scan`，更新 `metadata/` 与 `plugins.json`，商店可见新插件。

## 元数据与商店

- `./hago scan` 扫描 `plugins/` 生成 `metadata/chunk_*.json` 与 `plugins.json`。
- 主项目「Plugin 商店」读取这些元数据并支持安装。

## 开发工具

```bash
make init NAME=my-plugin   # 交互式创建新插件（5 件套）
make pack NAME=my-plugin   # 打包为 zip
make scan                  # 更新元数据
```