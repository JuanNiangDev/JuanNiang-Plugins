<!-- Author: Churnie HXCN -->
# juya_briefing 橘鸦 AI 早报自动推送

每日定时抓取 [橘鸦 AI 早报](https://daily.juya.uk/) 当期内容，合并转发到指定群。

## 数据源

站点每天一期：RSS 只有「一期」入口（标题是日期，链到 `/issues/<date>/`），正文页才是新闻列表。

```
https://daily.juya.uk/rss.xml              # 期号入口
https://daily.juya.uk/issues/{date}/       # 当期正文（{date} 自动替换为当天）
```

- 当期页面抓取失败 / 尚未出刊 → 回退 RSS 最新一期；若那一期的日期不是今天，则**跳过不补发**（按需求约定）。
- 同一期只发一次（`jn.cache` 记录 issue 日期，7 天过期）。

## 消息结构

一条合并转发：

```
AI 早报 2026-11-18
🎬 哔哩哔哩：https://www.bilibili.com/video/BV…     ← 期号 + 视频链接
📋 概览
【要闻】
#1 OpenAI 发布 GPT-6.2 Astra 与 Sol，分别面向复杂任务和日常工作
#2 微软在 Ignite 上公布七款新模型
…
#1 【要闻】OpenAI 发布 GPT-6.2 Astra 与 Sol…
<摘要原文，完整展示，不截断>
https://openai.com/index/introducing-gpt-6-2-astra-sol/
https://mp.weixin.qq.com/s/xxxx           ← 同一事件的多家来源都会列出
[配图] ← 该条新闻的正文配图全部跟在这个节点里，位于链接之后
```

- 分类标题一个节点，每条新闻一个节点。
- 单期条数上限默认 70（`max_items`）。
- `forward=false` 时降级为逐条纯文本发送。

## 配置

| 配置项 | 说明 |
|---|---|
| `enabled` | 总开关 |
| `target_groups` | 推送目标群号列表（可多个，逐群发送；private 取第一项） |
| `send_time` | 每日发送时间，默认 `11:30` |
| `feeds` | 数据源列表（RSS + 期号模板） |
| `max_items` | 单期最多推送条数，默认 70 |
| `links_max` | 每条新闻最多列几个来源链接，默认 6 |
| `node_nickname` | 合并转发卡片里的昵称 |
| `forward` | 是否使用合并转发 |
| `manual_trigger` | 立即触发一次（忽略时间与去重） |

## 权限

`onebot11` `http` `timer` `cache` `config`
