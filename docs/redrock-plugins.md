# Redrock 插件全集文档

> 最后更新: quiz 改用 PostgreSQL 持久化 + `/答` 命令 + 4 次答错上限；部门链接改为腾讯文档

## 一、插件总览

| 插件 | 类型 | 权限 | 功能 | 核心触发 |
|------|------|------|------|---------|
| `redrock_welcome` | `on_notice` | `onebot11` + `timer` | 入群欢迎 | 新人进群自动触发 |
| `redrock_faq` | 命令 | `onebot11` | 关键词问答（37 条查询） | `/redrock <关键词>` |
| `redrock_special` | `on_message` | `onebot11` | 卷娘彩蛋 | @卷娘 + 特定关键词 |
| `redrock_caidanci` | `on_message` + 命令 | `onebot11` + `cache` | 猜单词游戏 | `/猜单词` 开局，`/猜 <词>` 猜测 |
| `redrock_caidanci_grade` | `on_message` + 命令 | `onebot11` + `cache` + `file` + `t2i` | 分级猜单词（七档难度） | `/猜单词 [难度] [长度]` 开局 |
| `redrock_quiz` | 命令 | `onebot11` + `database` | 红岩快问快答 | `/来一局` 开局，`/答 <答案>` 答题 |
| `redrock_code` | `on_message` + 命令 | `onebot11` + `http` | 在线代码运行 | `/code <语言>` + 换行代码 |
| `redrock_poke` | `on_notice` | `onebot11` + `image` | 戳一戳回复 | 戳卷娘 |
| `redrock_group_manager` | `on_message` + `on_notice` + 命令 | `onebot11` + `database` + `file` + `llm` + `timer` | 群管理工具 | 自动检测 + `/groupstats` |
| `redrock_cron_msg` | `on_cronjob` | `onebot11` | 定时消息 | CronJob JSON 配置触发 |
| `redrock_delicious` | `on_cronjob` | `onebot11` | 干饭语录定时推送 | CronJob JSON 配置触发 |
| `redrock_fanzha` | 命令 | `onebot11` + `cache` | 开学季反诈提醒 | `/反诈提醒` / `/全体反诈提醒` |

---

## 二、插件详情

### 2.1 redrock_welcome — 入群欢迎

**触发条件**: `on_notice` 监听 `group_increase` 事件

**行为**: 新成员加入群聊时**攒批**发送：攒满 `batch_size`（默认 15）人立即统一发送；首人入队起 `flush_seconds`（默认 3）秒内未攒满则到点发送现有缓冲（`main.lua:23-48`、`:72`）。一条消息内逐个 @ 本批成员，后接欢迎语与海报。

**回复格式**:
```
@xxx @yyy 欢迎到来！这里是红岩网校工作站的新生群，有什么问题都可以问我哦！
没有头绪就试试发送/redrock吧。
[welcome.png]
```

**技术细节**: 
- 事件类型: `notice_type == "group_increase"`
- 消息格式: 富文本段 `{at × N, text, image}`，图片默认 `welcome.png`（`main.lua:39-42`）
- 攒批计时用 `jn.timer.after`（`timer` 权限），发送后递增代际号让在途旧 timer 空转（`main.lua:23-25`、`:72`、`:82-87`）
- 与 faq 的 `/redrock` 命令形成引导闭环：欢迎 → `/redrock` 查询清单

---

### 2.2 redrock_faq — 关键词问答（命令式）

**触发条件**: 只有一条命令 `/redrock <关键词>`（`plugins/redrock_faq/main.lua:180-201`），**没有 `on_message` 回调**——裸发关键词、@卷娘 都不会触发。

**匹配策略**（`main.lua:161-175`）：先**精确匹配**（`names` 任一项与输入完全相同），未命中再**双向包含匹配**（`key:find(n, 1, true)` 或 `n:find(key, 1, true)`，且两边长度都 ≥ 2，避免短词误命中）。

**查询条目**: `QUERIES` 共 **37 条**（`main.lua:72-120`），覆盖网校/部门介绍、加入方式、位置、学习收获、招新成果、新生导航、趣味功能、3G 科普、重邮特色，以及卷娘日常闲聊语料。

| 关键词（`names` 别名，忽略大小写） | 回复 |
|--------|------|
| `网校` / `红岩` / `redrock` / `介绍` / `是什么` / `网校介绍` / `红岩网校` | 红岩网校总体介绍 🔗 |
| `部门` / `部门介绍` / `有哪些部门` | 七个部门清单 |
| `产品` / `产品策划` / `产品策划及运营部` | 产品策划及运营部介绍 🔗 |
| `视觉` / `视觉设计部` | 视觉设计部介绍 🔗 |
| `前端` / `前端研发部` | 前端研发部介绍 🔗 |
| `后端` / `后端研发部` | 后端研发部介绍 🔗 |
| `移动` / `移动开发` / `移动开发部` / `移动部` | 移动开发部介绍 🔗 |
| `安卓` / `android` / `android开发` | Android 子部门介绍 🔗 |
| `ios` / `ios开发` | iOS 子部门介绍 🔗 |
| `运维` / `运维安全` / `运维安全部` / `安全` / `sre` | 运维安全部介绍 🔗 |
| `ai` / `人工智能` / `人工智能开发` / `人工智能开发及应用部` | AI 开发部介绍 🔗 |
| `加入` / `报名` / `怎么加入` / `如何加入` / `加入方式` / `报名方式` | 加入方式 + `join.png` 二维码 |
| `位置` / `地点` / `在哪` / `地址` / `怎么去` / `太极运动场` | 太极运动场指引 |
| `学习` / `能学到` / `能学到什么` / `学到什么` / `收获` | 学习收获介绍 🔗 |
| `招新` / `活动` / `宣讲会` / `招新宣讲会` | 招新活动介绍 🔗 |
| `成果` / `成就` | 红岩网校成果展示 |
| `新生导航` / `导航` | GIS 校园地图 URL |
| `趣味功能` / `功能` / `游戏` / `玩什么` | 游戏清单（猜单词/快问快答/运行代码） |
| `3g` / `芯片` / `3g芯片` | 通芯一号芯片完整科普（长篇） |
| `特色` | 重邮三宝：3G芯片/早操工程/校园跑 |
| `在吗` / `在不在`、`对象` / `单身` / `有对象`、`内卷`、`摆烂` / `躺平`、`emo` / `难过`、`吃饭` / `吃什么` / `食堂`、`早八` / `好困` / `好累`、`学长` / `大佬`、`重邮` / `学校`、`感谢` / `谢谢`、`拜拜` / `再见` / `晚安`、`校花`、`学不会` / `学不懂` / `太难了`、`无聊`、`6` / `666`、`干嘛` / `在干嘛`、`摸鱼` / `在摸鱼` | 卷娘日常闲聊语料（`摸鱼` 附 `xu.png`） |

**命令**:

| 命令 | 功能 |
|------|------|
| `/redrock` | 无参数时显示可查询清单（`MENU`，`main.lua:123-142`） |
| `/redrock <关键词>` | 按 `QUERIES` 精确 → 双向包含匹配，命中则回复对应内容 |
| `/redrock <未命中关键词>` | 回复"没有找到…试试 /redrock 查看查询清单吧～" |

**技术细节**:
- 输入先 trim + 转小写再匹配（`main.lua:187`）
- 群聊回复为 `@提问者 + 文本 [+ 图片]` 富文本段，私聊只发文本（`main.lua:147-158`）

---

### 2.3 redrock_special — 卷娘彩蛋

**触发条件**: @卷娘 + 关键词（宽松子串匹配）

| 关键词 | 回复 | 图片 |
|--------|------|------|
| `年龄` / `年纪` / `芳龄` / `多大了` | 有些事情你还是不要知道的好 | `img/q1/` 随机2选1 |
| `身高` | 不会吧，不会吧，不会真的有人要问女生的身高吧。 | `img/q2/` 随机2选1 |
| `体重` | emmmm你要不问问别的？ | `img/q3/` 随机2选1 |
| `喜欢什么颜色` / `什么颜色` / `喜欢啥颜色` | 当然是红色！毕竟我是红岩网校的卷娘～ | — |
| `周末干嘛` / `周末干什么` / `周末做什么` | 帮管理员整理文件，偷偷玩猜单词和快问快答 —— 悄悄说我胜率 80% 哦！ | — |

**技术细节**:
- 图片: `math.random(#images)` 随机选取
- emo 关键词已移至 faq 统一管理（避免两个插件对同一关键词给出不同回复）

---

### 2.4 redrock_caidanci — 猜单词游戏

**触发条件**: 命令触发 + 引导词推荐

| 命令 | 功能 |
|------|------|
| `/猜单词 [-l 4/5/6]` | 开局（默认5字母，同群共享） |
| `/猜 <单词>` | 提交猜测 |
| `/提示` | 获取线索（最多4次: 类别→首字母→尾字母→详细） |
| `/结束` | 认输看答案 |

**规则**: 6次机会，🟩=位置正确，🟨=字母存在，⬜=不存在

**引导触发词**: `没意思` / `没劲` / `有啥好玩` / `玩什么` → 推荐玩游戏

> ⚠️ `无聊` 触发词已移至 faq，避免与 faq "来杯好茶摇一摇" 冲突

**单词库**: 66 条（去重后 65 个单词，`commit` 重复一次），分 4 类：技术 47 / 通用 12 / 校园 6 / 水果 1（`main.lua:12-84`），含红岩相关提示

**技术细节**:
- 状态: `jn.cache`（Redis）按群 key 隔离（`main.lua:103-118`），插件重载不丢局
- 匹配: Wordle 规则（绿色→黄色→灰色三轮扫描）
- 英语猜词: 仅 `/猜 <word>` 命令触发，裸发单词不响应

---

### 2.5 redrock_quiz — 红岩知识快问快答

**触发条件**: 命令触发

| 命令 | 功能 |
|------|------|
| `/来一局` / `/快问快答` | 开局（随机抽5题） |
| `/答 <答案>` | 提交答案 |
| `/结束快答` | 中途退出（显示得分） |

**规则**:
- 答对夸夸 + 下一题
- 答错给提示，**最多答错 4 次**，用完公布正确答案并结束
- 题目可重复回答直到答对（答错只扣次数不跳题）

**评分**:
- 🏆 100%: 满分通关
- 🎯 ≥80%: 红岩知识达人
- 👍 ≥50%: 不错哦
- 📖 <50%: 附腾讯文档 Q&A 链接

**题库**: 8 道红岩知识题（`main.lua:15-54`），每局随机抽 5 题（`questions_per_game` 可配，`main.lua:75`）。判定按每题声明的策略（`check_answer`，`main.lua:174-198`）：
- 任意命中（默认）: `match` 中任一关键词出现即算对，如 "是"/"2000年10月"
- 全词匹配（`match_all`）: 七个部门名必须全部出现
- 最少 N 命中（`match_min`）: 核心产品至少命中 2 个、加入方式至少命中 3 个

**技术细节**:
- 权限: `onebot11` + `database`
- 存储: 内存缓存 + PostgreSQL KV 表（`INSERT ... ON CONFLICT`），重启不丢
- 状态按 `群:用户` 隔离
- 裸发文字不响应，答案必须走 `/答` 命令

---

### 2.6 redrock_code — 在线代码运行

**触发条件**: `/code <语言> [输入参数]` + 换行后的代码块

**示例**:
```
/code py Alice Bob
a = input()
b = input()
print("Hello " + a + " & " + b)
```

**支持语言**: 44 个 Judge0 language_id（`main.lua:18-63` 的 `language_map` 共 61 个别名键，多别名指向同一 id）

**技术细节**:
- 后端: Judge0 `/submissions?wait=true` 同步模式
- Judge0 URL: 配置在 `JUDGE0_BASE_URL` 变量
- 输入: 空格自动替换为 `\n`
- 输出: 自动截断 1500 字符
- 格式: `🔧 Python 3 | 0.01s 3100KB\n\n[输出]`
- 用法提示: 无参数或仅指定语言时附带 `example.png`

---

### 2.7 redrock_poke — 戳一戳回复

**触发条件**: `on_notice` 监听 `notify/poke` 事件

**回复库**: 18条，分四类，防连续重复
- 俏皮傲娇 (5条): 狮子座炸毛、18岁娇贵、爱干净等
- 红岩招新引导 (4条): 引导 `/redrock` / @卷娘 提问
- 游戏功能引导 (4条): 猜单词 → 快问快答 → 运行代码 → Python玩笑
- 人设介绍 + 红岩 (5条): 重庆南岸区、7月31生日、座右铭等

**技术细节**:
- `last_index` 缓存，避免连续两次相同回复
- 回复格式: `[CQ:at,qq=xxx] + 文本`

---

### 2.8 redrock_group_manager — 群管理工具

**检测模块** (优先级见 `on_message`，`main.lua:951-968`):

| 优先级 | 模块 | 触发条件 | 行为 | 管理员通知 |
|--------|------|---------|------|----------|
| 1 | 敏感 / 黑色地带 / 灰色地带（见下） | 消息命中词库 | 三级惩罚（LLM 复核见下） | ✅ DM |
| 2 | 图片刷屏 | 默认 2s 内 ≥3 张 | 警告 + `shuaping.png` → 再犯禁言 60s | ✅ (禁言时) |
| 3 | +1 复读 | 默认 3 人同消息 | `shuaping_2.png`（不 @） | — |

**词库三分类**（`main.lua:40-44`，运行期合并条数）：

| 类别 | 词库文件 | 运行期条数 | 处理 |
|------|---------|-----------|------|
| `black` | `words/black.txt` + `words/cn_advertisement.txt` | 845 | 无歧义广告词 → LLM 高危复核，确认后三级惩罚 |
| `sensitive` | `words/cn_pornographic.txt` + `words/cn_politics.txt` + `words/cn_general.txt` | 1009 | 色情/政治/脏话/辱骂 → LLM 高危复核 |
| `gray` | `words/all.txt`（剔除 black 重叠后） | 426 | 语义模糊 → 常规 LLM 审查，违规后追罚 |

**三级惩罚**（`handle_violation`，`main.lua:616-664`）：同一用户第 1 次撤回+警告，第 2 次撤回+禁言 30 分钟，第 3 次撤回+踢出（踢出后次数重置）。

**豁免/白名单**: 管理员与群主放行；`/豁免`（一次性解禁+清空违规）、`/白名单`（长期不检测）由管理员操作；`event.admins` 内的 QQ 同样放行。

**统计命令**: `/groupstats`（管理员）输出今日入群 `stats:join:<日期>` / 刷屏警告 `stats:warn` / 刷屏禁言 `stats:mute` / 复读警告 `stats:copy_warn` / 广告违规 `stats:ad`+`stats:card` / 敏感违规 `stats:sensitive` / 踢出 `stats:kick`（`main.lua:991-998`）。

**技术细节**:
- 存储: 内存缓存 + PostgreSQL KV 表（`INSERT ... ON CONFLICT`）
- 图片检测: 匹配 `[CQ:image` / `[CQ:face` / `[CQ:mface` / `[图片]` / `[表情]`
- 消息撤回: `jn.onebot11.delete_msg(message_id)`
- LLM 复核：`jn.llm.chat_async` 异步提交，`on_chat_response` 按 `req_id` 取回上下文追罚（`main.lua:802-901`）

---

### 2.9 redrock_cron_msg — 定时消息

**触发条件**: CronJob 定时触发 `on_cronjob`（`main.lua:15`；引擎派发入口 `internal/pluggin/pluggin.go:1150`）

**Payload 格式**:
```json
{
  "groups": [123456789, 987654321],
  "message": "今天晚上12点卷娘可要清理掉不按规矩改名的同学了哦！再提醒一遍，格式是年级-专业-姓名哦！"
}
```

**技术细节**:
- 支持多群并发发送
- 消息内容完全由 JSON 配置，无需改代码

#### 📌 如何配置 CronJob 发定时消息

1. **打包上传**: `make pack NAME=redrock_cron_msg`，将 `dist/redrock_cron_msg.zip` 上传到 JuanNiang-Neo 的插件市场/`data/pluggins/` 并启用

2. **进入定时任务页面**: Web 面板 → 定时任务 → 新建任务

3. **填写配置**:

   | 字段 | 值 |
   |------|-----|
   | 名称 | 例如「改名提醒」 |
   | Cron 表达式 | 见下方参考 |
   | 目标插件 | 选择 `redrock_cron_msg` |
   | Payload (JSON) | 见下方示例 |

4. **Payload 示例**（换成真实群号）:
   ```json
   {
     "groups": [123456789, 987654321],
     "message": "今天晚上12点卷娘可要清理掉不按规矩改名的同学了哦！再提醒一遍，格式是年级-专业-姓名哦！"
   }
   ```

5. **Cron 表达式参考**:

   | 表达式 | 含义 |
   |--------|------|
   | `0 0 20 * * ?` | 每晚 20:00 |
   | `0 0 21 * * ?` | 每晚 21:00 |
   | `0 0 12 * * ?` | 每天中午 12:00 |
   | `0 30 18 * * ?` | 每天 18:30 |
   | `0 */2 * * * ?` | 每 2 小时一次 |

6. **多群多内容**: 想发不同内容到不同群，新建多个定时任务，每个任务配置不同的 `groups` + `message`

---

### 2.10 redrock_caidanci_grade — 分级猜单词

**触发条件**: 命令触发 + 引导词推荐（`on_message`，`main.lua:893`）

| 命令 | 功能 |
|------|------|
| `/猜单词 [难度] [长度]` | 开局（七档难度：高考/四级/六级/考研/雅思/托福/GRE，默认四级；长度 3–10，未指定时 4–6 随机） |
| `/猜 <单词>` / `/猜<单词>` | 提交猜测（无空格写法同样支持） |
| `/提示` | 每局仅一次：随机揭示一个正确字母，或给出词性与中文释义 |
| `/结束` | 结束当前游戏并展示棋盘 |
| `/怎么猜单词` | 查看玩法说明 |

**技术细节**:
- 棋盘反馈由 T2I 渲染为图片（本地 PoetsenOne 字体），T2I 不可用时降级为 emoji 文本（`pluggin.yaml` 申请 `t2i` 权限）
- 权限: `onebot11` + `cache` + `file` + `t2i`（`pluggin.yaml:6-10`）
- 状态按群隔离存于 `jn.cache`；词库文件通过 `jn.file` 读取
- 与 `redrock_caidanci` 注册同名 `/猜单词`、`/猜`、`/提示`、`/结束` 命令，命令树后注册覆盖先注册（`internal/pluggin/command.go:71-76`），两者同时启用时以加载顺序靠后者为准，建议二选一

---

### 2.11 redrock_delicious — 干饭语录

**触发条件**: CronJob 定时触发 `on_cronjob`（`main.lua:60`）

**Payload 格式**:
```json
{ "groups": [123456789, 987654321] }
```

**技术细节**:
- 内置 20 条语录（中心食堂一楼/二楼 + 校外觅食推荐），每条以"该吃饭了，卷娘到 xxx 吃了 xxx"开头
- 面板配置 `extra_quotes`（list）可追加自定义语录
- 权限: `onebot11`（`pluggin.yaml:6-7`）
- cron 示例：`0 30 11 * * *`（每天 11:30）

---

### 2.12 redrock_fanzha — 开学季反诈提醒

**触发条件**: 命令触发

| 命令 | 功能 |
|------|------|
| `/反诈提醒` | 向当前会话发送反诈指南图文（限流） |
| `/全体反诈提醒` | 指南前附加 @全体成员（仅群聊 + 指定发送人 + 限流） |

**技术细节**:
- 权限: `onebot11` + `cache`（`pluggin.yaml:6-8`）
- 限流以会话为粒度（群号/私聊 QQ），普通版与 @全体成员版共用同一额度，通过 Redis cache TTL 实现（插件重载不影响计数）
- 图文末尾附图 `anticheat.png`；配置项见 `config.yaml`（`enabled` / `image_file` / `at_all_senders` / `rate_limit_enabled` / `rate_limit_minutes`）

---

## 三、语料库交叉引用

| 关键词 | 归属插件 | 说明 |
|--------|---------|------|
| `无聊` | faq | "来杯好茶摇一摇"，faq 独有，caidanci 已移除 |
| `emo` | faq | "请你吃杂酱面"，faq 统一管理，special 已移除 |
| `卷` | — | 已移除，仅保留 `内卷` |
| `年龄/身高/体重` | special | 彩蛋问答 + 随机图片 |
| `戳一戳` | poke（实际处理事件） | 只有 `redrock_poke` 的 `on_notice` 处理 `notify/poke` 事件（`main.lua:156-158`）；faq 仅在"趣味功能"回复正文里文字提及（`main.lua:32`），special 与戳一戳无关 |
| `猜单词` | caidanci + caidanci_grade + poke + faq | 命令在 `redrock_caidanci` / `redrock_caidanci_grade`；poke 与 faq 仅正文文字引导 |
| `快问快答` | quiz + poke + faq | 命令在 `redrock_quiz`；poke 与 faq 仅正文文字引导 |
| `运行代码` | code + poke + faq | 命令在 `redrock_code`；poke 与 faq 仅正文文字引导 |

---

## 四、匹配策略总结

| 策略 | 适用插件 | 规则 |
|------|---------|------|
| 精确匹配 | faq | 输入（trim + 小写）恰好等于 `names` 中任一项 |
| 双向包含 | faq | 精确未命中时，`key` 含 `name` 或 `name` 含 `key`，且两者长度均 ≥2（`main.lua:167-173`） |
| 宽松子串 | special | 消息中出现即命中 |
| 命令系统 | caidanci / caidanci_grade / quiz / code / faq / fanzha / group_manager | `/xxx` 前缀，优先级高于 `on_message` |
| 关键词集合匹配 | quiz | `match_all`（全命中）/ `match_min`（至少 N 个）/ 任意命中（`main.lua:174-198`） |

---

## 五、加载顺序建议

1. `redrock_welcome` — 入群欢迎（`on_notice`，不阻塞 message）
2. `redrock_group_manager` — 群管理（安全兜底，率先拦截违规消息）
3. `redrock_faq` — 核心问答（纯命令式，`/redrock <关键词>`）
4. `redrock_special` — 彩蛋（faq 后处理未命中的特殊关键词）
5. `redrock_caidanci` — 猜单词（命令为主，引导词在 faq 之后）
6. `redrock_quiz` — 快问快答（命令为主）
7. `redrock_code` — 代码运行（命令为主）
8. `redrock_poke` — 戳一戳（`on_notice`，不阻塞 message）
9. `redrock_cron_msg` — 定时消息（`on_cronjob`，独立触发）
10. `redrock_delicious` — 干饭语录（`on_cronjob`，独立触发）
11. `redrock_fanzha` — 反诈提醒（命令为主）
12. `redrock_caidanci_grade` — 分级猜单词（命令为主，与 `redrock_caidanci` 同名前缀命令，建议二选一启用）
