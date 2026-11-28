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
local function build_nodes(cats, max_items, links_max, nickname, issue_date, bili)
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
            local summary = tostring(it.summary or "")
            if summary ~= "" then parts[#parts + 1] = summary end
            local detail = tostring(it.detail or "")
            if detail ~= "" and detail ~= summary then parts[#parts + 1] = detail end
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

-- 解析推送目标列表：list 或逗号分隔字符串，去重、仅保留正整数 ID
local function get_targets()
    local raw = jn.config.get("target_groups")
    local list, seen = {}, {}
    local function push(v)
        local id = tonumber(v)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    if type(raw) == "table" then
        for _, v in ipairs(raw) do push(v) end
    elseif type(raw) == "string" and raw ~= "" then
        for item in raw:gmatch("[^,,%s]+") do push(item) end
    end
    return list
end


-- 图片会让合并转发接口超时；保留全部文本，单独出一份无图节点用于重试
local function strip_images(nodes)
    local out = {}
    for _, n in ipairs(nodes) do
        if type(n.content) == "string" then
            out[#out + 1] = n
        else
            local segs = {}
            for _, seg in ipairs(n.content or {}) do
                if seg.type ~= "image" then segs[#segs + 1] = seg end
            end
            if #segs > 0 then
                out[#out + 1] = { user_id = n.user_id, nickname = n.nickname, content = segs }
            end
        end
    end
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
            local content = n.content
            if type(content) == "string" then
                if content ~= "" then parts[#parts + 1] = content end
            elseif type(content) == "table" then
                local texts = {}
                for _, seg in ipairs(content) do
                    if seg.type == "text" and seg.data and seg.data.text then
                        texts[#texts + 1] = seg.data.text
                    end
                end
                local txt = table.concat(texts, "\n")
                if txt ~= "" then parts[#parts + 1] = txt end
            end
        end
        local chunks = chunk_text(table.concat(parts, "\n\n"), 1500)
        for _, c in ipairs(chunks) do send_text(c) end
        jn.log.warn(string.format("[%s] 合并转发不可用，已合并为 %d 条文本发送", PLUGIN_NAME, #chunks))
        return true
    end

    if forward and target_type == "private" and jn.onebot11.send_private_forward_msg_sync then
        local id, err = jn.onebot11.send_private_forward_msg_sync(target_id, nodes)
        if err == nil then return true end
        local err_s = tostring(err)
        if err_s:lower():find("timeout", 1, true) then
            jn.log.warn("[" .. PLUGIN_NAME .. "] 私聊合并转发等待回包超时（协议端通常已投递，不再重发以免重复）: " .. err_s)
            return true
        end
        jn.log.warn("[" .. PLUGIN_NAME .. "] 私聊合并转发失败: " .. err_s)
        return send_nodes_as_text()
    end
    if forward and target_type ~= "private" and jn.onebot11.send_group_forward_msg_sync then
        local plain = strip_images(nodes)
        local attempts = {
            { nodes = nodes, label = "原始" },
            { nodes = plain, label = "纯文本" },
        }
        for _, attempt in ipairs(attempts) do
            local id, err = jn.onebot11.send_group_forward_msg_sync(target_id, attempt.nodes)
            if err == nil then
                jn.log.info(string.format("[%s] 群合并转发成功（%s，%d 节点）",
                    PLUGIN_NAME, attempt.label, #attempt.nodes))
                return true
            end
            local err_s = tostring(err)
            if err_s:lower():find("timeout", 1, true) then
                -- 协议端实际已发送但 WS 回包慢于 Go 超时，重试会导致群内重复刷两条以上
                jn.log.warn(string.format("[%s] 群合并转发等待超时（%s，%d 节点），按已投递处理以防重复刷屏: %s",
                    PLUGIN_NAME, attempt.label, #attempt.nodes, err_s))
                return true
            end
            jn.log.warn(string.format("[%s] 群合并转发失败（%s，%d 节点）: %s",
                PLUGIN_NAME, attempt.label, #attempt.nodes, err_s))
        end
        return send_nodes_as_text()
    end
    return send_nodes_as_text()
end

-- 抓取并发送一期；返回 是否发送, 说明
function push_briefing(force)
    if state.running then return false, "正在执行" end
    if not force and not cfg_bool("enabled", true) then return false, "已关闭" end

    local target_type = cfg_string("target_type", "group")
    local targets = get_targets()
    if #targets == 0 then
        -- 兼容旧配置键
        local legacy = tonumber(cfg_string("target_group", ""))
        if legacy then targets = { legacy } end
    end
    if #targets == 0 then
        return false, "未配置推送目标（target_groups 为空）"
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
        -- 按群去重：Bot 侧 cache.get 仅解 JSON 对象，兼容旧数值键须同时检查 cache.exists
        local function is_group_sent(ck)
            if jn.cache.get(ck) ~= nil then return true end
            if jn.cache.exists and jn.cache.exists(ck) == 1 then return true end
            return false
        end
        local pending = {}
        for _, gid in ipairs(targets) do
            if force or not is_group_sent(cache_key .. ":" .. gid) then
                pending[#pending + 1] = gid
            end
        end
        if #pending == 0 then
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
            cfg_num("links_max", 6),
            cfg_string("node_nickname", "橘鸦·AI早报"),
            issue_date,
            bili
        )
        local ok_list, fail_list = {}, {}
        for _, gid in ipairs(pending) do
            local sent, send_err = send_to_target(target_type, gid, nodes)
            if sent then
                ok_list[#ok_list + 1] = tostring(gid)
                jn.cache.set(cache_key .. ":" .. gid, { ts = os.time() }, 7 * 86400)
            else
                fail_list[#fail_list + 1] = tostring(gid) .. "(" .. tostring(send_err) .. ")"
            end
        end
        if #ok_list == 0 then
            jn.log.error("[" .. PLUGIN_NAME .. "] 全部目标发送失败: " .. table.concat(fail_list, ", "))
            return false, table.concat(fail_list, ", ")
        end
        if #fail_list > 0 then
            jn.log.warn("[" .. PLUGIN_NAME .. "] 部分目标失败: " .. table.concat(fail_list, ", "))
        end

        state.last_sent_date = issue_date
        jn.log.info(string.format("[%s] 早报已发送到 %s（来源=%s，节点=%d，新闻=%d）",
            PLUGIN_NAME, table.concat(ok_list, ","), tostring(source), #nodes, count))
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
-- "HH:MM" → 当日分钟数；非法返回 nil
local function hhmm_to_min(v)
    local h, m = tostring(v):match("^(%d%d?):(%d%d)$")
    if not h then return nil end
    return tonumber(h) * 60 + tonumber(m)
end

local function check_timer()
    local today = os.date("%Y-%m-%d")
    local now_min = tonumber(os.date("%H")) * 60 + tonumber(os.date("%M"))
    local target = cfg_string("send_time", "11:30")
    local target_min = hhmm_to_min(target)
    -- 补发窗口：错过精确分钟（重载/重启/回调阻塞）后仍能在窗口内补发，0 = 不补发
    local catchup = cfg_num("catchup_hours", 3) * 60

    if target_min and state.last_check_date ~= today then
        local late = now_min - target_min
        if late >= 0 and (late == 0 or (catchup > 0 and late <= catchup)) then
            state.last_check_date = today
            if late > 0 then
                jn.log.info(string.format("[%s] 发送时间 %s 已过 %d 分钟，仍在补发窗口内，立即补发", PLUGIN_NAME, target, late))
            else
                jn.log.info(string.format("[%s] 到达发送时间 %s，抓取当期早报...", PLUGIN_NAME, target))
            end
            push_briefing(false)
        elseif late > catchup and catchup >= 0 then
            -- 超出补发窗口：当天放弃，记一次避免反复判断
            state.last_check_date = today
            jn.log.warn(string.format("[%s] 发送时间 %s 已过 %d 分钟，超出补发窗口（%s 小时），今日不发送",
                PLUGIN_NAME, target, late, tostring(cfg_num("catchup_hours", 3))))
        end
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
