-- ====================================================================
-- T2I 文生图示例插件
-- ====================================================================
-- 用法:
--   /t2i <html>     → 生成图片，返回 URL
--   /t2i_url <html> → 同上，并把图片发到群里
--   /t2i_state      → 查看 T2I 服务状态
--
-- HTML 示例:
--   /t2i <div style="background:red;color:white;padding:20px;font-size:32px">Hello World</div>
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- /t2i —— 生成图片并打印 URL 到日志
-- ====================================================================
jn.command.register("t2i", function(args, event)
    if not jn.t2i.is_active() then
        jn.log.error("[t2i-example] T2I 服务未启用")
        reply(event, "T2I 服务未启用，请先开启～")
        return true
    end

    if #args == 0 then
        reply(event, [[用法: /t2i <HTML>
示例: /t2i <div style="font-size:24px;color:blue">Hello World</div>]])
        return true
    end

    -- args 是空格分隔的数组，原样拼接为 HTML
    local html = table.concat(args, " ")

    jn.log.info("[t2i-example] 正在生成图片...")

    local url, err = jn.t2i.generate_url(html)
    if not url then
        jn.log.error("[t2i-example] 生成失败: " .. (err or "unknown"))
        reply(event, "生成图片失败: " .. (err or "unknown"))
        return true
    end

    jn.log.info("[t2i-example] 图片 URL: " .. url)
    reply(event, "✅ 图片生成成功\nURL: " .. url)
    return true
end, {
    description = "生成图片（T2I），返回 URL",
    usage = "/t2i <HTML>",
})

-- ====================================================================
-- /t2i_url —— 生成图片并发送到群
-- ====================================================================
jn.command.register("t2i_url", function(args, event)
    if not jn.t2i.is_active() then
        reply(event, "T2I 服务未启用～")
        return true
    end

    if #args == 0 then
        reply(event, "用法: /t2i_url <HTML>")
        return true
    end

    local html = table.concat(args, " ")

    local url, err = jn.t2i.generate_url(html)
    if not url then
        reply(event, "生成失败: " .. (err or "unknown"))
        return true
    end

    jn.log.info("[t2i-example] 图片 URL: " .. url)

    -- 用图片 URL 发到群里
    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, {
            { type = "image", data = { file = url } },
        })
    else
        jn.onebot11.send_private_msg(event.user_id, {
            { type = "image", data = { file = url } },
        })
    end
    return true
end, {
    description = "生成图片并直接发送",
    usage = "/t2i_url <HTML>",
})

-- ====================================================================
-- /t2i_state —— 查看 T2I 服务状态
-- ====================================================================
jn.command.register("t2i_state", function(args, event)
    local active = jn.t2i.is_active()
    local config, err = jn.t2i.get_config()
    local info = "T2I 状态: " .. (active and "✅ 已启用" or "❌ 未启用")
    if config then
        info = info .. "\n配置: " .. jn.json.encode(config)
    end
    reply(event, info)
    jn.log.info("[t2i-example] " .. info)
    return true
end, {
    description = "查看 T2I 服务状态",
    usage = "/t2i_state",
})

-- ====================================================================
-- 辅助函数
-- ====================================================================
function reply(event, text)
    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, text)
    else
        jn.onebot11.send_private_msg(event.user_id, text)
    end
end

function on_message(event)
    return false, nil
end

jn.log.info("[t2i-example] T2I 文生图插件已加载")
