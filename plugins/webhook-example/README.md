# webhook-example

Webhook 示例插件

## 简介

- **作者**: JuanNiang
- **版本**: 1.0.0

## 功能

处理外部服务通过 HTTP 推送的 Webhook 请求，并将通知转发到指定的 QQ 群。支持多种 payload 格式：

- GitHub Webhook（push / pull_request / issues / ping）
- 通用告警 JSON：`{"message":"...", "group_id":123, "level":"warn"}`
- 钉钉 / 飞书文本：`{"msgtype":"text","text":{"content":"..."}}`

## 使用

1. 在 Web 面板开启 Webhook（默认 8091 端口）。
2. 外部服务 POST 到 `http://<host>:8091/`（路径不限）。
3. 插件自动识别 payload 格式并转发到指定 QQ 群。

## 命令

本插件无需手动指令，通过 Webhook 回调自动触发。

## 配置

在 Web 管理面板「Plugin 管理」的插件详情「配置」页可调整本插件的配置：

- `default_group`：当推送 payload 未指定 `group_id` 时，通知转发的默认群号

## 许可

本项目遵循 MIT 许可证。