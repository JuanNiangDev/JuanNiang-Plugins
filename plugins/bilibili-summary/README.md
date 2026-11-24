# bilibili-summary 哔哩哔哩内容总结插件

识别群聊/私聊里的 B 站内容并自动总结，支持：

- 视频长链 `https://www.bilibili.com/video/BV.../?p=2`
- 短链 `https://b23.tv/xxxxxxx`（302 到视频 / 专栏 / 动态）
- QQ 小程序卡片（`meta.detail_1.qqdocurl` 里的 b23 链接）
- 专栏 `https://www.bilibili.com/opus/<id>`、旧版 `read/cv<id>`

## 输出格式

视频：

```
📺 视频标题
👤 UP 主 | 🕒 2026-11-18 18:04 | ▶️ 16.4万
🔗 https://www.bilibili.com/video/BV...
📝 简介（≤300 字）
🎬 共 6 P：1.标题｜2.标题｜…
🧠 内容总结
单 P：字幕总结（≤300 字）；多 P：前 N P 字幕合并成一段整体总结
persona 模式下这一段改为人设口吻讲解内容（默认 ≤600 字）
[封面图]
```

- 单 P 且拿不到字幕：不写「内容总结」段，只保留元信息与简介。
- 多 P 且拿不到字幕：由模型概括分 P 标题。
- 字幕无实质内容（纯噪音/无信息量）：模型返回 `no_content`，省略总结段；**歌词/MV 会总结歌词大意、主题与情绪**，不会因为“无人声台词”跳过。
- 带 `?p=N` 的链接只总结第 N P，不发全部分 P 列表。

专栏：

```
📄 标题（没有则不显示）
👤 作者
🔗 链接
🧠 内容总结（原文很短时原样返回）
🎬 引用视频：标题 + 链接（图文里引用了视频时，附带该视频封面）
[配图，最多 max_images 张；纯文字动态没有配图就不发图]
```

## 字幕与 Cookie

字幕接口 `x/player/wbi/v2?aid=&cid=` 需要登录态：`cookie` 填浏览器里 bilibili.com 的 Cookie（至少 `SESSDATA`）。插件会补 `Origin` / `Sec-Fetch-Site: same-origin`，并自动从 `x/frontend/finger/spi` 取 `buvid3`/`buvid4`（缓存 7 天，失败则跳过）。留空时视频只能按标题/简介总结，多 P 视频退化为分 P 标题概括。

字幕选择：优先非 AI 字幕（`lan` 不以 `ai` 开头），否则取 AI 字幕。字幕文本默认每 P 最多送 50000 字给模型。

> B 站字幕接口偶发返回**其它视频的字幕**（同一 cid 多次请求结果不同）。插件会用标题/分P标题做相关度校验，不符时重取最多 5 次；仍不符则标注给模型判断（歌词保留总结），避免把别人的字幕总结成本视频。封面、专栏配图统一 `https://`。

## 抓取说明

- 视频信息：`api.bilibili.com/x/web-interface/view`（免登录）
- 字幕列表：`api.bilibili.com/x/player/wbi/v2?aid=&cid=` → `subtitle_url`（带 Cookie + 同源请求头；字幕 JSON 本身直连，不携带 Cookie）
- 专栏：桌面页 `__INITIAL_STATE__` 的 `detail.modules`（标题/作者/时间/段落/正文图片/头图相册/视频卡片）
- 短链：经本地 `media-proxy` 的 `/b23?code=` 只取 Location，不跟随跳转到 B 站网页，避免 412
- 图片统一 `http→https`，可选 `image_proxy_prefix` 走图片代理

## 配置要点

| 键 | 说明 |
|---|---|
| `summary_style` | `objective` 客观总结 / `persona` 用 Bot 人设口吻把内容完整讲一遍（自动读取启用中的人设提示词） |
| `link_style` | `0` 完整链接；`1` 视频显示 BV 号、专栏显示规范 opus 链接（不用 b23） |
| `max_pages` | 多 P 最多总结前几个 P 的字幕，默认 5 |
| `max_subtitle_chars` | 单 P 字幕送入 LLM 的字数上限，默认 50000 |
| `max_images` | 专栏配图上限，默认 9 |
| `target_groups` | 留空 = 全部群/私聊；填写后只处理这些群 |
| `merge_forward` | 是否开启合并转发投递（默认 `true`） |
| `merge_threshold` | 同条消息达到至少几条结果时合并转发（默认 `"1"`，即单条也合并转发；设为 `"2"`/`"3"` 则达到阈值才合并） |
| `forward_sender_name` | 合并转发内节点昵称（留空用机器人自身昵称） |
| `cookie` | 字幕登录 Cookie，默认空；可再填 `buvid3` / `buvid4` 手动覆盖自动获取值 |

## 其它

- 标题行尾带零宽水印，转发本机输出不会二次总结。
- 结果缓存 7 天（`cache_ttl`），同一内容重复发送直接复用。
- 同一会话的多个链接串行处理，避免并发打爆接口。
