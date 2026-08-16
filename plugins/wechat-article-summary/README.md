# wechat-article-summary 公众号文章总结插件

识别群聊/私聊中发送的微信公众号文章链接（`mp.weixin.qq.com/s/...` 短链与长链均支持），自动抓取文章正文，由主程序 LLM 按文章类型总结核心内容，一条消息可含多篇（合并为一次 LLM 调用、一条消息输出，每篇一段、段间空两行、各自附链接）。

## 文件结构

```
wechat-article-summary/
├── main.lua     插件主逻辑：链接解析 → 异步抓取 → 正文提取 → LLM 分类总结 → 发送
├── config.yaml  运行配置（Web 面板可改，改后即时生效）
├── pluggin.yaml 插件元数据（permissions: onebot11 / http / cache / llm）
└── README.md    本文档
```

## 触发方式

直接发送文章链接即触发（无需命令）：

```
https://mp.weixin.qq.com/s/-oL9KwQaOKgFPADxaPgFTQ
```

多篇合并：一条消息里多个链接，一起总结后一条消息输出。

## 总结分类（LLM 判定，同一提示词覆盖全部文章）

| 类别 | 总结要点 |
|---|---|
| 项目/模型/产品介绍 | 是什么、核心特性与功能、关键参数/数据、如何使用或获取、适用场景 |
| 新闻/资讯 | 时间、事件、涉及人物（含身份）、起因经过结果、影响 |
| 观点/评论 | 核心观点、论述过程（论据与论证逻辑）、对反方观点的回应、结论 |
| 教程/指南 | 教什么、前置要求、主要流程/步骤、关键注意事项 |
| 其他 | 核心内容 |

铁律：只总结正文明确内容，禁止编造时间/事件/人物/数据；简体中文；每篇独立判定类型。

## 输出格式

```
📰 标题
📖 公众号名（抓不到则不显示该行）
核心内容总结（50~150 字；早报/新闻汇总类为前 5 条新闻标题 + "共 X 条"）
🔗 原文链接
[封面图]（默认附在末尾，send_cover 可关）
```

（多篇时每段之间空两行，一次发送；封面图取第一篇抓取到封面的文章。）

## 抓取说明

微信公众号对非浏览器 User-Agent 有风控（返回"环境异常"验证页）。插件抓取时带浏览器 UA + Referer 请求头（依赖引擎 `http.get_async` 的 headers 扩展），正文从 `id="js_content"` 容器按 div 深度配对提取。风控/404/解析失败均有明确错误提示。

## 配置项

| key | 说明 | 默认 |
|---|---|---|
| enabled | 总开关 | true |
| enable_summary | LLM 总结开关（关闭只发标题与公众号名） | true |
| reply_quote | 回复时引用原消息 | true |
| send_cover | 发送封面图（og:image） | true |
| group_only | 仅群聊生效 | false |
| cache_ttl | 总结结果缓存秒数 | 604800（7 天） |
| max_content_chars | 送入 LLM 的正文最大字数 | 10000 |
| llm_timeout | LLM 超时秒数 | 60 |
| max_articles | 单条消息最多处理链接数 | 5 |
| summary_min_chars | LLM 总结的最少字数 | 50 |
| summary_max_chars | LLM 总结的最多字数 | 150 |
| ua | 抓取 User-Agent（勿改回非浏览器 UA） | Chrome 126 UA |

## 依赖

- 引擎 `http.get_async` 支持可选 headers 参数（Bot 侧新增，向后兼容）
- 主程序 LLM（`jn.llm.chat_async`）
- Redis 缓存（`jn.cache`，按文章链接去重 + 结果缓存）
