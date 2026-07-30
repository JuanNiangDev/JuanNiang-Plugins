# 插件开发指南

本文档面向**在 JuanNiang-Plugins 仓库中开发插件的 Agent**，涵盖插件规范、API 参考和最佳实践。

## 快速开始

### 1. 用脚手架创建

```bash
./hago init my-plugin
```

交互式输入作者和简介后，自动生成标准插件骨架：

```
plugins/my-plugin/
├── pluggin.yaml    # 元数据
├── main.lua        # 入口
└── jn.lua          # SDK (类型注解)
```

### 2. 编写代码

编辑 `main.lua`，实现插件逻辑。所有插件必须 `require("jn")` 引入 SDK。

### 3. 测试

将 `plugins/my-plugin/` 目录放入 JuanNiang-Neo 的 `data/pluggins/`，重启或通过 Web 面板上传。

### 4. 打包

```bash
./hago pack my-plugin
```

## pluggin.yaml 规范

每个插件目录下必须有 `pluggin.yaml`：

```yaml
name: "my-plugin"         # 必填：插件名（用于日志标识）
version: "1.0.0"          # 必填：语义化版本
author: "anonymous"       # 必填：作者名
description: "描述"        # 必填：一句话简介
entry: "main.lua"         # 可选：入口文件（默认 main.lua）
permissions:              # 必填：权限列表
  - onebot11
  - http
system: false             # 可选：系统插件（默认 false）
enabled: true             # 可选：启用状态（默认 true）
```

### 权限列表

| 权限 | 授予的 API |
|------|-----------|
| `onebot11` | `jn.onebot11.*` — 消息发送、群管理、用户信息 |
| `http` | `jn.http.get` / `jn.http.post` |
| `database` | `jn.database.*` — 数据库读写 |
| `cache` | `jn.cache.*` — Redis 缓存 |
| `t2i` | `jn.t2i.*` — 文生图 |
| `sandbox` | `jn.sandbox.*` — 代码沙箱 |
| `agent` | `jn.agent.*` — Agent 运行态操作 |
| `*` | 全部权限 |

## main.lua 规范

入口文件必须是一个合法的 Lua 脚本，使用 `jn` SDK。

### 事件回调

插件可选择实现以下全局函数来响应不同事件：

```lua
local jn = require("jn")

-- 消息事件
function on_message(event)
    -- event.post_type = "message"
    -- event.message_type = "private" | "group"
    -- event.user_id, event.group_id, event.raw_message
    -- event.message_id, event.sender: {user_id, nickname, sex, age, card}
    -- 返回 consumed, reply
    return false, nil
end

-- 通知事件（群成员变动、禁言、戳一戳等）
function on_notice(event)
    -- event.notice_type: group_increase / group_decrease / group_ban / notify 等
    -- event.sub_type: approve / invite / poke 等
    -- event.user_id, event.group_id, event.operator_id, event.target_id
end

-- 请求事件（加好友、加群邀请）
function on_request(event)
    -- event.request_type: friend | group
    -- event.comment, event.flag
    -- 可用 jn.onebot11.handle_friend_request(flag, approve, remark) 处理
end

-- Webhook 事件
function on_webhook(event)
    -- event.webhook.path, event.webhook.method, event.webhook.payload
    return false, nil
end

-- 定时任务事件（CronJob 触发）
function on_timer_call(event)
    -- event.payload: CronJob 配置的 JSON payload
end
```

### 命令注册

用 `jn.command.register` 注册命令（优先级高于 `on_message`）：

```lua
jn.command.register("hello", function(args, event)
    return true, "Hello, World!"
end, {
    description = "打招呼",
    usage = "/hello [name]"
})
```

- handler 签名：`function(args, event) → consumed, reply`
- `consumed=true` 表示命令已处理，不再走 Agent
- `reply` 非空时自动发送回复

### 消息发送

```lua
-- 异步发送（推荐，不阻塞）
jn.onebot11.send_group_msg(group_id, "hello")
jn.onebot11.send_private_msg(user_id, "hello")

-- 同步发送（需要确认结果时使用）
local ok, err = jn.onebot11.send_group_msg_sync(group_id, "hello")
if not ok then
    jn.log.error("发送失败: " .. err)
end
```

### 富文本消息段

```lua
jn.onebot11.send_group_msg(group_id, {
    { type = "text",  data = { text = "Hello " } },
    { type = "at",    data = { qq = "123456" } },
    { type = "text",  data = { text = " 看图：" } },
    { type = "image", data = { file = "img/cat.png" } },  -- 相对路径自动转 base64
    { type = "image", data = { file = "https://..." } },  -- URL 直接透传
    { type = "image", data = { file = "base64://..." } }, -- Base64 直接透传
    { type = "face",  data = { id = "66" } },             -- CQ 表情
})
```

图片 `file` 字段支持三种来源：
- **URL**：`"http://..."` 或 `"https://..."`
- **Base64**：`"base64://..."`
- **相对路径**：`"img/photo.png"` 从插件目录自动读取并转换为 base64

### 日志

```lua
jn.log.info("操作成功")
jn.log.warn("警告信息")
jn.log.error("错误信息")
```

日志自动带 `[plugin:<name>]` 前缀，在 Web 面板"日志"页可见。

### 其他 OneBot11 API

```lua
jn.onebot11.delete_msg(message_id)
jn.onebot11.get_group_info(group_id)
jn.onebot11.get_group_member_list(group_id)
jn.onebot11.kick_group_member(group_id, user_id)
jn.onebot11.ban_group_member(group_id, user_id, duration_seconds)
jn.onebot11.set_group_card(group_id, user_id, "新名片")
jn.onebot11.handle_friend_request(flag, approve, remark)
jn.onebot11.handle_group_request(flag, sub_type, approve, reason)
jn.onebot11.read_file_base64("img/photo.png")  -- 手动读文件转 base64
```

## 插件素材

### Logo

在插件目录下放置 `logo.png`、`logo.jpg` 或 `icon.png`（优先级递减），`hago scan` 会自动识别并写入元数据。

### 图片资源

插件目录下的图片文件可在消息段中通过相对路径引用：

```lua
{ type = "image", data = { file = "assets/banner.png" } }
```

## 最佳实践

1. **权限最小化**：只声明插件实际需要的权限
2. **异步优先**：默认用 `send_xxx_msg`（异步），只在需要结果时用 `send_xxx_msg_sync`
3. **命令优先于 on_message**：用 `jn.command.register` 处理结构化交互，`on_message` 用于自由文本监听
4. **日志清晰**：关键操作打日志，方便排查
5. **不阻塞事件循环**：耗时操作（HTTP 请求等）应在回调内尽快返回
6. **SDK 版本**：`jn.lua` 应与目标 JuanNiang-Neo 版本匹配

## 完整示例

参考本仓库已有插件：
- `welcome/` — on_notice + at 消息段
- `rich-demo/` — 富文本命令 + 图片自动转换
- `poke-reply/` — on_notice (poke) + 随机回复
- `cron-example/` — on_timer_call + Payload 参数

完整 JuanNiang-Neo 插件文档见 [plugin-development.md](https://github.com/JuanNiangDev/JuanNiang-Neo/blob/main/docs/plugin-development.md)。
