# redrock_group_manager

红岩群管理工具

## 简介

- **作者**: Redrock
- **版本**: 1.2.6

红岩网校 QQ 群自动化管理工具，包含图片刷屏检测、+1 复读检测、广告/敏感违规拦截（黑色地带直接处罚、灰色地带 LLM 审查）、QQ 群聊推荐卡片检测、三级惩罚、入群统计与数据监控等功能。

## 功能

- **图片刷屏检测**：短时间连续发图触发警告，重复刷屏自动禁言
- **+1 复读检测**：多人连续复读相同消息触发警告
- **黑色地带**：命中 `words/black.txt`（来源 [campus-ad-detection-words/样本.md](https://github.com/excniesNIED/campus-ad-detection-words/blob/main/样本.md) 抽取的无歧义话术，如贷款强提、假通知群、0元购、流量卡、修图日结等）或 `words/cn_advertisement.txt` 即触发三级惩罚
- **灰色地带 LLM 审查**：命中 `words/all.txt`（校园卡、考研、群名片、加群、加微信等语义模糊词）时**异步**送 Bot 自身 LLM 审查（`jn.llm`，复用 Bot Provider 配置，不阻塞消息流程），LLM 返回 JSON 判定违规类型（广告/敏感）后按三级惩罚追罚，判定正常则放行
- **敏感违规**：色情 / 政治 / 脏话词库命中即触发三级惩罚
- **三级惩罚**：同一用户第 1 次违规撤回+警告，第 2 次撤回+禁言 30 分钟，第 3 次撤回+踢出群聊（踢出后违规次数重置）
- **豁免**：管理员可用 `/豁免 QQ号` 或 `/豁免 @某人` 对某用户执行一次豁免——解除禁言并清空违规记录（**不加入白名单**，该用户仍参与正常违规检测）
- **白名单**：管理员可用 `/白名单 QQ号` 或 `/白名单 @某人` 将用户加入白名单（不再检测并清除违规记录；**若该用户处于禁言状态自动解除禁言**），`/解除豁免`（或 `/取消豁免`）从白名单移除并恢复检测；也可在面板配置页增删
- **管理员识别**：系统管理员 / 手动管理员（面板 `admin_users`）直接放行；群角色可识别时群主与管理员也放行
- **数据监控**：记录入群、警告、禁言、踢出、违规次数等统计数据

## LLM 审查说明

- 灰色词命中后通过 `jn.llm.chat_async` 异步调用 Bot 当前启用的文本模型 Provider（模型/采样参数/密钥全部复用 Bot 配置，插件不接触密钥），同一用户同一时刻只有一个在途审查，同一条消息 10 分钟内不重复审查
- LLM 返回 JSON：`{"violation": "ad|sensitive|none", "reason": "..."}`；`violation` 为 `ad`/`sensitive` 时按对应类别触发三级惩罚
- 系统提示词内置在 `main.lua` 的 `LLM_SYSTEM_PROMPT`，可自行调整
- 面板配置 `llm_review_enabled` 关闭后灰色词直接放行（不处罚不审查）

## 面板管理

白名单、手动管理员与违规记录持久化在 `config.yaml`（list 配置项），Web 面板「插件 → 配置」页可直接查看和增删修改，保存后自动重载生效：

| 配置项 | 说明 | 面板操作 |
| ---- | ---- | ---- |
| `exempt_users` | 白名单 QQ 列表 | 添加/删除（`/白名单` `/解除豁免` 命令也会写入） |
| `admin_users` | 手动管理员 QQ 列表 | 添加/删除 |
| `violations` | 违规记录，格式 `群号:QQ号:次数` | 查看违规人及等级；删除某行即重置该用户违规 |
| `llm_review_enabled` | 灰色地带 LLM 审查开关 | 开关；关闭后灰色词直接放行 |

## 词库

所有词条均来自 `words/` 目录下的 txt 文件，脚本内无任何预设词条，更新词库只需替换/新增文件后重启插件。

| 违规类型 | 词库文件 | 来源 |
| ---- | ---- | ---- |
| 黑色地带 | `words/black.txt` | [campus-ad-detection-words/样本.md](https://github.com/excniesNIED/campus-ad-detection-words/blob/main/样本.md) 抽取的无歧义广告话术 |
| 黑色地带 | `words/cn_advertisement.txt` | CN 广告词库 |
| 灰色地带（LLM 审查） | `words/all.txt` | [campus-ad-detection-words](https://github.com/excniesNIED/campus-ad-detection-words)（校园卡/考研/群名片/加群等灰色词） |
| 敏感 | `words/cn_pornographic.txt` | CN 色情词库 |
| 敏感 | `words/cn_politics.txt` | CN 政治词库 |
| 敏感 | `words/cn_general.txt` | CN 脏话/通用词库 |

- 内存策略：仅在插件加载时读取一次，跨文件去重、小写化，只保留「黑色」「灰色」「敏感」三份数组；黑色词条自动从灰色集合剔除（黑色优先）
- 纯 ASCII 且短于 3 字符的 token 会被过滤，避免误命中正常英文单词

## 命令

| 命令 | 说明 |
| ---- | ---- |
| /groupstats | 查看群管理统计数据（仅管理员） |
| /豁免 QQ号 或 /豁免 @某人 | 对某用户执行一次豁免：解除禁言、清空违规记录，不加入白名单（仅管理员） |
| /白名单 QQ号 或 /白名单 @某人 | 将某用户加入白名单：不再检测、清除违规记录，若被禁言自动解除（仅管理员） |
| /解除豁免 QQ号 或 /解除豁免 @某人 | 从白名单移除该用户，恢复检测（仅管理员） |
| /取消豁免 | 同 /解除豁免 |

## 配置

在 Web 管理面板「Plugin 管理」的插件详情「配置」页可调整本插件的配置。

| 配置项 | 类型 | 说明 | 默认值 |
| ---- | ---- | ---- | ---- |
| img_spam_window | string | 图片刷屏时间窗口(秒) | 2 |
| img_spam_threshold | string | 图片刷屏阈值 | 3 |
| img_mute_duration | string | 刷屏禁言时长(秒) | 60 |
| copy_threshold | string | 复读触发阈值 | 3 |
| enable_copy_check | bool | 是否启用复读检测 | true |
| violation_mute_seconds | string | 违规禁言时长(秒) | 1800 |
| llm_review_enabled | bool | 灰色地带 LLM 审查开关 | true |
| exempt_users | list | 白名单 QQ 列表 | [] |
| admin_users | list | 手动管理员 QQ 列表 | [] |
| violations | list | 违规记录(群号:QQ:次数) | [] |

## 许可

本项目遵循 MIT 许可证。
