# redrock_group_manager

红岩群管理工具

## 简介

- **作者**: Redrock
- **版本**: 1.0.0

红岩网校 QQ 群自动化管理工具，包含图片刷屏检测、+1 复读检测、广告违规/敏感违规拦截（全部词库来自 txt 文件）、QQ 群聊推荐卡片检测、三级惩罚、入群统计与数据监控等功能。

## 功能

- **图片刷屏检测**：短时间连续发图触发警告，重复刷屏自动禁言
- **+1 复读检测**：多人连续复读相同消息触发警告
- **广告违规**：广告词库命中或发送 QQ 群聊推荐卡片（`com.tencent.troopsharecard` / `com.tencent.contact.lua`，OneBot 11 json 消息段）即触发三级惩罚
- **敏感违规**：色情 / 政治 / 脏话词库命中即触发三级惩罚
- **三级惩罚**：同一用户第 1 次违规撤回+警告，第 2 次撤回+禁言 30 分钟，第 3 次撤回+踢出群聊（踢出后违规次数重置）
- **豁免**：管理员可用 `/豁免 QQ号` 或 `/豁免 @某人` 豁免账号，豁免后不再检测该账号并清除其全部违规记录；也可在面板配置页增删
- **管理员识别**：系统管理员 / 手动管理员（面板 `admin_users`）直接放行；群角色可识别时群主与管理员也放行
- **数据监控**：记录入群、警告、禁言、踢出、违规次数等统计数据

## 面板管理

豁免、手动管理员与违规记录持久化在 `config.yaml`（list 配置项），Web 面板「插件 → 配置」页可直接查看和增删修改，保存后自动重载生效：

| 配置项 | 说明 | 面板操作 |
| ---- | ---- | ---- |
| `exempt_users` | 豁免 QQ 列表 | 添加/删除（`/豁免` 命令也会写入） |
| `admin_users` | 手动管理员 QQ 列表 | 添加/删除 |
| `violations` | 违规记录，格式 `群号:QQ号:次数` | 查看违规人及等级；删除某行即重置该用户违规 |

## 词库

所有词条均来自 `words/` 目录下的 txt 文件，脚本内无任何预设词条，更新词库只需替换/新增文件后重启插件。

| 违规类型 | 词库文件 | 来源 |
| ---- | ---- | ---- |
| 广告 | `words/all.txt` | [campus-ad-detection-words](https://github.com/excniesNIED/campus-ad-detection-words) |
| 广告 | `words/cn_advertisement.txt` | CN 广告词库 |
| 敏感 | `words/cn_pornographic.txt` | CN 色情词库 |
| 敏感 | `words/cn_politics.txt` | CN 政治词库 |
| 敏感 | `words/cn_general.txt` | CN 脏话/通用词库 |

- 内存策略：仅在插件加载时读取一次，跨文件去重、小写化，只保留「广告」「敏感」两份数组；纯 ASCII 且短于 3 字符的 token 会被过滤，避免误命中正常英文单词

## 命令

| 命令 | 说明 |
| ---- | ---- |
| /groupstats | 查看群管理统计数据（仅管理员） |
| /豁免 QQ号 或 /豁免 @某人 | 豁免某用户，不再检测并清除其违规记录（仅管理员） |

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
| exempt_users | list | 豁免 QQ 列表 | [] |
| admin_users | list | 手动管理员 QQ 列表 | [] |
| violations | list | 违规记录(群号:QQ:次数) | [] |

## 许可

本项目遵循 MIT 许可证。