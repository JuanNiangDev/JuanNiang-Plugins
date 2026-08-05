# Ping 插件 (ping)

Ping 插件示例，使用 jn SDK 注册 `/ping` 命令。

## 简介

- **作者**: JuanNiang
- **版本**: 1.1.0

## 功能

- 注册 `/ping` 命令，回复默认文本 `pong!`
- 演示 `jn.command.register` 与 `jn.onebot11.send_group_msg` / `send_private_msg` 标准用法
- 兼容旧 `on_message` 入口

## 命令

| 命令   | 说明                          |
| ------ | ----------------------------- |
| /ping  | 连通性测试，回复 pong         |

## 配置

在 Web 管理面板「Plugin 管理」的插件详情「配置」页可调整本插件的配置：

| 配置键     | 类型   | 说明                       |
| ---------- | ------ | -------------------------- |
| reply_text | string | /ping 命令的回复内容，默认 `pong!` |

## 许可

本项目遵循 MIT 许可证。