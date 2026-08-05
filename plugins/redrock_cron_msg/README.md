# redrock_cron_msg

定时发送消息到指定群

## 简介

- **作者**: Redrock
- **版本**: 1.0.0

通过 CronJob 定时任务，在指定时间向指定群批量发送消息。目标群号与消息内容由定时任务的 payload 提供，插件本身无需配置。

## 功能

- 支持向多个群批量发送同一消息
- 由 CronJob 的 payload 驱动，灵活配置发送时间

## 命令

本插件无聊天命令，由 `on_timer_call` 定时触发。

### CronJob Payload 示例

```json
{
  "groups": [123456, 789012],
  "message": "今天晚上12点卷娘可要清理掉不按规矩改名的同学了哦！"
}
```

## 配置

本插件无可配置项（`configs: []`），目标群号与消息内容均来自 CronJob 的 payload。

## 许可

本项目遵循 MIT 许可证。