# 仓库介绍插件 (repo-intro)

发送 **GitHub / Hugging Face / ModelScope** 仓库链接时，自动引用原消息并发布仓库介绍到群聊（私聊同样生效）：

- **一条消息可含多个链接**：逐个拉取元数据与 README，合并为**一次** LLM 调用（GitHub / HF / ModelScope 同一提示词），由 LLM 判定每个仓库的类型并总结
- **一条消息输出**：每个仓库一段、各自附上链接，段与段之间空两行
- **类型由 LLM 判定**：AI Agent 项目 / MCP·Skills·插件 / 数据集 / 文本模型 / 图像生成 / 视频生成 / 语音 / 多模态 / 嵌入 / 重排序 / OCR / 机器人模型 / 其他
- MCP / Skills / 插件类：总结时**给出安装方式**（`npx`/`npm`/`uvx`/`pip`/`brew` 或配置文件路径）
- 模型类：按类型提取关键信息（文本模型含总参数/激活参数（MoE）、精度、上下文长度、多模态支持、专长基准；图像/视频/语音/嵌入/OCR/机器人等各有侧重）
- README 缺失则不输出摘要段；LLM 不可用自动降级为仓库名 + 原文简介
- 复用主程序 LLM（`jn.llm.chat_async`），全程异步不阻塞事件循环

## 触发示例

```text
https://github.com/JuanNiangDev/JuanNiang-Neo
https://huggingface.co/Qwen/Qwen2.5-7B
https://modelscope.cn/models/Qwen/Qwen2.5-7B
https://modelscope.cn/datasets/modelscope/chinese-poetry-collection
```

一条消息带两个链接时，输出示例（段间空两行）：

```text
📦 tavily-ai/tavily-mcp · GitHub
🏷 MCP 服务器
Tavily 搜索与网页抓取能力的 MCP 服务器，可接入 Claude 等 Agent。
⚙️ 安装：npx -y tavily-mcp
🔗 https://github.com/tavily-ai/tavily-mcp


📦 Qwen/Qwen2.5-7B · Hugging Face · 模型
🏷 文本对话模型
Qwen2.5 系列 7B 模型，Dense 架构，支持 128K 上下文，文本生成。
🔗 https://huggingface.co/Qwen/Qwen2.5-7B
```

> 支持 `www.` 前缀与 `modelscope.ai` 域名；自动忽略 `api.github.com` 等子域、HF `collections` 页面与命令消息（`/` 开头）。

## 工作流程

```
检测到链接（可多个）→ 未命中缓存者逐仓库拉取元数据+README → 合并一次 LLM 调用 → 逐仓库缓存 → 组装一条消息发送
```

- 全程异步（`http.get_async` / `llm.chat_async` + 引擎异步回调），不阻塞事件循环。
- **每个仓库的总结独立缓存**（Redis，默认 7 天）：再遇到同仓库直接复用，跳过 HTTP 与 LLM；同一仓库 60 秒内在途去重，避免并发重复。
- 机器人自己的消息不处理，防止自触发循环。
- 单条消息最多处理 `max_repos` 个链接（默认 5）。

## 数据来源

| 平台 | 元数据 API | README |
|------|-----------|--------|
| GitHub | `api.github.com/repos/{owner}/{repo}` | 仓库 `readme` API → `download_url` |
| Hugging Face | `huggingface.co/api/{models\|datasets\|spaces}/{id}` | `/raw/main/README.md`（404 回退 `master`） |
| ModelScope | `modelscope.cn/api/v1/{models\|datasets}/{id}` | 数据集内嵌 `ReadmeContent`；模型走 `repo?FilePath=README.md` |

## 配置项

| key | 类型 | 默认 | 说明 |
|-----|------|------|------|
| `enable_github` | bool | `true` | 启用 GitHub 仓库介绍 |
| `enable_huggingface` | bool | `true` | 启用 Hugging Face 介绍 |
| `enable_modelscope` | bool | `true` | 启用 ModelScope 介绍 |
| `hf_mirror` | bool | `true` | Hugging Face 请求走 hf-mirror.com 镜像（国内直连常不通） |
| `enable_summary` | bool | `true` | 用主程序 LLM 判定类型并总结 |
| `reply_quote` | bool | `true` | 回复时引用原消息 |
| `group_only` | bool | `false` | 仅群聊生效（开启后私聊忽略） |
| `cache_ttl` | string | `604800` | 单仓库总结结果缓存秒数（7 天） |
| `max_readme_chars` | string | `10000` | 送入 LLM 的 README 最大字符数 |
| `llm_timeout` | string | `60` | 主程序 LLM 调用超时（秒） |
| `max_repos` | string | `5` | 单条消息最多处理的链接数 |
| `summary_min_chars` | string | `50` | LLM 总结的最少字数 |
| `summary_max_chars` | string | `150` | LLM 总结的最多字数 |

## 权限

`onebot11` / `http` / `cache` / `llm`

## 许可

MIT
