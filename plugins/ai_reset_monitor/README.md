# ai_reset_monitor

多平台 **AI 额度重置与官方服务状态监控**插件。直连官方 X（Twitter）时间线 RSS、官方状态页与高精度聚合核验源，借助 Bot 内置 LLM 做语义鉴真与去噪（过滤日常水帖与玩笑），支持 **4 档播报风格**与**分群订阅路由**。

> 纯后台面板（`config.yaml`）配置与控制，不注册额外聊天指令，不打扰群内日常对话。

---

## 覆盖产品与信源

### 1. 额度重置监控

| 订阅键 | 产品 | 一手官方 X 信源 / 核验源 |
|---|---|---|
| `codex` | Codex (OpenAI) | `@thsottiaux`、`@OpenAIDevs`、`whenreset.dev`、`whenaireset.com` |
| `antigravity` | Antigravity (Google) | `@_mohansolo`、`agyresets.com/api/v1/status`、`whenaireset.com` |
| `claude` | Claude / Claude Code | `@ClaudeDevs`、`@bcherny`、`@claudeai`、`@AnthropicAI`、`whenreset.dev`、`whenaireset.com` |
| `grok` | Grok (xAI) | `@grok`、`@elonmusk`、`whenreset.dev`、`whenaireset.com` |
| `grok_bot` | Grok Bot (xAI) | `@bot`（及提及 Grok Bot 的官方公告） |
| `glm` | GLM Coding Plan (智谱 / Z.ai) | `whenaireset.com`（支持在 `extra_rss_feeds` 接入自建 RSSHub `@Zai_org`） |
| `qoder` | Qoder | `@qoder_ai_ide`（及 `extra_rss_feeds`） |
| `kimi` | Kimi / Kimi Code | `whenaireset.com`（支持在 `extra_rss_feeds` 接入自建 RSSHub `@Kimi_Moonshot`） |
| `gemini_cli` | Gemini CLI (Google) | `whenaireset.com`（及 `extra_rss_feeds`） |
| `cursor` | Cursor | `whenaireset.com`（及 `extra_rss_feeds`） |

### 2. 官方故障状态监控（按官方阶段推进实时通知）

| 订阅键 | 服务 | 数据源与降级策略 |
|---|---|---|
| `openai_status` | OpenAI 服务状态 | `status.openai.com/feed.rss` |
| `claude_status` | Claude 服务状态 | `status.claude.com/history.rss` |
| `deepseek_status` | DeepSeek 服务状态 | 优先直探 `status.deepseek.com/history.rss` 与 `feed.rss`（带浏览器 UA）；不可达时自动降级采样 `entireweb.com/zh-cn/status/deepseek` |

---

## 配置说明（Web 管理后台）

### 分群订阅规则（`group_subscriptions`）

每行填写一条规则，格式：

```text
群号|订阅键|可选风格覆写
```

- **订阅键快捷别名**：
  - `all`：全部重置产品 + 全部故障状态
  - `reset_all`：全部 10 个 AI 额度重置产品
  - `status_all`：全部 3 个故障状态监控（OpenAI / Claude / DeepSeek）
  - 逗号分隔具体产品键：如 `codex,antigravity,claude,grok_bot,glm,deepseek_status`
- **风格覆写（可选，留空跟随全局 `summary_style`）**：
  - `objective`：纯客观结构化快报
  - `persona`：纯 Bot 人格口吻播报（读取当前激活的 Bot `personality` 设定）
  - `both`：上段客观快报 + 下段 Bot 人格吐槽提醒
  - `major_persona`：仅全员直接重置 / 发放重置卡 / 重大故障追加人格播报，其余发纯客观

配置示例：

```text
1007385018|all|both
123456789|codex,claude,antigravity|major_persona
987654321|reset_all,deepseek_status|objective
```

### 扩展自定义 RSS / RSSHub（`extra_rss_feeds`）

参考 `juya_briefing` 插件做法，可随时新增自定义 RSS / Atom 源（含自建 RSSHub），支持两种写法：

- `glm|http://172.17.0.1:1200/twitter/user/Zai_org`（固定绑定到 `glm`）
- `https://example.com/feed.xml`（由 LLM 自动判别归属产品）

### 常用开关与代理

- `poll_interval_minutes`：默认 `"60"`（每小时查一次），最小 `"1"`；设 `"0"` 可关闭自动轮询仅使用后台 CronJob。
- `cold_start_skip_history`：默认开启，首次上线或新增信源只建立已见基线，不刷屏推送历史旧消息。
- `quiet_hours`：夜间静默时段（北京时间 `HH:MM-HH:MM`，如 `01:00-07:30`）；静默期命中的消息暂存 PostgreSQL，静默结束后自动合并补发。
- `foreign_proxy` / `cn_proxy`：海外信源与国内/DeepSeek 状态源分离代理配置，海外走代理如 `socks5://172.27.0.1:20170`，国内源可留空直连。
- `text_provider_id` / `fallback_provider_id` / `llm_min_interval`：支持指定主力或备选文本模型（例如主模型遇到 `503 no_healthy_account` 时自动切换备选模型并用完还原），默认每条串行间隔 `1.5` 秒调用避免并发打满号池。
- `max_msg_chars`：默认 `"450"`，所有推送文本强制全中文翻译，并严格控制在 450 字以内。
- `manual_trigger` + `manual_replay_hours` + `test_group`：打开 `manual_trigger` 后将在 30 秒内触发测试；`manual_replay_hours=0` 发送各产品最新状态诊断汇总，填正数（如 `72`）则回放最近 N 小时命中事件并走 LLM 润色发送到测试群（不破坏正常去重记录）；验证完请关回。
