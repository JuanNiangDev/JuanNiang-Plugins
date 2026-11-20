# cyber_chaunzi · 赛博串子

接 [searchanythingfun](https://searchanythingfun.xyz/docs) 的素材检索，在群里当串子：**只发表情包**，按概率自动串，或者用命令手动开串。

## 行为

| 场景 | 输出 |
|------|------|
| 后台静默（`mode=both/silent`） | 每条群消息按 `silent_probability`（默认 3%）触发，检索一张合适表情包发出 |
| `/开串`（`mode=both/manual`） | 本群进入串子模式（写入数据库，重启仍在），之后每条消息按 `session_probability`（默认 100%）触发 |
| `/串子出去` | 结束串子模式，并删除数据库会话 |
| 开串 / 结束 / 每次串完 | 可分别发送一个 QQ 表情包（`stk://<短ID>`，走 `send_group_sticker`） |

- 串的落点是**独立的一条图片消息**，不带文字、不引用原消息。
- 同一群 `cooldown_seconds`（默认 60s）内最多串一次；每群每天最多 `daily_cap` 次。
- 同一群同一时刻只跑一个检索请求（`inflight`）。
- 纯图片/纯表情消息（去掉 CQ 码后不足 `min_chars`）跳过——检索需要文字。

## 选材接口

`POST /api/reply`（AI 选材，20 次/天）优先；取不到带图片的素材时自动退回 `POST /api/search`（语义检索，500 次/天、30 次/分）。

- `api_mode=hybrid`（默认）：先 reply，失败/无图 → search
- `api_mode=search`：只用检索
- `ai_daily_cap`：本地记账，AI 调用达到上限后自动只用检索
- `quota_guard_min`：当日检索剩余低于该值时，触发概率降到 20%
- HTTP 429：该群冷却 60 秒，不重试

素材图片字段是相对路径（`/api/media/...`），发送前补全为 `https://www.searchanythingfun.xyz/api/media/...`；如协议端拉不到，可配 `image_proxy_prefix`（例如 `https://wsrv.nl/?url=`）。

## 配置要点

- `mode`：`both` / `silent`（只静默，命令不可用）/ `manual`（只手动）
- `target_groups`：留空=所有群
- `admin_only` + `admins`：限制谁能 `/开串`
- `emoji_start` / `emoji_end` / `emoji_each`：QQ 表情包短 ID，可写 `stk://xxx` 或裸 `xxx`；对应 `*_enabled` 开关
- `proxy`：容器直连 API 不通时填 `socks5://172.27.0.1:20170`

## 异步流水线

```
on_message
  └─ 概率 / 冷却 / 额度 / 每日上限 → request_material
       ├─ POST /api/reply  ──on_http_response(stage=reply)──► 有图 → 发送；无图 → /api/search
       └─ POST /api/search ──on_http_response(stage=search)─► 有图 → 发送
GET /api/session ──on_http_response(stage=session)──► 缓存额度 10 分钟
```

## 权限

`onebot11` `database` `cache` `http`

## 注意

- 素材版权归原出处，转发前请自行确认使用权（API 文档条款）。
- 表情包 ID 从群内引用 `stk://` 即可；留空则不发。
