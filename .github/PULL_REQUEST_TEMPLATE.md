## 贡献规则提醒

- **禁止从 fork 仓库的主分支（`main`/`master`）直接发起 PR**——此类 PR 将被拒绝。
- 本仓库对 `main` 启用了分支保护：所有变更须在**新建分支**上提交，通过 PR 合并；直接 push 会被拒绝。
- PR 标题遵循[约定式提交](https://www.conventionalcommits.org/zh-hans/v1.0.0/)：`<type>(<scope>): <subject>`，如 `feat(plugins/welcome): 新增每日问候模式`。

## 变更内容

<!-- 本次改了什么、为什么 -->

## 插件校验

- [ ] 已运行 `./hago validate <name> --strict`
- [ ] `pluggin.yaml` 的 `version` 已递增（更新已有插件时必填）

## 影响范围

- [ ] 插件（plugins/）
- [ ] SDK（sdk/）
- [ ] 工具（tool/）
- [ ] 元数据（metadata/）
- [ ] 文档

## 验证

<!-- 本地如何验证（命令/操作） -->
