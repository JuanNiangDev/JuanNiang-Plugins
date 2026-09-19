# MeT_Music 点歌

基于 [MeT Music](https://music.met6.top:444/app/) 的点歌插件：搜索歌曲渲染成结果图，按编号播放为 QQ 音乐卡片。

## 命令

| 命令 | 说明 |
|------|------|
| `/music search <关键词> [数量]` | 搜索歌曲，默认 5 首，结果渲染成图片（含编号/封面/名称/歌手/专辑/时长/免费标识） |
| `/music play <编号>` | 播放最近一次搜索结果中的对应歌曲，以语音形式发送 |
| `/music` | 查看命令说明与 MeT Music 项目支持方式 |

搜索结果缓存 10 分钟（按群+用户隔离），期间可多次 `/music play`。

## 配置项

| key | 类型 | 说明 |
| --- | --- | --- |
| `base_url` | string | MeT Music API 根地址，默认 `https://music.met6.top:444` |

## 说明

- 播放为 OneBot11 `record` 语音段：`file` 直接使用 MeT Music 取流直链（302 跳转到实际音频），由 OneBot 实现端下载并自动转码为语音；发送失败时降级为文本直链。
- `fee=1` 的歌曲为付费内容，取流直链可能只有试听片段，结果图中会以 `VIP` 标识。
- 结果图由 T2I 渲染：封面以原始 URL 交给渲染环境下载（参照 repo-intro 的做法，常见 CDN 可直连），个别加载失败的封面显示为占位底色。

## 支持 MeT Music

- 网站：https://music.met6.top:444/app/
- 仓库：https://github.com/MeTerminator/MeT-Music_App / https://github.com/MeTerminator/MeT-Music_Player
