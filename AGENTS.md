# AGENTS.md

Guidance for agent sessions working in this repo. 本仓库是 JuanNiang-Neo 的官方 Lua 插件仓库：插件源码（`plugins/`）、SDK（`sdk/`）、元数据（`metadata/` + `plugins.json`）与脚手架工具（`tool/`，二进制 `hago`）。提交插件前用 `./hago validate <name> --strict` 校验。

## 分支保护与贡献规则

主分支（`main`）已启用分支保护，**禁止直接向主分支提交代码**：

- **仓库内贡献者（读写权限）**：所有代码修改必须在**新建的分支**（如 `feature/xxx`、`fix/xxx`）上进行，然后通过 **Pull Request** 合并到主分支；直接 push 到 `main` 会被拒绝。
- **Fork 贡献者（含 agent 协作）**：可在自 fork 仓库的**主分支**上自由开发、提交（fork 的 `main` 不受上游分支保护限制）；但向本仓库贡献改动时，必须**基于功能分支**向本仓库发起 Pull Request；**禁止从 fork 仓库的主分支（`main`/`master`）直接发起 PR**，此类 PR 将被拒绝。
- **重要（agent 协作）**：当用户要求「发起 PR / 合并 PR」时，**不得把功能分支直接合并进 fork 自己的 `main`**——那只是本地合并，并不会把改动贡献给上游。应基于该功能分支向**上游仓库（`upstream`）**发起 Pull Request，由上游维护者合并。
- 主分支的合并只能通过 Pull Request 完成（详见 README 与 CONTRIBUTING.md）。
## 同步规则（上游更新处理）

- 提交 PR 前若上游（`upstream`）有更新，必须先在 GitHub 上点击 **Update branch**，再在本地执行 `git fetch upstream && git rebase upstream/main` 变基拉取，确保基于最新上游代码，避免冲突与覆盖他人提交。
- 必须使用 rebase 变基拉取上游提交，**禁止将上游提交 merge 到本地仓库**。
- 禁止在本地直接推送旧基点分支后绕过 rebase 发起 PR。

## 提交信息规范（重要）

遵循 [Conventional Commits 约定式提交](https://www.conventionalcommits.org/zh-hans/v1.0.0/)。

- **格式**：`<type>(<scope>): <subject>`，subject 后空一行接 body，末尾可选 footer
- **type**（必选）：

  | type | 用途 |
  |---|---|
  | `feat` | 新功能 |
  | `fix` | 缺陷修复 |
  | `docs` | 仅文档变更 |
  | `style` | 格式/样式，不影响逻辑 |
  | `refactor` | 重构，不改行为 |
  | `perf` | 性能优化 |
  | `test` | 测试 |
  | `build` | 构建系统/依赖 |
  | `ci` | CI 配置 |
  | `chore` | 其他不修改 src/test 的变更 |
  | `revert` | 回退先前的提交 |

- **scope**（可选）：影响范围（模块/组件/文件名）。本项目常用：
  `plugins/<name>`（具体插件）、`sdk`（jn.lua SDK）、`tool`（hago CLI）、
  `metadata`（元数据/商店索引）、`docs`（文档）、`config`（工程配置）
- **subject**：中文、简短（≤50 字），概括本次提交的动机而非过程
- **body**：说明改动点、影响范围与必要背景；用**多个独立 `-m`** 组织
  （第一个 `-m` 为标题，后续每个 `-m` 一段无序列表项）；
  **禁止**用 `\n` 把多条说明塞进单个 `-m` 伪装多段
- **footer**（可选）：`BREAKING CHANGE:` 等；如需决策记录可用
  `Constraint:` / `Rejected:` / `Directive:` / `Tested:` trailer
- 示例：

  ```bash
  git commit \
    -m "feat(plugins/welcome): 新增每日问候模式" \
    -m "- 增加 config.yaml 的 greeting_mode 配置项" \
    -m "- 适配 jn.config 动态读取"
  ```
