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

## 卡片字体

卡片模板 `templates/card-5.html` 内嵌了 **Maple Mono Normal NF CN** 的 woff2 子集（base64 data URI，约 964KB）。因为 T2I 渲染服务只收到 HTML 文本、没有文件上传通道，字体必须打进模板里才能正常显示中文。

- 字符集：ASCII + Latin-1 + 常用标点/符号 + **GB2312 一级汉字（3755 个）**
- 子集字体的 family 名保持 `Maple Mono Normal NF CN` 不变，与模板 CSS 声明一致
- 原始字体、子集文件与字符集见 `fonts/` 目录（`card-best.woff2`、`charset.txt`）

重新生成（需要 fonttools + brotli）：

```bash
python3 -m venv /tmp/fontenv
/tmp/fontenv/bin/pip install fonttools brotli

# 在插件目录执行
PYFTSUBSET=/tmp/fontenv/bin/pyftsubset ./fonts/rebuild.sh
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
| `card_template` | string | `5` | 卡片模板编号（当前仅有 5；`random` 每次随机选一个） |
| `card_width` | string | `900` | 卡片渲染宽度像素（模板 900×450） |
| `card_height` | string | `450` | 卡片渲染高度像素（模板 900×450） |
| `github_token` | string | 空 | GitHub Personal Access Token：限流 60→5000 次/小时并可访问私有仓库；留空走匿名免费层级 |

## 权限

`onebot11` / `http` / `cache` / `llm` / `file`（卡片模板读取） / `t2i`（卡片渲染）

## 许可

MIT
