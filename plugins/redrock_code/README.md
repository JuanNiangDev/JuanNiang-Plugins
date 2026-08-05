# redrock_code

基于 Judge0 的在线代码运行插件

## 简介

- **作者**: Redrock
- **版本**: 1.0.0

在群聊中直接运行代码的插件，基于 Judge0 在线评测服务，支持 40+ 种编程语言，返回运行结果、耗时与内存占用。

## 功能

- 支持 Python、C、C++、Java、JavaScript、Go、Rust、Lua 等 40+ 种语言
- 支持传入标准输入
- 返回运行输出、耗时与内存占用
- 自动截断过长的输出
- 仅限群聊使用

## 命令

| 命令 | 说明 |
| ---- | ---- |
| /code <语言> [输入...] | 运行指定语言代码，换行后写代码内容 |

示例：

```
/code py
print("hello, world")
```

## 配置

在 Web 管理面板「Plugin 管理」的插件详情「配置」页可调整本插件的配置。

| 配置项 | 类型 | 说明 | 默认值 |
| ---- | ---- | ---- | ---- |
| judge0_base_url | string | Judge0 服务地址 | https://ce.judge0.com |
| max_output_len | string | 输出最大长度 | 1500 |

## 许可

本项目遵循 MIT 许可证。