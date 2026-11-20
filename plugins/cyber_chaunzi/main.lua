-- ====================================================================
-- 赛博串子 (cyber_chaunzi)
-- --------------------------------------------------------------------
-- 接 searchanythingfun 素材检索，在群里「串」别人：
--   · 后台静默：按概率挑一条群消息去检索一张合适的表情包并发出
--   · 前台手动：/开串 开启本群串子模式，/串子出去 结束
--   · 只发表情包（素材 image），不生成文字
--   · 开串 / 结束 / 每次串完 可各发一个 QQ 表情包
--
-- API：https://www.searchanythingfun.xyz
--   POST /api/reply  （AI 选材，20 次/天）
--   POST /api/search （语义检索，500 次/天、30 次/分）
--   GET  /api/session（额度）
-- ====================================================================

local jn = require("jn")

local PLUGIN = "cyber_chaunzi"
local TABLE_SESSIONS = "pluggin_cyber_chaunzi_sessions"
local DEFAULT_API_BASE = "https://www.searchanythingfun.xyz"

local sessions = {}   -- group_id -> true（内存态，启动时从库加载）
local inflight = {}   -- group_id -> true（同一群同时只跑一次检索）
local state = { quota = nil }

-- --------------------------------------------------------------------
-- 配置读取
-- --------------------------------------------------------------------
local function cstr(key, default)
    local v = jn.config.get(key)
    if v == nil or v == "" then return default end
    return tostring(v)
end

local function cnum(key, default)
    local n = tonumber(jn.config.get(key))
    return n or default
end

local function cbool(key, default)
    local v = jn.config.get(key)
    if v == nil then return default end
    return v ~= false and v ~= "false" and v ~= "0"
end

local function clist(key)
    local v = jn.config.get(key)
    local out = {}
    if type(v) == "table" then
        for _, x in ipairs(v) do out[#out + 1] = tostring(x) end
    elseif type(v) == "string" and v ~= "" then
        for x in v:gmatch("[^,，%s]+") do out[#out + 1] = x end
    end
    return out
end

local function today()
    return os.date("%Y-%m-%d")
end

local function api_base()
    local b = cstr("api_base", DEFAULT_API_BASE)
    return (b:gsub("/+$", ""))
end

-- --------------------------------------------------------------------
-- 数据表：串子会话（跨重启保留，/串子出去 才会删）
-- --------------------------------------------------------------------
local function init_db()
    local sql = [[CREATE TABLE IF NOT EXISTS ]] .. TABLE_SESSIONS .. [[ (
        group_id BIGINT PRIMARY KEY,
        enabled_by BIGINT NOT NULL DEFAULT 0,
        enabled_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
    )]]
    local _, err = jn.database.exec(sql)
    if err then
        jn.log.error("[" .. PLUGIN .. "] 建表失败: " .. tostring(err))
    end
end

local function load_sessions()
    sessions = {}
    local rows, err = jn.database.query("SELECT group_id FROM " .. TABLE_SESSIONS)
    if err then
        jn.log.warn("[" .. PLUGIN .. "] 读取会话失败: " .. tostring(err))
        return
    end
    for _, r in ipairs(rows or {}) do
        local gid = tonumber(r.group_id)
        if gid then sessions[gid] = true end
    end
end

-- --------------------------------------------------------------------
-- 工具
-- --------------------------------------------------------------------
local function self_id()
    if not (jn.onebot11 and jn.onebot11.get_login_info) then return 0 end
    local info = jn.onebot11.get_login_info()
    if type(info) ~= "table" then return 0 end
    return tonumber(info.user_id or info.userId or 0) or 0
end

local function strip_cq(s)
    s = tostring(s or "")
    s = s:gsub("%[CQ:[^%]]*%]", " ")
    s = s:gsub("&amp;", "&")
    s = s:gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip(s, n)
    s = tostring(s or "")
    if #s <= n then return s end
    return s:sub(1, n)
end

local function group_allowed(gid)
    local list = clist("target_groups")
    if #list == 0 then return true end
    for _, v in ipairs(list) do
        if tonumber(v) == gid then return true end
    end
    return false
end

local function is_admin(event)
    if not cbool("admin_only", true) then return true end
    local uid = tostring(event.user_id or "")
    for _, a in ipairs(clist("admins")) do
        if a == uid then return true end
    end
    local sys = event.admins
    if type(sys) == "table" then
        for _, a in ipairs(sys) do
            if tostring(a) == uid then return true end
        end
    end
    return false
end

local function sticker_id(raw)
    local s = tostring(raw or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^stk://", "")
    s = s:gsub("%[CQ:image,", ""):gsub(",subType=1%]", "")
    return s
end

local function send_sticker(gid, raw)
    local id = sticker_id(raw)
    if id == "" then return end
    if not (jn.onebot11 and jn.onebot11.send_group_sticker) then
        jn.log.warn("[" .. PLUGIN .. "] 当前引擎不支持 send_group_sticker，跳过表情包")
        return
    end
    jn.onebot11.send_group_sticker(gid, id)
end

-- --------------------------------------------------------------------
-- 额度：GET /api/session，缓存 10 分钟
-- --------------------------------------------------------------------
local function quota()
    local q = jn.cache.get("quota")
    if type(q) == "table" then return q end
    return nil
end

local function refresh_quota()
    local url = api_base() .. "/api/session"
    local proxy = cstr("proxy", "")
    if proxy ~= "" then
        jn.http.get_async(url, { stage = "session" }, nil, proxy)
    else
        jn.http.get_async(url, { stage = "session" })
    end
end

local function search_used()
    return tonumber(jn.cache.get("search:" .. today()) or 0) or 0
end

local function search_inc()
    local key = "search:" .. today()
    local n = search_used() + 1
    jn.cache.set(key, tostring(n), 86400 * 2)
    return n
end

local function search_cap()
    local q = quota()
    local cap = type(q) == "table" and tonumber(q.searches_per_day) or nil
    return cap or 500
end

local function quota_ok()
    local guard = cnum("quota_guard_min", 20)
    local left = search_cap() - search_used()
    if left <= 0 then return false end
    if left < guard then
        -- 额度见底：降频到 20%
        return math.random() * 100 <= 20
    end
    return true
end

-- --------------------------------------------------------------------
-- 日常频率：冷却 + 每群每日上限
-- --------------------------------------------------------------------
local function cooldown_hit(gid)
    local cd = cnum("cooldown_seconds", 60)
    if cd <= 0 then return false end
    return jn.cache.get("cd:" .. tostring(gid)) ~= nil
end

local function mark_cooldown(gid)
    local cd = cnum("cooldown_seconds", 60)
    if cd > 0 then jn.cache.set("cd:" .. tostring(gid), "1", cd) end
end

local function daily_used(gid)
    return tonumber(jn.cache.get("cnt:" .. tostring(gid) .. ":" .. today()) or 0) or 0
end

local function daily_inc(gid)
    local key = "cnt:" .. tostring(gid) .. ":" .. today()
    local n = daily_used(gid) + 1
    jn.cache.set(key, tostring(n), 86400 * 2)
    return n
end

-- AI 选材次数（本地记账，防超 20 次/天）
local function ai_used()
    return tonumber(jn.cache.get("ai:" .. today()) or 0) or 0
end

local function ai_inc()
    local key = "ai:" .. today()
    local n = ai_used() + 1
    jn.cache.set(key, tostring(n), 86400 * 2)
    return n
end

-- --------------------------------------------------------------------
-- 选材与发送
-- --------------------------------------------------------------------
local function abs_image(path)
    if path == nil then return nil end
    local s = tostring(path)
    if s == "" then return nil end
    if s:find("^https?://") then return s end
    if s:sub(1, 1) == "/" then return api_base() .. s end
    return nil
end

local function apply_image_proxy(url)
    local prefix = cstr("image_proxy_prefix", "")
    if prefix == "" then return url end
    if prefix:find("url=", 1, true) then
        return prefix .. (url:gsub("?", "%%3F"):gsub("&", "%%26"))
    end
    return prefix .. url:gsub("^https?://", "")
end

local function pick_item(results, key)
    -- results: 素材数组；淘汰没有图片的，避开上一次发过的那条
    local gid, last = key.gid, jn.cache.get("last:" .. tostring(key.gid))
    local pool = {}
    for _, it in ipairs(results or {}) do
        if type(it) == "table" then
            local img = abs_image(it.image)
            if img and tostring(it.id or "") ~= tostring(last or "") then
                pool[#pool + 1] = { id = tostring(it.id or ""), image = img, text = tostring(it.text or "") }
            end
        end
    end
    if #pool == 0 then
        -- 全被 last 过滤掉时退化为纯有图集合
        for _, it in ipairs(results or {}) do
            if type(it) == "table" then
                local img = abs_image(it.image)
                if img then pool[#pool + 1] = { id = tostring(it.id or ""), image = img } end
            end
        end
    end
    if #pool == 0 then return nil end
    return pool[math.random(#pool)]
end

local function send_material(gid, item)
    if not item or not item.image then return false end
    local url = apply_image_proxy(item.image)
    jn.cache.set("last:" .. tostring(gid), item.id, 86400)
    local ok, err = jn.onebot11.send_group_msg(gid, {
        { type = "image", data = { file = url } },
    })
    if ok == false then
        jn.log.warn("[" .. PLUGIN .. "] 表情包发送失败 gid=" .. tostring(gid) .. " err=" .. tostring(err))
        return false
    end
    daily_inc(gid)
    jn.log.info(string.format("[%s] 已串 gid=%d 素材=%s", PLUGIN, gid, tostring(item.id)))
    if cbool("emoji_each_enabled", true) then
        send_sticker(gid, cstr("emoji_each", ""))
    end
    return true
end

-- --------------------------------------------------------------------
-- 检索请求
-- --------------------------------------------------------------------
local function request_search(gid, query)
    local body = jn.json.encode({
        query = clip(query, 200),
        mode = "semantic",
        limit = cnum("limit", 8),
    })
    search_inc()
    local ok, id = pcall(jn.http.post_async, api_base() .. "/api/search", "application/json", body,
        { ctx = { stage = "search", gid = gid, query = query } })
    if not ok or not id or id == 0 then
        inflight[gid] = nil
        jn.log.warn("[" .. PLUGIN .. "] 检索请求提交失败 gid=" .. tostring(gid))
    end
end

local function request_material(gid, query)
    inflight[gid] = true
    mark_cooldown(gid)
    -- 兜底：回调丢包时 90 秒后解除占用，避免该群永久卡住
    if jn.timer and jn.timer.after then
        jn.timer.after(90, { action = "clear_inflight", gid = gid })
    end

    local api_mode = cstr("api_mode", "hybrid")
    local use_reply = (api_mode == "hybrid")
        and ai_used() < cnum("ai_daily_cap", 20)
        and quota_ok()

    if use_reply then
        ai_inc()
        local body = jn.json.encode({
            query = clip(query, 200),
            style = cstr("api_style", "fun"),
            limit = cnum("limit", 8),
        })
        local ok, id = pcall(jn.http.post_async, api_base() .. "/api/reply", "application/json", body,
            { ctx = { stage = "reply", gid = gid, query = query } })
        if ok and id and id ~= 0 then return end
        jn.log.warn("[" .. PLUGIN .. "] AI 选材提交失败，改走检索")
    end

    request_search(gid, query)
end

-- --------------------------------------------------------------------
-- 异步回调：HTTP
-- --------------------------------------------------------------------
function on_http_response(req_id, ctx, result, err)
    if not ctx or not ctx.stage then return end

    if ctx.stage == "session" then
        local body = result and result.status == 200 and result.body or nil
        local parsed = body and jn.json.decode(body) or nil
        local limits = type(parsed) == "table" and parsed.limits or nil
        if type(limits) == "table" then
            jn.cache.set("quota", {
                searches_per_day = tonumber(limits.searchesPerDay or 500),
                ai_per_day = tonumber(limits.aiPerDay or 20),
            }, 900)
        end
        return
    end

    local gid = tonumber(ctx.gid) or 0
    if gid <= 0 then return end

    local status = result and tonumber(result.status) or 0
    local body = result and result.body or ""
    local parsed = nil
    if status == 200 and body ~= "" then
        local ok, obj = pcall(jn.json.decode, body)
        if ok and type(obj) == "table" then parsed = obj end
    end

    if ctx.stage == "reply" then
        local picks = parsed and parsed.picks or nil
        local items = {}
        if type(picks) == "table" then
            for _, p in ipairs(picks) do
                if type(p) == "table" and type(p.item) == "table" then
                    items[#items + 1] = p.item
                end
            end
        end
        local item = pick_item(items, { gid = gid })
        if item then
            inflight[gid] = nil
            send_material(gid, item)
            return
        end
        if status == 429 then
            inflight[gid] = nil
            jn.log.warn("[" .. PLUGIN .. "] AI 选材被限流，暂停 60s")
            jn.cache.set("cd:" .. tostring(gid), "1", 60)
            return
        end
        -- AI 没挑到合适图片：退回检索
        request_search(gid, ctx.query or "")
        return
    end

    if ctx.stage == "search" then
        inflight[gid] = nil
        if status == 429 then
            jn.log.warn("[" .. PLUGIN .. "] 检索被限流，暂停 60s")
            jn.cache.set("cd:" .. tostring(gid), "1", 60)
            return
        end
        local results = parsed and parsed.results or nil
        local item = pick_item(results, { gid = gid })
        if item then
            send_material(gid, item)
        else
            jn.log.info("[" .. PLUGIN .. "] 未检索到可用表情包 gid=" .. tostring(gid))
        end
    end
end

-- --------------------------------------------------------------------
-- 异步回调：定时器（清理 inflight 占用）
-- --------------------------------------------------------------------
function on_timer_response(req_id, ctx, result, err)
    if ctx and ctx.action == "clear_inflight" then
        local gid = tonumber(ctx.gid)
        if gid then inflight[gid] = nil end
    end
end

-- --------------------------------------------------------------------
-- 前台命令
-- --------------------------------------------------------------------
local function start_session(args, event)
    if cstr("mode", "both") == "silent" then
        return true, "当前为后台静默模式，未启用 /开串"
    end
    if event.message_type ~= "group" then
        return true, "串子只能在群里开"
    end
    if not is_admin(event) then
        return true, "你没有开串权限"
    end
    local gid = tonumber(event.group_id) or 0
    if gid <= 0 then return true, nil end

    sessions[gid] = true
    local _, err = jn.database.exec([[
        INSERT INTO ]] .. TABLE_SESSIONS .. [[ (group_id, enabled_by, enabled_at)
        VALUES (?, ?, now())
        ON CONFLICT (group_id) DO UPDATE SET enabled_by = EXCLUDED.enabled_by, enabled_at = now()
    ]], { gid, tonumber(event.user_id) or 0 })
    if err then
        jn.log.error("[" .. PLUGIN .. "] 开启会话失败: " .. tostring(err))
        return true, "开串失败，请查看日志"
    end
    jn.log.info(string.format("[%s] 群 %d 开串 by %s", PLUGIN, gid, tostring(event.user_id)))
    if cbool("emoji_start_enabled", true) then
        send_sticker(gid, cstr("emoji_start", ""))
    end
    return true, nil
end

local function stop_session(args, event)
    if cstr("mode", "both") == "silent" then
        return true, "当前为后台静默模式，未启用 /串子出去"
    end
    if event.message_type ~= "group" then
        return true, "串子只能在群里结束"
    end
    if not is_admin(event) then
        return true, "你没有结束串子的权限"
    end
    local gid = tonumber(event.group_id) or 0
    if gid <= 0 then return true, nil end

    sessions[gid] = nil
    jn.database.exec("DELETE FROM " .. TABLE_SESSIONS .. " WHERE group_id = ?", { gid })
    jn.log.info(string.format("[%s] 群 %d 串子收工 by %s", PLUGIN, gid, tostring(event.user_id)))
    if cbool("emoji_end_enabled", true) then
        send_sticker(gid, cstr("emoji_end", ""))
    end
    return true, nil
end

-- --------------------------------------------------------------------
-- 静默触发
-- --------------------------------------------------------------------
local function handle_builtin_command(event, raw)
    local body = raw:match("^%s*/%s*([^%s]+)")
    if not body then return false end
    if body == cstr("command_start", "开串") then
        start_session({}, event)
        return true
    end
    if body == cstr("command_end", "串子出去") then
        stop_session({}, event)
        return true
    end
    return false
end

function on_message(event)
    if not event or event.message_type ~= "group" then return false, nil end
    if not cbool("enabled", true) then return false, nil end

    local gid = tonumber(event.group_id) or 0
    if gid <= 0 or not group_allowed(gid) then return false, nil end

    local uid = tonumber(event.user_id) or 0
    local me = self_id()
    if me > 0 and uid == me then return false, nil end

    local raw = event.raw_message or ""
    -- 命令系统若没命中（例如中文命令名），这里兜底执行，避免 /开串 失效
    if handle_builtin_command(event, raw) then return true, nil end
    if raw:match("^%s*/%S") then return false, nil end   -- 其它命令交给命令系统

    local text = strip_cq(raw)
    if #text < cnum("min_chars", 2) then return false, nil end
    if inflight[gid] then return false, nil end

    local mode = cstr("mode", "both")
    local in_session = (mode ~= "silent") and sessions[gid] == true
    if mode == "manual" and not in_session then return false, nil end

    if daily_used(gid) >= cnum("daily_cap", 500) then return false, nil end
    if cooldown_hit(gid) then return false, nil end
    if not quota_ok() then return false, nil end

    local prob = in_session and cnum("session_probability", 100) or cnum("silent_probability", 3)
    if prob <= 0 then return false, nil end
    if math.random() * 100 > prob then return false, nil end

    -- 顺手刷新一次额度（缓存 10 分钟）
    if quota() == nil then refresh_quota() end

    request_material(gid, text)
    return false, nil
end

-- --------------------------------------------------------------------
-- 启动
-- --------------------------------------------------------------------
init_db()
load_sessions()

local start_cmd = cstr("command_start", "开串")
local end_cmd = cstr("command_end", "串子出去")

if jn.command and jn.command.register then
    jn.command.register(start_cmd, start_session, {
        description = "开启本群赛博串子模式",
        usage = "/" .. start_cmd,
    })
    jn.command.register(end_cmd, stop_session, {
        description = "结束本群赛博串子模式",
        usage = "/" .. end_cmd,
    })
end

refresh_quota()

jn.log.info(string.format("[%s] 赛博串子已加载：模式=%s，会话群=%d",
    PLUGIN, cstr("mode", "both"), (function()
        local n = 0
        for _ in pairs(sessions) do n = n + 1 end
        return n
    end)()))
