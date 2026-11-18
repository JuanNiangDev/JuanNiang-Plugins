-- ============================================================================
-- juya_briefing: 橘鸦 AI 早报自动推送
-- ----------------------------------------------------------------------------
-- 每日 send_time（默认 11:30）抓取 daily.juya.uk 当期页面：
--   · 当天页面没出刊 → 跳过，不补发（配置项 forward_time 语义用户已确认）
--   · 同一期只发一次（jn.cache 记 issue 日期）
--   · 消息结构：每个分类一个标题节点 + 每条新闻一个节点
--     （节点内容 = 标题 + 摘要 + 全部来源链接），整期做成一条合并转发
-- 数据解析见 juya.lua（由 load_juya 注入 jn）
-- ============================================================================

local jn = require("jn")
-- 引擎没有给插件目录挂 package.path，共享模块用 jn.file.read + loadstring 载入
local function load_juya()
    local src, err = jn.file.read("juya.lua")
    if not src then return nil, "juya.lua 读取失败: " .. tostring(err) end
    local chunk, lerr = loadstring(src, "juya.lua")
    if not chunk then return nil, "juya.lua 语法错误: " .. tostring(lerr) end
    local ok, factory = pcall(chunk)
    if not ok or type(factory) ~= "function" then return nil, "juya.lua 初始化失败" end
    local ok2, mod = pcall(factory, jn)
    if not ok2 or type(mod) ~= "table" then return nil, "juya.lua 执行失败: " .. tostring(mod) end
    return mod
end
local juya, juya_err = load_juya()
if not juya then jn.log.error("juya 模块加载失败: " .. tostring(juya_err)) end

local PLUGIN_NAME = "juya_briefing"

local state = {
    bot_uin = 0,
    last_check_date = "",
    last_sent_date = "",
    running = false,
    manual_done = false,
    timer_id = 0,
}

-- ============================================================================
-- 1. 配置与基础工具
-- ============================================================================
local function cfg_string(key, default)
    local v = jn.config.get(key)
    if v == nil or v == "" then return default end
    return tostring(v)
end

local function cfg_num(key, default)
    local v = tonumber(jn.config.get(key))
    if not v then return default end
    return v
end

local function cfg_bool(key, default)
    local v = jn.config.get(key)
    if v == nil then return default end
    return v ~= false and v ~= "false" and v ~= "0"
end

local function get_bot_uin()
    if state.bot_uin > 0 then return state.bot_uin end
    if jn.onebot11 and jn.onebot11.get_login_info then
        local info = jn.onebot11.get_login_info()
        if info and info.user_id then
            state.bot_uin = tonumber(info.user_id) or 0
        end
    end
    return state.bot_uin
end

-- 按 UTF-8 边界截断，避免切出半个汉字
local function truncate(s, max)
    s = tostring(s or "")
    max = tonumber(max) or 160
    if max <= 0 or #s <= max then return s end
    local cut = max
    while cut > 1 do
        local b = s:byte(cut + 1)
        if b and b >= 0x80 and b <= 0xBF then cut = cut - 1 else break end
    end
    return s:sub(1, cut) .. "…"
end

-- 配置里的 feeds：RSS（.xml / rss / atom）与期号模板（含 {date}）分开
local function resolve_feeds()
    local rss, issue = "", ""
    local list = jn.config.get("feeds")
    if type(list) == "table" then
        for _, v in ipairs(list) do
            local u = tostring(v or "")
            if u ~= "" then
                if u:find("{date}", 1, true) or u:find("/issues/", 1, true) then
                    if issue == "" then issue = u end
                else
                    if rss == "" then rss = u end
                end
            end
        end
    end
    if rss == "" and issue == "" then
        rss = "https://daily.juya.uk/rss.xml"
        issue = "https://daily.juya.uk/issues/{date}/"
    end
    return { rss = rss, issue = issue }
end

-- ============================================================================
-- 2. 抓取 + 组节点 + 发送
-- ============================================================================
local function build_nodes(cats, max_items, summary_max, links_max, nickname, issue_date, bili)
    local bot_uin = get_bot_uin()
    if bot_uin <= 0 then bot_uin = 1772023368 end
    local nodes, count = {}, 0

    local function add(content)
        nodes[#nodes + 1] = { user_id = bot_uin, nickname = nickname, content = content }
    end

    -- 1) 报头：期号 + 哔哩哔哩收看链接
    local header = "AI 早报 " .. (issue_date ~= "" and issue_date or os.date("%Y-%m-%d"))
    if bili and bili ~= "" then
        header = header .. "\n🎬 哔哩哔哩：" .. bili
    end
    add(header)

    -- 2) 概览：一个分类一条，行格式「标题 ↗ #序号」
    add("📋 概览")
    local idx = 0
    for _, c in ipairs(cats) do
        local lines = { "【" .. c.name .. "】" }
        for _, it in ipairs(c.items) do
            if idx >= max_items then break end
            idx = idx + 1
            lines[#lines + 1] = string.format("#%d %s", idx, it.title)
        end
        if #lines > 1 then add(table.concat(lines, "\n")) end
    end

    -- 3) 详情：每条一条（标题 + 摘要 + 全部来源链接）
    idx = 0
    for _, c in ipairs(cats) do
        for _, it in ipairs(c.items) do
            if count >= max_items then break end
            count = count + 1
            idx = idx + 1
            local parts = { string.format("#%d 【%s】%s", idx, c.name, it.title) }
            local summary = truncate(it.summary, summary_max)
            if summary ~= "" then parts[#parts + 1] = summary end
            local links = juya.links_text(it.links, links_max)
            if links ~= "" then parts[#parts + 1] = links end
            local text = table.concat(parts, "\n")
            if it.images and #it.images > 0 then
                -- 配图全部发出，放在链接之后
                local segs = { { type = "text", data = { text = text } } }
                for _, img in ipairs(it.images) do
                    segs[#segs + 1] = { type = "image", data = { file = img } }
                end
                nodes[#nodes + 1] = { user_id = bot_uin, nickname = nickname, content = segs }
            else
                add(text)
            end
        end
    end
    return nodes, count
end

local function chunk_text(text, max)
    max = max or 1500
    local out, buf, size = {}, {}, 0
    local src = tostring(text) .. "\n"
    for line in src:gmatch("([^\n]*)\n") do
        if size + #line + 1 > max and #buf > 0 then
            out[#out + 1] = table.concat(buf, "\n")
            buf, size = {}, 0
        end
        buf[#buf + 1] = line
        size = size + #line + 1
    end
    if #buf > 0 then out[#out + 1] = table.concat(buf, "\n") end
    return out
end

local function send_to_target(target_type, target_id, nodes)
    if #nodes == 0 then return false, "节点为空" end
    local forward = cfg_bool("forward", true)

    local function send_text(text)
        if target_type == "private" then
            return jn.onebot11.send_private_msg(target_id, text)
        end
        return jn.onebot11.send_group_msg(target_id, text)
    end

    -- 兜底：拼成少量文本，绝不逐节点发送
    local function send_nodes_as_text()
        local parts = {}
        for _, n in ipairs(nodes) do
            if type(n.content) == "string" and n.content ~= "" then parts[#parts + 1] = n.content end
        end
        local chunks = chunk_text(table.concat(parts, "\n\n"), 1500)
        for _, c in ipairs(chunks) do send_text(c) end
        jn.log.warn(string.format("[%s] 合并转发不可用，已合并为 %d 条文本发送", PLUGIN_NAME, #chunks))
        return true
    end

    if forward and target_type == "private" and jn.onebot11.send_private_forward_msg_sync then
        local id, err = jn.onebot11.send_private_forward_msg_sync(target_id, nodes)
        if err == nil then return true end
        jn.log.warn("[" .. PLUGIN_NAME .. "] 私聊合并转发失败: " .. tostring(err))
        return send_nodes_as_text()
    end
    if forward and target_type ~= "private" and jn.onebot11.send_group_forward_msg_sync then
        local id, err = jn.onebot11.send_group_forward_msg_sync(target_id, nodes)
        if err == nil then return true end
        jn.log.warn("[" .. PLUGIN_NAME .. "] 群合并转发失败: " .. tostring(err))
        return send_nodes_as_text()
    end
    return send_nodes_as_text()
end

-- 抓取并发送一期；返回 是否发送, 说明
function push_briefing(force)
    if state.running then return false, "正在执行" end
    if not force and not cfg_bool("enabled", true) then return false, "已关闭" end

    local target_type = cfg_string("target_type", "group")
    local group_id = tonumber(cfg_string("target_group", ""))
    if not group_id then
        return false, "未配置推送目标（target_group 为空）"
    end

    if not juya then
        return false, "juya 模块未加载"
    end
    state.running = true
    local ok_call, sent_ok, sent_msg = pcall(function()
        local feeds = resolve_feeds()
        local today = os.date("%Y-%m-%d")
        local url, html, source, err = juya.fetch_issue(feeds, today)
        if not url then
            jn.log.warn("[" .. PLUGIN_NAME .. "] 抓取失败: " .. tostring(err))
            return false, tostring(err)
        end

        local issue_date = juya.issue_date(url) or ""
        if not force and issue_date ~= "" and issue_date ~= today then
            jn.log.info(string.format("[%s] 当期日期 %s 不是今天（%s），今日未出刊，跳过", PLUGIN_NAME, issue_date, today))
            return false, "今日未出刊"
        end

        local cache_key = "sent:" .. (issue_date ~= "" and issue_date or url)
        if not force and jn.cache.get(cache_key) then
            jn.log.info("[" .. PLUGIN_NAME .. "] 本期已发送过: " .. cache_key)
            return false, "已发送"
        end

        local cats = juya.parse_issue(html)
        if #cats == 0 then
            jn.log.warn("[" .. PLUGIN_NAME .. "] 页面解析为空: " .. url)
            return false, "解析为空"
        end

        local bili = html:match("https?://www%.bilibili%.com/video/BV%w+") or ""
        local nodes, count = build_nodes(
            cats,
            cfg_num("max_items", 70),
            cfg_num("summary_max_chars", 160),
            cfg_num("links_max", 6),
            cfg_string("node_nickname", "橘鸦·AI早报"),
            issue_date,
            bili
        )
        local sent, send_err = send_to_target(target_type, group_id, nodes)
        if not sent then
            jn.log.error("[" .. PLUGIN_NAME .. "] 发送失败: " .. tostring(send_err))
            return false, send_err
        end

        jn.cache.set(cache_key, os.time(), 7 * 86400)
        state.last_sent_date = issue_date
        jn.log.info(string.format("[%s] 早报已发送到 %s:%d（来源=%s，节点=%d，新闻=%d）",
            PLUGIN_NAME, target_type, group_id, tostring(source), #nodes, count))
        return true, nil
    end)
    state.running = false

    if not ok_call then
        jn.log.error("[" .. PLUGIN_NAME .. "] 执行异常: " .. tostring(sent_ok))
        return false, tostring(sent_ok)
    end
    return sent_ok, sent_msg
end

-- ============================================================================
-- 3. 定时器（30s 轮询）
-- ============================================================================
local function check_timer()
    local today = os.date("%Y-%m-%d")
    local hm = os.date("%H:%M")
    local target = cfg_string("send_time", "11:30")
    if #target == 4 then target = "0" .. target end

    if hm == target and state.last_check_date ~= today then
        state.last_check_date = today
        jn.log.info(string.format("[%s] 到达发送时间 %s，抓取当期早报...", PLUGIN_NAME, target))
        push_briefing(false)
    end

    -- 手动触发：开关打开后执行一次（force，忽略日期与去重）
    if not cfg_bool("manual_trigger", false) then
        state.manual_done = false -- 开关关回后可再次触发
    elseif not state.manual_done then
        state.manual_done = true
        jn.log.info("[" .. PLUGIN_NAME .. "] 检测到立即触发开关，执行一次推送")
        if jn.timer and jn.timer.after then
            jn.timer.after(0.5, { action = "manual_push" })
        else
            push_briefing(true)
        end
    end

    if jn.timer and jn.timer.after then
        state.timer_id = jn.timer.after(30, { action = "daily_check" })
    end
end

function on_timer_response(req_id, ctx, result, err)
    if err then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 定时器回调异常: " .. tostring(err))
        return
    end
    if type(ctx) ~= "table" then return end
    if ctx.action == "daily_check" then
        check_timer()
    elseif ctx.action == "manual_push" then
        push_briefing(true)
    end
end

-- 外部 CronJob 触发（redrock_cron_msg 等）也支持
function on_cronjob(event)
    jn.log.info("[" .. PLUGIN_NAME .. "] 收到 CronJob 触发，抓取当期早报...")
    push_briefing(true)
end

-- ============================================================================
-- 4. 启动
-- ============================================================================
jn.log.info("[" .. PLUGIN_NAME .. "] 橘鸦早报插件已加载")

if jn.timer and jn.timer.after then
    state.timer_id = jn.timer.after(10, { action = "daily_check" })
end
