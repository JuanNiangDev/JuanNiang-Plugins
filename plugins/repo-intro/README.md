# 仓库介绍插件 (repo-intro)

发送 **GitHub / Hugging Face / ModelScope** 仓库链接时，自动引用原消息并发布仓库介绍到群聊（私聊同样生效）：

- **一条消息可含多个链接**：逐个拉取元数据与 README，合并为**一次** LLM 调用（GitHub / HF / ModelScope 同一提示词），由 LLM 判定每个仓库的类型并总结
- **一条消息输出**：每个仓库一段、各自附上链接，段与段之间空两行
- **类型由 LLM 判定**：AI Agent 项目 / MCP·Skills·插件 / 数据集 / 文本模型 / 图像生成 / 视频生成 / 语音 / 多模态 / 嵌入 / 重排序 / OCR / 机器人模型 / 其他
- **附带文本**：消息中除链接外的说明文字（如推文、推荐语）也会一并交给 LLM 作为仓库补充信息——例如分享者给的安装命令、一句话定位；与仓库无关的闲聊/晒 Star/祝贺等噪声由 LLM 自动忽略，绝不输出
- **反空话套话**：禁止输出"推测与 XX 相关""具体内容需查阅仓库文档""未提供详细文档"等元信息旁白；README 极简或没内容时如实写短或留空，只输出仓库给出的信息
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

### 附带文本示例

分享者带链接一起发的说明文字（推文/推荐语）会作为仓库补充信息参与总结：

```text
这个设计 skill 很棒：scandinavian-design，北欧极简风格，黑白中性色基础，
有点像 IKEA 那种少即是多的感觉。npx skills add ericzakariasson/scandinavian-design 试试看
https://github.com/ericzakariasson/scandinavian-design
```

即使该仓库 README 只有一句话，总结也会结合附带文本给出定位与安装命令。若附带文本是"卧槽一觉醒来干到 Trending 第一"这类与仓库内容无关的噪声，则被 LLM 忽略，只按 README 总结。

## 工作流程

```text
检测到链接（可多个）→ 未命中缓存者逐仓库拉取元数据+README → 合并一次 LLM 调用 → 逐仓库缓存 → 组装一条消息发送
```

- 全程异步（`http.get_async` / `llm.chat_async` + 引擎异步回调），不阻塞事件循环。
- **每个仓库的总结独立缓存**（Redis，默认 7 天）：再遇到同仓库直接复用，跳过 HTTP 与 LLM；同一仓库 60 秒内在途去重，避免并发重复。
- 机器人自己的消息不处理，防止自触发循环。
- 单条消息最多处理 `max_repos` 个链接（默认 5）。

## HF / ModelScope 模型卡片

HF/MS 仓库渲染 `templates/card-6.html`（GitHub 仍用 card-5）。模型卡展示：标题 + 仓库名、HF/MS 组织头像、**参数量 + 上下文（一行）**、**输入类型（文本/图片/音频/视频/PDF 图标，一行）**、**价格块**；去掉了 GitHub 水印图标与模型简介。

- 参数量优先取 HF 元数据 `safetensors.total`（ModelScope 无该字段），模型库兜底，未知显示"闭源"
- 价格按币种：国产模型（含 CNY 档）用 ¥，国外用 $；展示输入/输出、思考（不同于输出价时）、缓存、闲时档（off_peak）、不同上下文分段（tokenTier）
- 头像：MS 直连 `resouces.modelscope.cn`；HF 走 `wsrv.nl` 图片代理（T2I 渲染器网络无法直连 huggingface CDN，失败时灰圆占位）

### 模型信息收集链路（data/）

模型库 `data/modeldb.json` 由 `data/rebuild-modeldb.py` 从 **4 个来源全部参与**生成：

| 来源 | 贡献 |
|------|------|
| [llmrates.ai](https://www.llmrates.ai/zh-Hans/models) | 上下文/输入模态/provider（国产判定）+ 完整定价：CNY+USD、标准/闲时、上下文分段、思考/缓存 |
| [models.dev](https://models.dev/api.json) | 兜底：上下文/模态/USD 价格 |
| [newapiratio.com](https://newapiratio.com/api.json) | 交叉校验/兜底（与 models.dev 同族） |
| [openrouter](https://openrouter.ai/api/v1/models) | `hugging_face_id` 映射 + 描述里的参数量 |

按共享别名 union-find 归并同一模型的多来源数据（含 `modeldb.json` 的 `alias` 反向索引，按 HF id 渐进查找）。刷新：

```bash
# 在插件目录执行（联网拉取 4 源，需 python3）
python3 data/rebuild-modeldb.py
```

## 数据来源

| 平台 | 元数据 API | README |
|------|-----------|--------|
| GitHub | `api.github.com/repos/{owner}/{repo}` | 仓库 `readme` API 返回的 base64 `content` 直接解码（与元数据同源、国内可达）；content 缺失时回退 `download_url`（raw.githubusercontent.com） |
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
| `use_context_text` | bool | `true` | 附带文本参与总结：消息中除链接外的说明文字（推文/推荐语）一并交给 LLM；噪声由 LLM 自动忽略 |
| `reply_quote` | bool | `true` | 回复时引用原消息 |
| `group_only` | bool | `false` | 仅群聊生效（开启后私聊忽略） |
| `cache_ttl` | string | `604800` | 单仓库总结结果缓存秒数（7 天） |
| `max_readme_chars` | string | `10000` | 送入 LLM 的 README 最大字符数 |
| `llm_timeout` | string | `60` | 主程序 LLM 调用超时（秒） |
| `max_repos` | string | `5` | 单条消息最多处理的链接数 |
| `summary_min_chars` | string | `50` | LLM 总结的目标字数（内容稀少时可如实写短或留空） |
| `summary_max_chars` | string | `150` | LLM 总结的最多字数 |
| `card_enabled` | bool | `true` | 发送仓库卡片图（走主程序 T2I 服务渲染 HTML 模板） |
| `card_template` | string | `5` | 卡片模板编号（仅用于 GitHub 卡片；`random` 在 1~5 间随机选一个；HF/MS 模型卡固定用 card-6） |
| `card_width` | string | `900` | 卡片渲染宽度像素（模板 900×450） |
| `card_height` | string | `450` | 卡片渲染高度像素（模板 900×450） |
| `github_token` | string | 空 | GitHub Personal Access Token：限流 60→5000 次/小时并可访问私有仓库；留空走匿名免费层级 |

## 权限

`onebot11` / `http` / `cache` / `llm` / `file`（卡片模板读取） / `t2i`（卡片渲染）

## 许可

MIT
