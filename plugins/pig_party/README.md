# pig_party 猪猪派对

群聊猪猪表情趣味插件：**今日小猪**（每日每人固定一只、原图直发）、**随机小猪**（群内去重防刷屏）、**含猪字自动回复**（带白名单/概率/冷却三重保护）。

复刻自 [astrbot_plugin_pig_party](https://github.com/Mitsukikis/astrbot_plugin_pig_party)，深度适配 JuanNiang-Neo 架构（Lua + Redis + Neo 图床）。

## 功能特色

1. **直接发送原图**：
   - 绝不搞多余的拉伸与 800×800 卡片合成，1:1 保留原图比例与高清画质；
   - 完整支持静态图片（JPG/PNG/WebP）与动态 GIF。
2. **今日小猪稳定可复现**：
   - 每人每天固定一只小猪，全天多次抽取结果完全一致；
   - 附带小猪个性称号文本；
   - 可通过 `/今日小猪 @群友` 查看他人的今日小猪。
3. **随机小猪智能去重**：
   - 接入 Redis 记录本群最近发送过的图片列表，短时间内绝不连续重复发送同一张表情。
4. **含猪字自动回复**：
   - 群消息包含 `猪`、`🐷`、`🐖`、`🐽` 时按概率回复；
   - **默认关闭**，需管理员在后台手动开启；拥有群白名单、触发概率、群冷却时间保护，避免打扰严肃工作或考研群。
5. **图床多源整合与脚本导入**：
   - 支持挂载多个卷娘 Neo 图床虚拟文件夹；
   - 支持后台配置多条自定义外链（格式 `名称=URL` 或直接填 `URL`）；
   - 内置 `scripts/fetch_pighub.py` 自动化抓取脚本，一键拉取 [PigHub](https://pighub.top/#/all) 1300+ 热门小猪表情并批量上传到卷娘图床！

---

## 使用指令

| 指令 | 别名 | 说明 |
| :--- | :--- | :--- |
| `/今日小猪` | `/抽小猪` `/我的小猪` `/rollpig` | 抽取或查看自己的今日小猪（原图 + 称号） |
| `/今日小猪 @某人` | — | 查看被艾特群友的今日小猪（需开启 `at_view_pig`） |
| `/随机小猪` | `/随机猪猪` `/猪猪` `/rollpig_random` | 随机发送一张猪图表情（带群内去重） |
| 普通消息含 `猪` | `猪` `🐷` `🐖` `🐽` | 自动回复一张随机猪图（需后台手动开启） |

> 说明：命令前缀由实例配置决定，上表以默认 `/` 为例。

---

## 后台配置说明 (`config.yaml`)

| 配置项 | 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `enable_groups` | 列表 | `[]` | 启用群列表，**留空表示所有群生效**；填 `*` 亦表示全部 |
| `image_bed_folders` | 列表 | `["pig_party"]` | 关联的卷娘图床虚拟目录（可填多个，如 `pig_party`） |
| `custom_pig_images` | 列表 | `[]` | 额外自定义单张/多张外链，如 `干饭猪=https://example.com/a.gif` |
| `auto_reply_pig_messages` | 布尔 | `false` | 普通消息含猪自动回复开关（默认关，防打扰） |
| `pig_trigger_keywords` | 字符串 | `猪,🐷,🐖,🐽` | 自动回复触发关键词，中英文逗号隔开 |
| `auto_reply_probability` | 字符串 | `50` | 命中关键词后的回复概率（1-100，默认 50%） |
| `auto_reply_cooldown_seconds` | 字符串 | `15` | 同一群内两次自动回复的最小间隔秒数 |
| `command_cooldown_seconds` | 字符串 | `3` | 主动指令（今日小猪/随机小猪）冷却秒数 |
| `random_recent_limit` | 字符串 | `8` | 随机猪图最近去重数量（避免连发相同表情） |
| `at_view_pig` | 布尔 | `true` | 是否允许 @群友 查看其今日小猪 |
| `pool_cache_seconds` | 字符串 | `300` | 图池在内存与 Redis 中的缓存秒数 |

---

## PigHub 表情导入脚本 (`scripts/fetch_pighub.py`)

插件内置了极简的 PigHub 抓取脚本，依赖仅需 Python 3 标准库：

```bash
cd data/pluggins/pig_party/scripts

# 1. 预览有哪些小猪表情（不下载）
python3 fetch_pighub.py --dry-run --limit 20

# 2. 一键批量上传到当前卷娘 Neo 图床（自动创建 /pig_party 目录，跳过重名）
python3 fetch_pighub.py \
    --neo-url http://127.0.0.1:8090 \
    --username admin \
    --password 'Admin123' \
    --folder pig_party \
    --skip-existing \
    --limit 200

# 3. 或者只下载到本地目录供挑选
python3 fetch_pighub.py --output-dir ./pigs --limit 100
```

---

## 权限依赖

`onebot11`（消息收发） / `cache`（Redis 去重与每日定格） / `image`（卷娘图床读取） / `file`

## 作者

Churnie HXCN（复刻自 Mitsukikis 的 astrbot_plugin_pig_party）
