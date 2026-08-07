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

-- 异步回调回复目标（不持有 event，用调用现场 ctx）
local function target_of(event)
    if event.message_type == "group" then
        return { kind = "group", id = event.group_id }
    end
    return { kind = "private", id = event.user_id }
end

local function reply_to(ctx, text)
    if not ctx or not ctx.target then return end
    if ctx.target.kind == "group" then
        jn.onebot11.send_group_msg(ctx.target.id, text)
    else
        jn.onebot11.send_private_msg(ctx.target.id, text)
    end
end

-- ====================================================================
-- /t2i —— 生成图片并返回 URL（异步，不阻塞事件循环）
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

    local ctx = { action = "url", target = target_of(event) }
    local rid = jn.t2i.generate_url_async(html, nil, ctx)
    if rid == 0 then
        reply(event, "生成提交失败，请确认 T2I 服务已启用～")
    end
    return true
end, {
    description = "生成图片（T2I，异步），返回 URL",
    usage = "/t2i <HTML>",
})

-- ====================================================================
-- /t2i_url —— 生成图片并发送到群（异步）
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
    local ctx = { action = "send", target = target_of(event) }
    local rid = jn.t2i.generate_url_async(html, nil, ctx)
    if rid == 0 then
        reply(event, "生成提交失败，请确认 T2I 服务已启用～")
    end
    return true
end, {
    description = "生成图片并直接发送（异步）",
    usage = "/t2i_url <HTML>",
})

-- ====================================================================
-- 异步完成回调：on_t2i_response(req_id, ctx, result, err)
--   result = 图片 URL；err 非 nil 表示失败
-- ====================================================================
function on_t2i_response(req_id, ctx, result, err)
    if not ctx or not ctx.target then return end
    if err then
        reply_to(ctx, "生成图片失败: " .. tostring(err))
        return
    end
    jn.log.info("[t2i-example] 图片 URL: " .. result)
    if ctx.action == "url" then
        reply_to(ctx, (jn.config.get("success_prefix") or "✅ 图片生成成功\nURL: ") .. result)
    elseif ctx.action == "send" then
        local msg = { { type = "image", data = { file = result } } }
        if ctx.target.kind == "group" then
            jn.onebot11.send_group_msg(ctx.target.id, msg)
        else
            jn.onebot11.send_private_msg(ctx.target.id, msg)
        end
    end
end

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
