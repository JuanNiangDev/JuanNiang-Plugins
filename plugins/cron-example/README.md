# Cron 示例插件 (cron-example)

示例插件：通过 CronJob 定时触发，向 Payload 中指定的 QQ 号发送消息。

## 简介

- **作者**: JuanNiang
- **版本**: 1.0.0

## 功能

- 通过 CronJob 定时任务触发 `on_timer_call(event)`
- 根据 Payload 中的 `message_type` 向私聊 QQ 或群发送定时消息
- 支持 Payload 字段：`target_qq`、`message`、`message_type`、`group_id`

## Payload 示例

```json
{
  "target_qq": 123456789,
  "message": "⏰ 定时提醒：该喝水啦！",
  "message_type": "private"
}
```

## 配置

在 Web 管理面板「Plugin 管理」的插件详情「配置」页可调整本插件的配置：

| 配置键          | 类型   | 说明                                           |
| --------------- | ------ | ---------------------------------------------- |
| default_message | string | Payload 未提供 message 时发送的兜底消息，默认空 |

## 许可

本项目遵循 MIT 许可证。