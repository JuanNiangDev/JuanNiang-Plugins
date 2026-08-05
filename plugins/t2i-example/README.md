# T2I 文生图示例插件 (t2i-example)

T2I 文生图示例插件，通过 HTML 生成图片。

## 简介

- **作者**: JuanNiang
- **版本**: 1.0.0

## 功能

- `/t2i <html>` 生成图片并返回 URL
- `/t2i_url <html>` 生成图片并直接发送到会话
- `/t2i_state` 查看 T2I 服务状态

## 命令

| 命令       | 说明                               |
| ---------- | ---------------------------------- |
| /t2i       | 生成图片（T2I），返回 URL          |
| /t2i_url   | 生成图片并直接发送到群里           |
| /t2i_state | 查看 T2I 服务状态                  |

## HTML 示例

```
/t2i <div style="background:red;color:white;padding:20px;font-size:32px">Hello World</div>
```

## 配置

在 Web 管理面板「Plugin 管理」的插件详情「配置」页可调整本插件的配置：

| 配置键         | 类型   | 说明                                   |
| -------------- | ------ | -------------------------------------- |
| success_prefix | string | /t2i 生成成功时回复内容的前缀          |

## 许可

本项目遵循 MIT 许可证。