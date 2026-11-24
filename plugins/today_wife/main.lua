-- ============================================================================
-- today_wife: 群聊今日老婆插件
-- 作者: Churnie HXCN
-- 复刻自: astrbot_plugin_today_wife (专为 JuanNiang-Neo 架构深度定制)
--
-- 指令：
--   /今日老婆 /查老婆 /我的老婆          查看当前老婆列表
--   /随机老婆 /娶老婆 /抽老婆            随机抽取（固定配对优先）
--   /强娶 <@|QQ>                         强制绑定指定群友
--   /离婚 <@|QQ>                         解除普通老婆关系（固定配对受保护）
--   /所有人都是我老婆 /全都要            活跃群友全部娶为老婆
--   /强娶全体成员 /全员老婆              群全体成员全部娶为老婆
--   /全部离婚 /净身出户                  解除全部普通老婆关系
--   /老婆关系网 /绿帽图 /本群关系        T2I 渲染本群关系拓扑图
--   /固定老婆 <@|QQ>                     发起永恒 CP 绑定邀请（需对方同意）
--   /同意固定老婆                        同意绑定（被邀请者）
--   /拒绝固定老婆                        拒绝绑定（被邀请者）
--   /解除固定老婆 <@|QQ>                 发起解绑（群管可直接解绑）
--   /同意解除固定老婆                    同意解绑（被邀请者）
--
-- 数据：PostgreSQL 三张业务表（配对 / 次数 / 活跃群友）+ Redis（冷却、邀请态、成员缓存）
-- ============================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

local PLUGIN_NAME = "today_wife"

local T_PAIR   = "pluggin_today_wife_pairings"
local T_COUNT  = "pluggin_today_wife_counts"
local T_ACTIVE = "pluggin_today_wife_active"

-- 邀请态有效期（秒）：发起后对方需在此时间内确认
local INVITE_TTL = 300
-- 群成员昵称映射缓存时长（秒）
local MEMBER_CACHE_TTL = 600
-- 活跃记录写入节流（秒）：同一用户在该窗口内只落库一次
local ACTIVE_THROTTLE = 120
-- 后台清理任务周期（秒）
local CLEAN_INTERVAL = 6 * 3600

-- 固定配对邀请 Redis 键前缀
local K_FIX_REQ    = "fixreq"    -- fixreq:<gid>:<target>    = inviter
local K_FIX_UNBIND = "fixunbind" -- fixunbind:<gid>:<target> = requester

local state = {
    bot_uin = 0,
    timer_id = 0,
}

-- 前向声明
local logical_date
local member_map
local reply

-- ============================================================================
-- 1. 配置读取
-- ============================================================================
local function cfg_str(key, default)
    local v = jn.config.get(key)
    if v == nil or v == "" then return default end
    return tostring(v)
end

local function cfg_num(key, default)
    local v = tonumber(jn.config.get(key))
    if v == nil then return default end
    return math.floor(v)
end

local function cfg_bool(key, default)
    local v = jn.config.get(key)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    local s = tostring(v):lower()
    return s == "true" or s == "1" or s == "yes" or s == "on"
end

-- 启用群列表：留空表示所有群生效
local function enabled_groups()
    local raw = jn.config.get("enable_groups")
    local set = {}
    local any = false
    if type(raw) == "table" then
        for _, v in pairs(raw) do
            local s = tostring(v or ""):match("^%s*(.-)%s*$")
            if s ~= "" then
                if s == "*" then return { __all = true } end
                local gid = tonumber(s)
                if gid and gid > 0 then
                    set[gid] = true
                    any = true
                end
            end
        end
    elseif type(raw) == "string" then
        for item in raw:gmatch("[^,，%s]+") do
            if item == "*" then return { __all = true } end
            local gid = tonumber(item)
            if gid and gid > 0 then
                set[gid] = true
                any = true
            end
        end
    end
    if not any then
        set.__all = true
    end
    return set
end

local function is_enabled_group(group_id)
    local gid = tonumber(group_id) or 0
    if gid <= 0 then return false end
    local set = enabled_groups()
    if set.__all then return true end
    return set[gid] == true
end

-- 猫娘尾缀：开启时统一在回复末尾补「喵~」
local function tail(text)
    if not cfg_bool("enable_cat_tone", true) then
        return text
    end
    return tostring(text) .. " 喵~"
end

-- ============================================================================
-- 2. 基础工具
-- ============================================================================

-- 逻辑日期：以 reset_hour 为分界（例：reset_hour=4 时，03:30 仍算前一天）
function logical_date()
    local reset_hour = cfg_num("reset_hour", 4)
    if reset_hour < 0 or reset_hour > 23 then reset_hour = 4 end
    local ts = os.time() - reset_hour * 3600
    return os.date("%Y-%m-%d", ts)
end

local function get_bot_uin()
    if state.bot_uin and state.bot_uin > 0 then
        return state.bot_uin
    end
    if jn.onebot11 and jn.onebot11.get_login_info then
        local info = jn.onebot11.get_login_info()
        if info and info.user_id then
            state.bot_uin = math.floor(tonumber(info.user_id) or 0)
            return state.bot_uin
        end
    end
    return 0
end

local function xml_escape(s)
    return (tostring(s or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
        :gsub("'", "&#39;"))
end

-- 按 UTF-8 字符数安全截断，并清理双向隔离控制字符，彻底避免切碎中文字符出现豆腐块（□）
local function clean_display_text(s)
    s = tostring(s or "")
    s = s:gsub("\226\129[\166-\169]", ""):gsub("\226\128[\170-\174]", "")
    s = s:gsub("[\r\n\t]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function utf8_clip(s, max_chars)
    s = clean_display_text(s)
    if max_chars <= 0 or s == "" then return "" end
    local count, i, n = 0, 1, #s
    while i <= n do
        if count >= max_chars then
            return s:sub(1, i - 1) .. "…"
        end
        local b = s:byte(i)
        local step = 1
        if b >= 240 then step = 4
        elseif b >= 224 then step = 3
        elseif b >= 192 then step = 2 end
        i = i + step
        count = count + 1
    end
    return s
end

-- 从参数中解析目标 QQ：支持 @某人（CQ 码）与直接输入 QQ 号
local function parse_target(args)
    local joined = table.concat(args or {}, " ")
    if joined == "" then return nil end
    local qq = joined:match("%[CQ:at,qq=(%d+)%]")
    if qq then return tonumber(qq) end
    qq = joined:match("(%d+)")
    if qq then return tonumber(qq) end
    return nil
end

function reply(event, message)
    local gid = tonumber(event.group_id) or 0
    if gid > 0 then
        return jn.onebot11.send_group_msg(gid, message)
    end
    return jn.onebot11.send_private_msg(tonumber(event.user_id) or 0, message)
end

-- 群成员昵称映射：优先 Redis 缓存，未命中调一次 get_group_member_list
-- 缓存值以「条目数组」存放：Lua 数字键表经 JSON 序列化时会被当作数组（键被重排），
-- 显式转成 {qq=string, name=string} 数组可避免该歧义。
function member_map(group_id)
    local gid = tonumber(group_id) or 0
    local key = "members:" .. tostring(gid)
    local cached = jn.cache.get(key)
    if type(cached) == "table" and type(cached.list) == "table" then
        local norm = {}
        for _, e in ipairs(cached.list) do
            if type(e) == "table" then
                local qq = tonumber(e.qq)
                if qq then
                    norm[math.floor(qq)] = tostring(e.name or "")
                end
            end
        end
        if next(norm) ~= nil then
            return norm
        end
    end
    local list = jn.onebot11.get_group_member_list(gid)
    local map = {}
    if type(list) == "table" then
        for _, m in ipairs(list) do
            local qq = math.floor(tonumber(m.user_id) or 0)
            if qq > 0 then
                local name = tostring(m.card or "")
                if name == "" then name = tostring(m.nickname or "") end
                if name ~= "" then
                    map[qq] = name
                end
            end
        end
    end
    -- 仅在拿到成员时才写缓存，避免一次接口抖动把空表缓存 10 分钟
    local entries = {}
    for qq, name in pairs(map) do
        entries[#entries + 1] = { qq = tostring(qq), name = name }
    end
    if #entries > 0 then
        jn.cache.set(key, { list = entries }, MEMBER_CACHE_TTL)
    end
    return map
end

-- 显示名：群名片 > 群昵称 > 兜底 QQ 号
local function display_name(group_id, user_id, map)
    local uid = math.floor(tonumber(user_id) or 0)
    map = map or member_map(group_id)
    local name = map[uid]
    if name and name ~= "" then return name end
    return tostring(uid)
end

-- ============================================================================
-- 3. 数据库初始化与数据访问
-- ============================================================================
local function init_db()
    local sql = [[
        CREATE TABLE IF NOT EXISTS ]] .. T_PAIR .. [[ (
            id BIGSERIAL PRIMARY KEY,
            group_id BIGINT NOT NULL,
            user_id BIGINT NOT NULL,
            wife_id BIGINT NOT NULL,
            is_fixed BOOLEAN NOT NULL DEFAULT FALSE,
            pair_date TEXT NOT NULL DEFAULT '',
            created_at BIGINT NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX IF NOT EXISTS uk_tw_pair
            ON ]] .. T_PAIR .. [[ (group_id, user_id, wife_id, is_fixed, pair_date);
        CREATE INDEX IF NOT EXISTS idx_tw_pair_group_date
            ON ]] .. T_PAIR .. [[ (group_id, pair_date);

        CREATE TABLE IF NOT EXISTS ]] .. T_COUNT .. [[ (
            group_id BIGINT NOT NULL,
            user_id BIGINT NOT NULL,
            stat_date TEXT NOT NULL,
            action TEXT NOT NULL,
            count INT NOT NULL DEFAULT 0,
            PRIMARY KEY (group_id, user_id, stat_date, action)
        );

        CREATE TABLE IF NOT EXISTS ]] .. T_ACTIVE .. [[ (
            group_id BIGINT NOT NULL,
            user_id BIGINT NOT NULL,
            nickname TEXT NOT NULL DEFAULT '',
            last_seen BIGINT NOT NULL DEFAULT 0,
            PRIMARY KEY (group_id, user_id)
        );
    ]]
    local _, err = jn.database.exec(sql)
    if err then
        jn.log.error("[" .. PLUGIN_NAME .. "] 初始化数据库失败: " .. tostring(err))
    else
        jn.log.info("[" .. PLUGIN_NAME .. "] 数据库表初始化就绪")
    end
end

-- 每日惰性重置：清掉非当日的普通配对与次数（固定配对不受影响）
local function ensure_daily_reset(group_id)
    local today = logical_date()
    jn.database.exec(
        "DELETE FROM " .. T_PAIR ..
        " WHERE group_id = ? AND is_fixed = FALSE AND pair_date <> ?",
        { group_id, today })
    jn.database.exec(
        "DELETE FROM " .. T_COUNT .. " WHERE group_id = ? AND stat_date <> ?",
        { group_id, today })
    return today
end

-- 读取某用户当日已用次数
local function get_count(group_id, user_id, action, today)
    local rows = jn.database.query(
        "SELECT count FROM " .. T_COUNT ..
        " WHERE group_id = ? AND user_id = ? AND stat_date = ? AND action = ?",
        { group_id, user_id, today, action })
    if type(rows) == "table" and #rows > 0 then
        return math.floor(tonumber(rows[1].count) or 0)
    end
    return 0
end

local function inc_count(group_id, user_id, action, today)
    jn.database.exec(
        "INSERT INTO " .. T_COUNT .. " (group_id, user_id, stat_date, action, count) " ..
        "VALUES (?, ?, ?, ?, 1) " ..
        "ON CONFLICT (group_id, user_id, stat_date, action) " ..
        "DO UPDATE SET count = " .. T_COUNT .. ".count + 1",
        { group_id, user_id, today, action })
end

-- 次数上限校验：0 表示不限制；通过则自增并返回 true
local function consume_quota(group_id, user_id, action, limit_key, today)
    local limit = cfg_num(limit_key, 0)
    if limit > 0 then
        local used = get_count(group_id, user_id, action, today)
        if used >= limit then
            return false, limit
        end
    end
    inc_count(group_id, user_id, action, today)
    return true, limit
end

-- 冷却校验（Redis）：群冷却 + 用户冷却
local function check_cooldown(group_id, user_id)
    local gsec = cfg_num("group_cooldown_seconds", 5)
    local usec = cfg_num("user_cooldown_seconds", 10)
    local gkey = "cd:g:" .. tostring(group_id)
    local ukey = "cd:u:" .. tostring(group_id) .. ":" .. tostring(user_id)
    if gsec > 0 and jn.cache.exists(gkey) > 0 then
        return false
    end
    if usec > 0 and jn.cache.exists(ukey) > 0 then
        return false
    end
    if gsec > 0 then jn.cache.set(gkey, "1", gsec) end
    if usec > 0 then jn.cache.set(ukey, "1", usec) end
    return true
end

-- 配对写入（幂等）
local function add_pairing(group_id, user_id, wife_id, is_fixed, today)
    local date_key = is_fixed and "" or today
    jn.database.exec(
        "INSERT INTO " .. T_PAIR ..
        " (group_id, user_id, wife_id, is_fixed, pair_date, created_at) VALUES (?, ?, ?, ?, ?, ?) " ..
        "ON CONFLICT (group_id, user_id, wife_id, is_fixed, pair_date) DO NOTHING",
        { group_id, user_id, wife_id, is_fixed, date_key, os.time() })
end

local function remove_pairing(group_id, user_id, wife_id, is_fixed, today)
    if is_fixed then
        jn.database.exec(
            "DELETE FROM " .. T_PAIR ..
            " WHERE group_id = ? AND user_id = ? AND wife_id = ? AND is_fixed = TRUE",
            { group_id, user_id, wife_id })
    else
        jn.database.exec(
            "DELETE FROM " .. T_PAIR ..
            " WHERE group_id = ? AND user_id = ? AND wife_id = ? AND is_fixed = FALSE AND pair_date = ?",
            { group_id, user_id, wife_id, today })
    end
end

-- 某用户当前全部老婆（含固定配对），返回 {qq, fixed} 数组
local function list_wives(group_id, user_id, today)
    local rows = jn.database.query(
        "SELECT wife_id, is_fixed FROM " .. T_PAIR ..
        " WHERE group_id = ? AND user_id = ? AND (is_fixed = TRUE OR pair_date = ?) " ..
        "ORDER BY is_fixed DESC, wife_id ASC",
        { group_id, user_id, today })
    local out = {}
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                qq = math.floor(tonumber(r.wife_id) or 0),
                fixed = (r.is_fixed == true or tostring(r.is_fixed) == "true"),
            }
        end
    end
    return out
end

-- 是否已是自己的老婆
local function is_wife(group_id, user_id, wife_id, today)
    for _, w in ipairs(list_wives(group_id, user_id, today)) do
        if w.qq == wife_id then return true, w.fixed end
    end
    return false, false
end

-- 解析配置里的固定配对：{群号: {用户QQ: 老婆QQ}}
local function config_fixed_pairings()
    local raw = cfg_str("fixed_pairings", "{}")
    local ok, parsed = pcall(jn.json.decode, raw)
    if not ok or type(parsed) ~= "table" then
        return {}
    end
    return parsed
end

-- 把配置中的固定配对落库（幂等），返回是否命中
local function sync_config_fixed(group_id, user_id)
    local all = config_fixed_pairings()
    local group_map = all[tostring(group_id)] or all[group_id]
    if type(group_map) ~= "table" then return false end
    local wife = group_map[tostring(user_id)] or group_map[user_id]
    local wife_id = tonumber(wife)
    if not wife_id or wife_id <= 0 then return false end
    add_pairing(group_id, user_id, math.floor(wife_id), true, "")
    return true
end

-- 该用户配置中指定的固定老婆 QQ（仅配置，不含命令绑定）
local function config_fixed_wife(group_id, user_id)
    local all = config_fixed_pairings()
    local group_map = all[tostring(group_id)] or all[group_id]
    if type(group_map) ~= "table" then return nil end
    local wife = group_map[tostring(user_id)] or group_map[user_id]
    local wife_id = tonumber(wife)
    if not wife_id or wife_id <= 0 then return nil end
    return math.floor(wife_id)
end

-- 该用户在群内已绑定的固定老婆（配置 + 命令绑定）
local function fixed_wife_of(group_id, user_id, today)
    for _, w in ipairs(list_wives(group_id, user_id, today)) do
        if w.fixed then return w.qq end
    end
    return nil
end

-- 活跃群友池（active_days 天内发过言，排除自己与机器人）
local function active_pool(group_id, exclude_id, today)
    local days = cfg_num("active_days", 3)
    if days < 1 then days = 1 end
    local cutoff = os.time() - days * 86400
    local rows = jn.database.query(
        "SELECT user_id FROM " .. T_ACTIVE ..
        " WHERE group_id = ? AND last_seen >= ? ORDER BY last_seen DESC LIMIT 500",
        { group_id, cutoff })
    local pool = {}
    local bot = get_bot_uin()
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            local uid = math.floor(tonumber(r.user_id) or 0)
            if uid > 0 and uid ~= exclude_id and uid ~= bot then
                pool[#pool + 1] = uid
            end
        end
    end
    return pool
end

-- 群成员列表（全体成员，含不活跃）
local function all_members(group_id, exclude_id)
    local list = jn.onebot11.get_group_member_list(group_id)
    local out = {}
    local bot = get_bot_uin()
    if type(list) == "table" then
        for _, m in ipairs(list) do
            local uid = math.floor(tonumber(m.user_id) or 0)
            if uid > 0 and uid ~= exclude_id and uid ~= bot then
                out[#out + 1] = uid
            end
        end
    end
    return out
end

local function is_member(group_id, user_id)
    local info = jn.onebot11.get_group_member_info(group_id, user_id)
    return type(info) == "table" and (tonumber(info.user_id) or 0) > 0
end

-- ============================================================================
-- 4. 老婆列表展示
-- ============================================================================
local function format_wife_list(group_id, wives)
    local map = member_map(group_id)
    local names = {}
    for _, w in ipairs(wives) do
        local name = display_name(group_id, w.qq, map)
        if w.fixed then
            name = name .. "💍"
        end
        names[#names + 1] = name
    end
    return table.concat(names, "、")
end

local function show_wives(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local today = ensure_daily_reset(gid)
    sync_config_fixed(gid, uid)
    local wives = list_wives(gid, uid, today)
    if #wives == 0 then
        reply(event, tail("你现在还没有群老婆，发送 /随机老婆 抽一个吧"))
        return true
    end
    local at = { { type = "at", data = { qq = tostring(uid) } } }
    at[#at + 1] = { type = "text", data = { text = " 你现在的群老婆有：\n" } }
    at[#at + 1] = { type = "text", data = { text = format_wife_list(gid, wives) } }
    at[#at + 1] = { type = "text", data = { text = string.format("\n共 %d 位（💍 为固定永恒老婆）", #wives) } }
    if cfg_bool("enable_cat_tone", true) then
        at[#at + 1] = { type = "text", data = { text = " 喵~" } }
    end
    reply(event, at)
    return true
end

-- ============================================================================
-- 5. 随机 / 强娶 / 离婚
-- ============================================================================
local function do_random_wife(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local today = ensure_daily_reset(gid)
    sync_config_fixed(gid, uid)

    -- 固定配对优先：配置中指定了固定老婆，则直接使用
    local fixed = config_fixed_wife(gid, uid)
    if fixed then
        if not is_member(gid, fixed) then
            reply(event, tail(cfg_str("not_in_group_text", "你绑定的永恒老婆今天不在这个群里哦~")))
            return true
        end
        local exists = is_wife(gid, uid, fixed, today)
        if not exists then
            add_pairing(gid, uid, fixed, true, "")
        end
        local wives = list_wives(gid, uid, today)
        reply(event, {
            { type = "at", data = { qq = tostring(uid) } },
            { type = "text", data = { text = " 你的永恒老婆是：" .. display_name(gid, fixed) ..
                " 💍\n现在你的群老婆有：" .. format_wife_list(gid, wives) } },
            { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
        })
        return true
    end

    local ok, limit = consume_quota(gid, uid, "random", "max_random_count", today)
    if not ok then
        reply(event, tail(string.format("今天的随机老婆次数用完啦（上限 %d 次），明天再来吧", limit)))
        return true
    end

    local pool = active_pool(gid, uid, today)
    if #pool == 0 then
        reply(event, tail("群里最近没有活跃群友，先在群里聊聊天再来抽吧"))
        return true
    end

    -- 优先抽还没成为老婆的活跃群友
    local candidates = {}
    for _, qq in ipairs(pool) do
        local exists = is_wife(gid, uid, qq, today)
        if not exists then
            candidates[#candidates + 1] = qq
        end
    end
    if #candidates == 0 then
        reply(event, tail("群里的活跃群友都已经是你的老婆啦，试试 /强娶全体成员"))
        return true
    end

    local pick = candidates[math.random(#candidates)]
    add_pairing(gid, uid, pick, false, today)
    local wives = list_wives(gid, uid, today)
    reply(event, {
        { type = "at", data = { qq = tostring(uid) } },
        { type = "text", data = { text = " 今天的随机老婆是：" .. display_name(gid, pick) ..
            "\n现在你的群老婆有：" .. format_wife_list(gid, wives) } },
        { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
    })
    return true
end

local function do_force_marry(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local target = parse_target(args)
    if not target then
        reply(event, tail("用法：/强娶 @某人 或 /强娶 <QQ号>"))
        return true
    end
    local bot = get_bot_uin()
    if target == uid then
        reply(event, tail("不能强娶自己哦"))
        return true
    end
    if target == bot then
        reply(event, tail("我可不归你管哦"))
        return true
    end
    local today = ensure_daily_reset(gid)
    if not is_member(gid, target) then
        reply(event, tail("对方不在本群，强娶失败了"))
        return true
    end
    local ok, limit = consume_quota(gid, uid, "marry", "max_marry_count", today)
    if not ok then
        reply(event, tail(string.format("今天的强娶次数用完啦（上限 %d 次）", limit)))
        return true
    end
    add_pairing(gid, uid, target, false, today)
    local wives = list_wives(gid, uid, today)
    reply(event, {
        { type = "at", data = { qq = tostring(uid) } },
        { type = "text", data = { text = " 强娶成功！现在你的群老婆有：" .. format_wife_list(gid, wives) } },
        { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
    })
    return true
end

local function do_divorce(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local target = parse_target(args)
    if not target then
        reply(event, tail("用法：/离婚 @某人 或 /离婚 <QQ号>"))
        return true
    end
    local today = ensure_daily_reset(gid)
    local exists, fixed = is_wife(gid, uid, target, today)
    if not exists then
        reply(event, tail("对方不是你的老婆哦"))
        return true
    end
    if fixed then
        reply(event, tail("这是你的固定永恒老婆，普通离婚无效；如需解除请使用 /解除固定老婆 @对方（需双方同意或群管操作）"))
        return true
    end
    local ok, limit = consume_quota(gid, uid, "divorce", "max_divorce_count", today)
    if not ok then
        reply(event, tail(string.format("今天的离婚次数用完啦（上限 %d 次）", limit)))
        return true
    end
    remove_pairing(gid, uid, target, false, today)
    local wives = list_wives(gid, uid, today)
    if #wives == 0 then
        reply(event, {
            { type = "at", data = { qq = tostring(uid) } },
            { type = "text", data = { text = " 离婚成功！你现在没有群老婆了" } },
            { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
        })
    else
        reply(event, {
            { type = "at", data = { qq = tostring(uid) } },
            { type = "text", data = { text = " 离婚成功！现在你的群老婆有：" .. format_wife_list(gid, wives) } },
            { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
        })
    end
    return true
end

local function do_marry_all_active(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local today = ensure_daily_reset(gid)
    local ok, limit = consume_quota(gid, uid, "all_marry", "max_all_marry_count", today)
    if not ok then
        reply(event, tail(string.format("今天的「所有人都是我老婆」次数用完啦（上限 %d 次）", limit)))
        return true
    end
    local pool = active_pool(gid, uid, today)
    if #pool == 0 then
        reply(event, tail("群里最近没有活跃群友"))
        return true
    end
    local added = 0
    for _, qq in ipairs(pool) do
        local exists = is_wife(gid, uid, qq, today)
        if not exists then
            add_pairing(gid, uid, qq, false, today)
            added = added + 1
        end
    end
    local wives = list_wives(gid, uid, today)
    reply(event, {
        { type = "at", data = { qq = tostring(uid) } },
        { type = "text", data = { text = string.format(" 所有人都是你老婆啦！（新增 %d 位）\n现在你的群老婆有：", added) ..
            format_wife_list(gid, wives) } },
        { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
    })
    return true
end

local function do_force_marry_all(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local today = ensure_daily_reset(gid)
    local ok, limit = consume_quota(gid, uid, "force_all_marry", "max_force_all_marry_count", today)
    if not ok then
        reply(event, tail(string.format("今天的「强娶全体成员」次数用完啦（上限 %d 次）", limit)))
        return true
    end
    local members = all_members(gid, uid)
    if #members == 0 then
        reply(event, tail("获取群成员列表失败或群里没有其他成员"))
        return true
    end
    local added = 0
    for _, qq in ipairs(members) do
        local exists = is_wife(gid, uid, qq, today)
        if not exists then
            add_pairing(gid, uid, qq, false, today)
            added = added + 1
        end
    end
    local wives = list_wives(gid, uid, today)
    reply(event, {
        { type = "at", data = { qq = tostring(uid) } },
        { type = "text", data = { text = string.format(" 强娶全体成员成功！（新增 %d 位）\n现在你的群老婆有：", added) ..
            format_wife_list(gid, wives) } },
        { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
    })
    return true
end

local function do_divorce_all(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local today = ensure_daily_reset(gid)
    local ok, limit = consume_quota(gid, uid, "all_divorce", "max_all_divorce_count", today)
    if not ok then
        reply(event, tail(string.format("今天的「全部离婚」次数用完啦（上限 %d 次）", limit)))
        return true
    end
    local wives = list_wives(gid, uid, today)
    local removed = 0
    local kept = 0
    for _, w in ipairs(wives) do
        if w.fixed then
            kept = kept + 1
        else
            remove_pairing(gid, uid, w.qq, false, today)
            removed = removed + 1
        end
    end
    local msg = string.format(" 全部离婚成功！你解除了与 %d 位老婆的关系", removed)
    if kept > 0 then
        msg = msg .. string.format("（%d 位固定永恒老婆受保护，未解除）", kept)
    end
    if cfg_bool("enable_cat_tone", true) then msg = msg .. " 喵~" end
    reply(event, {
        { type = "at", data = { qq = tostring(uid) } },
        { type = "text", data = { text = msg } },
    })
    return true
end

-- ============================================================================
-- 6. 固定永恒配对（双向同意）
-- ============================================================================
local function do_fix_invite(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local target = parse_target(args)
    if not target then
        reply(event, tail("用法：/固定老婆 @某人 或 /固定老婆 <QQ号>"))
        return true
    end
    local bot = get_bot_uin()
    if target == uid then
        reply(event, tail("不能和自己绑定固定老婆哦"))
        return true
    end
    if target == bot then
        reply(event, tail("我可不归你管哦"))
        return true
    end
    local today = ensure_daily_reset(gid)
    if not is_member(gid, target) then
        reply(event, tail("对方不在本群，无法发起固定绑定"))
        return true
    end
    if fixed_wife_of(gid, uid, today) then
        reply(event, tail("你已经有固定永恒老婆了，先 /解除固定老婆 再重新绑定吧"))
        return true
    end
    if fixed_wife_of(gid, target, today) then
        reply(event, tail("对方已经有固定永恒老婆了"))
        return true
    end
    jn.cache.set(K_FIX_REQ .. ":" .. gid .. ":" .. target, { uid = tostring(uid) }, INVITE_TTL)
    reply(event, {
        { type = "at", data = { qq = tostring(target) } },
        { type = "text", data = { text = " " .. display_name(gid, uid) ..
            " 想和你结为固定永恒老婆！\n请在 " .. tostring(math.floor(INVITE_TTL / 60)) ..
            " 分钟内发送 /同意固定老婆 完成绑定，或 /拒绝固定老婆 婉拒。" } },
        { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
    })
    return true
end

local function do_fix_accept(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local key = K_FIX_REQ .. ":" .. gid .. ":" .. uid
    local entry = jn.cache.get(key)
    local inviter = type(entry) == "table" and tonumber(entry.uid) or nil
    if not inviter then
        reply(event, tail("你当前没有待确认的固定老婆邀请"))
        return true
    end
    inviter = math.floor(inviter)
    local today = ensure_daily_reset(gid)
    if not is_member(gid, inviter) then
        jn.cache.del(key)
        reply(event, tail("邀请方已不在本群，绑定取消"))
        return true
    end
    if fixed_wife_of(gid, uid, today) or fixed_wife_of(gid, inviter, today) then
        jn.cache.del(key)
        reply(event, tail("双方中已有一方存在固定永恒老婆，绑定取消"))
        return true
    end
    add_pairing(gid, uid, inviter, true, "")
    add_pairing(gid, inviter, uid, true, "")
    jn.cache.del(key)
    jn.cache.del(K_FIX_UNBIND .. ":" .. gid .. ":" .. inviter)
    reply(event, {
        { type = "text", data = { text = "💍 " .. display_name(gid, uid) .. " 与 " ..
            display_name(gid, inviter) .. " 已结为固定永恒老婆，每日重置也不会分离！" } },
        { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
    })
    return true
end

local function do_fix_reject(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local key = K_FIX_REQ .. ":" .. gid .. ":" .. uid
    local entry = jn.cache.get(key)
    local inviter = type(entry) == "table" and tonumber(entry.uid) or nil
    if not inviter then
        reply(event, tail("你当前没有待确认的固定老婆邀请"))
        return true
    end
    jn.cache.del(key)
    reply(event, {
        { type = "at", data = { qq = tostring(math.floor(inviter)) } },
        { type = "text", data = { text = " 对方婉拒了你的固定老婆邀请" } },
        { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
    })
    return true
end

-- 判断是否为群管理员/群主
local function is_group_admin(event)
    local uid = tostring(math.floor(tonumber(event.user_id) or 0))
    if type(event.admins) == "table" then
        for _, a in ipairs(event.admins) do
            if tostring(a) == uid then return true end
        end
    end
    local gid = tonumber(event.group_id) or 0
    local info = jn.onebot11.get_group_member_info(gid, tonumber(uid))
    if type(info) == "table" then
        local role = tostring(info.role or "")
        if role == "owner" or role == "admin" then return true end
    end
    return false
end

local function do_fix_unbind_request(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local target = parse_target(args)
    if not target then
        reply(event, tail("用法：/解除固定老婆 @某人 或 /解除固定老婆 <QQ号>"))
        return true
    end
    local today = ensure_daily_reset(gid)
    local mine = fixed_wife_of(gid, uid, today)
    if not mine or mine ~= target then
        reply(event, tail("对方不是你的固定永恒老婆"))
        return true
    end

    -- 群管可直接解绑
    if is_group_admin(event) then
        remove_pairing(gid, uid, target, true, today)
        remove_pairing(gid, target, uid, true, today)
        reply(event, tail("💔 已由群管解除 " .. display_name(gid, uid) .. " 与 " ..
            display_name(gid, target) .. " 的固定永恒配对"))
        return true
    end

    jn.cache.set(K_FIX_UNBIND .. ":" .. gid .. ":" .. target, { uid = tostring(uid) }, INVITE_TTL)
    reply(event, {
        { type = "at", data = { qq = tostring(target) } },
        { type = "text", data = { text = " " .. display_name(gid, uid) ..
            " 希望解除与你的固定永恒配对。\n请在 " .. tostring(math.floor(INVITE_TTL / 60)) ..
            " 分钟内发送 /同意解除固定老婆 确认，或忽略本条消息。" } },
        { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
    })
    return true
end

local function do_fix_unbind_accept(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local key = K_FIX_UNBIND .. ":" .. gid .. ":" .. uid
    local entry = jn.cache.get(key)
    local requester = type(entry) == "table" and tonumber(entry.uid) or nil
    if not requester then
        reply(event, tail("你当前没有待确认的解除固定老婆申请"))
        return true
    end
    requester = math.floor(requester)
    local today = ensure_daily_reset(gid)
    remove_pairing(gid, requester, uid, true, today)
    remove_pairing(gid, uid, requester, true, today)
    jn.cache.del(key)
    reply(event, {
        { type = "text", data = { text = "💔 " .. display_name(gid, uid) .. " 与 " ..
            display_name(gid, requester) .. " 的固定永恒配对已解除" } },
        { type = "text", data = { text = cfg_bool("enable_cat_tone", true) and " 喵~" or "" } },
    })
    return true
end

-- ============================================================================
-- 7. 老婆关系网（T2I 渲染）
-- ============================================================================
local graph_template = nil

local function get_graph_template()
    if graph_template == nil then
        local content, err = jn.file.read("templates/graph.html")
        if not content then
            jn.log.error("[" .. PLUGIN_NAME .. "] 读取关系网模板失败: " .. tostring(err))
            graph_template = ""
        else
            graph_template = content
        end
    end
    return graph_template
end

-- 收集本群当日全部配对（含固定），返回节点表与边表
local function collect_graph_data(group_id, today)
    local rows = jn.database.query(
        "SELECT user_id, wife_id, is_fixed FROM " .. T_PAIR ..
        " WHERE group_id = ? AND (is_fixed = TRUE OR pair_date = ?)",
        { group_id, today })
    local node_set = {}
    local node_order = {}
    local edges = {}
    local edge_seen = {}
    local fixed_edges = {}
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            local u = math.floor(tonumber(r.user_id) or 0)
            local w = math.floor(tonumber(r.wife_id) or 0)
            local is_fixed = (r.is_fixed == true or tostring(r.is_fixed) == "true")
            if u > 0 and w > 0 and u ~= w then
                if not node_set[u] then node_set[u] = true; node_order[#node_order + 1] = u end
                if not node_set[w] then node_set[w] = true; node_order[#node_order + 1] = w end
                local ekey = tostring(u) .. "->" .. tostring(w)
                if not edge_seen[ekey] then
                    edge_seen[ekey] = true
                    edges[#edges + 1] = { from = u, to = w, fixed = is_fixed }
                    if is_fixed then
                        fixed_edges[ekey] = true
                    end
                end
            end
        end
    end
    return node_order, edges, edge_seen, fixed_edges
end

local function safe_concat(list, sep)
    local n = #list
    if n == 0 then return "" end
    sep = sep or ""
    if n <= 512 then return table.concat(list, sep) end
    local chunks = {}
    for i = 1, n, 512 do
        chunks[#chunks + 1] = table.concat(list, sep, i, math.min(n, i + 511))
    end
    return safe_concat(chunks, sep)
end

local function avatar_url(qq)
    return string.format("https://q1.qlogo.cn/g?b=qq&nk=%d&s=100", qq)
end

local function analyze_graph(nodes, edges, edge_seen)
    local out_deg, in_deg, fixed_node = {}, {}, {}
    local out_list, in_list = {}, {}
    for _, qq in ipairs(nodes) do
        out_deg[qq], in_deg[qq] = 0, 0
        out_list[qq], in_list[qq] = {}, {}
    end
    for _, e in ipairs(edges) do
        out_deg[e.from] = (out_deg[e.from] or 0) + 1
        in_deg[e.to] = (in_deg[e.to] or 0) + 1
        table.insert(out_list[e.from], e.to)
        table.insert(in_list[e.to], e.from)
        if e.fixed then
            fixed_node[e.from] = true
            fixed_node[e.to] = true
        end
    end

    -- 识别「全员后宫/海王」广播节点：出边达到 >=12 且 >=35% 群人数时，其非双向/非固定边仅作汇总统计，避免几百条直线把图糊死
    local mega_thresh = math.max(12, math.floor(#nodes * 0.35))
    local mega_hubs = {}
    for _, qq in ipairs(nodes) do
        if (out_deg[qq] or 0) >= mega_thresh then
            mega_hubs[qq] = true
        end
    end

    local core_in_deg, core_in_list, core_deg = {}, {}, {}
    local core_edges, core_node_set = {}, {}
    local bi_pairs, bi_node_set = {}, {}
    local seen_bi = {}

    for _, e in ipairs(edges) do
        local a, b = e.from, e.to
        local rev = edge_seen[tostring(b) .. "->" .. tostring(a)] ~= nil
        if rev then
            bi_node_set[a], bi_node_set[b] = true, true
            local k = (a < b) and (tostring(a) .. "-" .. tostring(b)) or (tostring(b) .. "-" .. tostring(a))
            if not seen_bi[k] then
                seen_bi[k] = true
                local is_f = e.fixed or (edge_seen[tostring(b) .. "->" .. tostring(a)] == true and fixed_node[a] and fixed_node[b])
                bi_pairs[#bi_pairs + 1] = { a = a, b = b, fixed = e.fixed }
            end
        end

        if not mega_hubs[a] then
            core_in_deg[b] = (core_in_deg[b] or 0) + 1
            core_in_list[b] = core_in_list[b] or {}
            table.insert(core_in_list[b], a)
        end

        if (not mega_hubs[a]) or rev or e.fixed then
            core_edges[#core_edges + 1] = e
            core_node_set[a] = true
            core_node_set[b] = true
            core_deg[a] = (core_deg[a] or 0) + 1
            core_deg[b] = (core_deg[b] or 0) + 1
        end
    end

    local green_targets = {}
    local green_count = 0
    for _, qq in ipairs(nodes) do
        if (core_in_deg[qq] or 0) >= 2 then
            green_targets[qq] = true
            green_count = green_count + 1
        end
    end

    -- 仅保留参与核心关系网的节点，并按度数与 BFS 邻接顺序排列以减少连线交叉
    local core_nodes = {}
    for _, qq in ipairs(nodes) do
        if core_node_set[qq] then
            core_nodes[#core_nodes + 1] = qq
        end
    end
    table.sort(core_nodes, function(a, b)
        local da, db = core_deg[a] or 0, core_deg[b] or 0
        if da ~= db then return da > db end
        return a < b
    end)

    return {
        out_deg = out_deg,
        in_deg = in_deg,
        out_list = out_list,
        in_list = in_list,
        fixed_node = fixed_node,
        mega_hubs = mega_hubs,
        core_in_deg = core_in_deg,
        core_in_list = core_in_list,
        core_deg = core_deg,
        core_edges = core_edges,
        core_nodes = core_nodes,
        bi_pairs = bi_pairs,
        bi_node_set = bi_node_set,
        green_targets = green_targets,
        green_count = green_count,
    }
end

local function bfs_order_ring(nodes, edges)
    if #nodes <= 3 then return nodes end
    local in_sub = {}
    local adj = {}
    for _, qq in ipairs(nodes) do
        in_sub[qq] = true
        adj[qq] = {}
    end
    for _, e in ipairs(edges) do
        if in_sub[e.from] and in_sub[e.to] then
            table.insert(adj[e.from], e.to)
            table.insert(adj[e.to], e.from)
        end
    end
    local visited, ordered = {}, {}
    for _, start in ipairs(nodes) do
        if not visited[start] then
            local q = { start }
            visited[start] = true
            local qi = 1
            while qi <= #q do
                local cur = q[qi]
                qi = qi + 1
                ordered[#ordered + 1] = cur
                for _, nb in ipairs(adj[cur]) do
                    if not visited[nb] then
                        visited[nb] = true
                        q[#q + 1] = nb
                    end
                end
            end
        end
    end
    return ordered
end

local function build_summary_html(group_id, nodes, info, map)
    local cards = {}

    -- 1. 后宫 / 海王榜
    local harems = {}
    for _, qq in ipairs(nodes) do
        local od = info.out_deg[qq] or 0
        if od >= 2 then
            harems[#harems + 1] = { qq = qq, count = od, mega = info.mega_hubs[qq] == true }
        end
    end
    table.sort(harems, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.qq < b.qq
    end)
    if #harems > 0 then
        local rows = {}
        for i = 1, math.min(4, #harems) do
            local h = harems[i]
            local name = xml_escape(utf8_clip(display_name(group_id, h.qq, map), 10))
            local tag = h.mega and string.format('<span class="pill gold">全员后宫 %d 人</span>', h.count)
                or string.format('<span class="pill gold">娶了 %d 人</span>', h.count)
            rows[#rows + 1] = string.format(
                '<div class="spot-row"><img src="%s"/><span class="spot-name">%s</span><span class="spot-desc">%s</span>%s</div>',
                avatar_url(h.qq), name, h.mega and "广播连线已折叠，详见下方图鉴" or "多线操作中", tag)
        end
        cards[#cards + 1] = '<div class="spot-card harem"><div class="spot-title">👑 今日海王 / 后宫榜</div><div class="spot-list">'
            .. table.concat(rows, "") .. '</div></div>'
    end

    -- 2. 绿帽焦点榜（多位非全员群友娶走同一位）
    local greens = {}
    for _, qq in ipairs(nodes) do
        local gd = info.core_in_deg[qq] or 0
        if gd >= 2 then
            greens[#greens + 1] = { qq = qq, count = gd, suitors = info.core_in_list[qq] or {} }
        end
    end
    table.sort(greens, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.qq < b.qq
    end)
    if #greens > 0 then
        local rows = {}
        for i = 1, math.min(4, #greens) do
            local g = greens[i]
            local target_name = xml_escape(utf8_clip(display_name(group_id, g.qq, map), 9))
            local s_names = {}
            for k = 1, math.min(3, #g.suitors) do
                s_names[#s_names + 1] = xml_escape(utf8_clip(display_name(group_id, g.suitors[k], map), 6))
            end
            local desc = table.concat(s_names, "、") .. (#g.suitors > 3 and " 等" or "")
            rows[#rows + 1] = string.format(
                '<div class="spot-row"><img src="%s"/><span class="spot-name">%s</span><span class="spot-desc">追求者：%s</span><span class="pill green">💚 ×%d</span></div>',
                avatar_url(g.qq), target_name, desc, g.count)
        end
        cards[#cards + 1] = '<div class="spot-card green"><div class="spot-title">💚 绿帽焦点 / 人气老婆榜</div><div class="spot-list">'
            .. table.concat(rows, "") .. '</div></div>'
    end

    -- 3. 双向奔赴 / 永恒 CP
    if #info.bi_pairs > 0 then
        local rows = {}
        for i = 1, math.min(5, #info.bi_pairs) do
            local bp = info.bi_pairs[i]
            local na = xml_escape(utf8_clip(display_name(group_id, bp.a, map), 8))
            local nb = xml_escape(utf8_clip(display_name(group_id, bp.b, map), 8))
            rows[#rows + 1] = string.format(
                '<div class="spot-row"><img src="%s"/><span class="spot-desc"><strong>%s</strong> 💗 <strong>%s</strong></span><img src="%s"/>%s</div>',
                avatar_url(bp.a), na, nb, avatar_url(bp.b),
                bp.fixed and '<span class="pill">💍 永恒</span>' or '<span class="pill">双向</span>')
        end
        if #info.bi_pairs > 5 then
            rows[#rows + 1] = string.format('<div class="spot-row"><span class="spot-desc">… 共 %d 对双向奔赴</span></div>', #info.bi_pairs)
        end
        cards[#cards + 1] = '<div class="spot-card"><div class="spot-title">💗 双向奔赴 &amp; 永恒 CP</div><div class="spot-list">'
            .. table.concat(rows, "") .. '</div></div>'
    end

    if #cards == 0 then return "" end
    return '<div class="summary-section">' .. table.concat(cards, "\n") .. '</div>'
end

local function build_roster_html(group_id, nodes, info, map, core_shown_set)
    local has_mega = next(info.mega_hubs) ~= nil
    if (not has_mega) and #nodes <= 28 and #nodes == #info.core_nodes then
        return ""
    end

    local sorted = {}
    for _, qq in ipairs(nodes) do sorted[#sorted + 1] = qq end
    table.sort(sorted, function(a, b)
        local ma = info.mega_hubs[a] and 1 or 0
        local mb = info.mega_hubs[b] and 1 or 0
        if ma ~= mb then return ma > mb end
        local ba = info.bi_node_set[a] and 1 or 0
        local bb = info.bi_node_set[b] and 1 or 0
        if ba ~= bb then return ba > bb end
        local ga = info.green_targets[a] and 1 or 0
        local gb = info.green_targets[b] and 1 or 0
        if ga ~= gb then return ga > gb end
        local sa = (info.core_deg[a] or 0) + (info.in_deg[a] or 0)
        local sb = (info.core_deg[b] or 0) + (info.in_deg[b] or 0)
        if sa ~= sb then return sa > sb end
        return a < b
    end)

    local tiles = {}
    for _, qq in ipairs(sorted) do
        local name = xml_escape(utf8_clip(display_name(group_id, qq, map), 9))
        local cls = "member-tile"
        local meta = {}
        if info.mega_hubs[qq] then
            cls = "member-tile is-harem"
            meta[#meta + 1] = string.format("👑 后宫 %d", info.out_deg[qq] or 0)
        elseif info.bi_node_set[qq] then
            cls = "member-tile is-bi"
            meta[#meta + 1] = info.fixed_node[qq] and "💍 双向" or "💗 双向"
        elseif info.green_targets[qq] then
            cls = "member-tile is-green"
            meta[#meta + 1] = string.format("💚 ×%d", info.core_in_deg[qq] or 0)
        end
        local od = info.out_deg[qq] or 0
        local id_cnt = info.in_deg[qq] or 0
        if #meta == 0 then
            if od > 0 and id_cnt > 0 then
                meta[#meta + 1] = string.format("娶%d · 被娶%d", od, id_cnt)
            elseif od > 0 then
                meta[#meta + 1] = string.format("娶了 %d 位", od)
            else
                meta[#meta + 1] = string.format("被 %d 人娶", id_cnt)
            end
        elseif not info.mega_hubs[qq] then
            meta[#meta + 1] = string.format("被娶%d", id_cnt)
        end
        tiles[#tiles + 1] = string.format(
            '<div class="%s"><img src="%s"/><div class="member-name">%s</div><div class="member-meta">%s</div></div>',
            cls, avatar_url(qq), name, table.concat(meta, " · "))
    end

    local sub = has_mega and "已折叠全员后宫广播直线，所有参与群友与配对状态一目了然" or "全群参与成员完整一览"
    return '<div class="roster-section"><div class="roster-head"><span>👥 群友配对图鉴（共 '
        .. tostring(#sorted) .. ' 人）</span><span class="roster-sub">' .. sub
        .. '</span></div><div class="roster-grid">' .. safe_concat(tiles, "\n") .. '</div></div>'
end

-- 生成清晰无重叠关系拓扑 SVG（支持单环外置标签 & 大人数同心多环自适应）
local function build_svg(group_id, nodes, edges, edge_seen, fixed_edges)
    local map = member_map(group_id)
    local info = analyze_graph(nodes, edges, edge_seen)
    local summary_html = build_summary_html(group_id, nodes, info, map)

    local core_nodes = info.core_nodes
    local m = #core_nodes
    if m == 0 then
        local empty_tip = '<div class="empty-tip">当前配对均为「全员后宫」展开，已在上方后宫榜与下方群友图鉴中清晰汇总，省略密集交叉线以保持可读性。</div>'
        local roster_html = build_roster_html(group_id, nodes, info, map, {})
        return empty_tip, summary_html, roster_html, info.green_count
    end

    local W = 1220
    local A, H
    local pos = {}
    local shown_nodes = {}
    local shown_set = {}
    local max_svg_nodes = 74

    if m <= 28 then
        local ordered = bfs_order_ring(core_nodes, info.core_edges)
        shown_nodes = ordered
        A = math.floor(1320 / math.max(m, 1))
        if A > 72 then A = 72 end
        if A < 46 then A = 46 end
        local min_R = math.floor(m * (A + 34) / (2 * math.pi))
        local R = math.max(165, math.min(410, min_R))
        local margin = A / 2 + 120
        H = math.max(460, math.floor(2 * (R + margin)))
        local cx, cy = W / 2, H / 2
        if m == 1 then
            pos[ordered[1]] = { x = cx, y = cy, ring = 1, ang = -math.pi / 2 }
        else
            for i, qq in ipairs(ordered) do
                local ang = -math.pi / 2 + 2 * math.pi * (i - 1) / m
                pos[qq] = {
                    x = cx + R * math.cos(ang),
                    y = cy + R * math.sin(ang),
                    ring = 1,
                    ang = ang,
                    outward = true,
                }
            end
        end
    else
        -- 大人数：同心多环，保证弧长间距 >= A + 16px，绝不堆叠头像
        local cap = math.min(m, max_svg_nodes)
        for i = 1, cap do
            shown_nodes[#shown_nodes + 1] = core_nodes[i]
        end
        A = 44
        local ring_defs = {
            { r = 165, cap = 12, outward = false },
            { r = 325, cap = 24, outward = false },
            { r = 485, cap = 38, outward = true },
        }
        H = 1180
        local cx, cy = W / 2, H / 2
        local idx = 1
        for r_idx, rd in ipairs(ring_defs) do
            local remaining = #shown_nodes - idx + 1
            if remaining <= 0 then break end
            local take = math.min(rd.cap, remaining)
            local slice = {}
            for k = 1, take do
                slice[#slice + 1] = shown_nodes[idx]
                idx = idx + 1
            end
            slice = bfs_order_ring(slice, info.core_edges)
            local offset_ang = (r_idx % 2 == 0) and (math.pi / math.max(take, 1)) or 0
            for k, qq in ipairs(slice) do
                local ang = -math.pi / 2 + offset_ang + 2 * math.pi * (k - 1) / take
                pos[qq] = {
                    x = cx + rd.r * math.cos(ang),
                    y = cy + rd.r * math.sin(ang),
                    ring = r_idx,
                    ang = ang,
                    outward = rd.outward,
                }
            end
        end
    end
    for _, qq in ipairs(shown_nodes) do shown_set[qq] = true end

    local parts = {}
    parts[#parts + 1] = string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">',
        W, H, W, H)
    parts[#parts + 1] = [[<defs>]]
    parts[#parts + 1] = [[<marker id="arrow-blue" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M0,1 L10,5 L0,9 z" fill="#60A5FA"/></marker>]]
    parts[#parts + 1] = [[<marker id="arrow-green" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse"><path d="M0,1 L10,5 L0,9 z" fill="#10B981"/></marker>]]
    parts[#parts + 1] = [[<marker id="arrow-red" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse"><path d="M0,1 L10,5 L0,9 z" fill="#E11D48"/></marker>]]
    for _, qq in ipairs(shown_nodes) do
        parts[#parts + 1] = string.format(
            '<clipPath id="clip%d"><circle cx="%.1f" cy="%.1f" r="%.1f"/></clipPath>',
            qq, pos[qq].x, pos[qq].y, A / 2)
    end
    parts[#parts + 1] = [[</defs>]]

    -- 连线：普通细弧线 -> 绿帽高亮弧线 -> 固定线 -> 双向粉色粗弧线（分层叠加，焦点清晰）
    local drawn_bi = {}
    local line_layers = { normal = {}, green = {}, fixed = {}, bi = {} }
    for _, e in ipairs(info.core_edges) do
        local a, b = e.from, e.to
        local p1, p2 = pos[a], pos[b]
        if p1 and p2 then
            local rev = edge_seen[tostring(b) .. "->" .. tostring(a)] ~= nil
            local dx, dy = p2.x - p1.x, p2.y - p1.y
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 1 then
                local ux, uy = dx / len, dy / len
                local off = A / 2 + 5
                local sx, sy = p1.x + off * ux, p1.y + off * uy
                local ex, ey = p2.x - off * ux, p2.y - off * uy
                local mx, my = (sx + ex) / 2, (sy + ey) / 2
                local nx, ny = -uy, ux

                if rev then
                    local pk = (a < b) and (tostring(a) .. "-" .. tostring(b)) or (tostring(b) .. "-" .. tostring(a))
                    if not drawn_bi[pk] then
                        drawn_bi[pk] = true
                        local bow = math.max(26, math.min(90, len * 0.16))
                        local ctrlx, ctrly = mx + nx * bow, my + ny * bow
                        line_layers.bi[#line_layers.bi + 1] = string.format(
                            '<path d="M%.1f,%.1f Q%.1f,%.1f %.1f,%.1f" fill="none" stroke="#FF4081" stroke-width="3.5" stroke-linecap="round" opacity="0.92"/>',
                            sx, sy, ctrlx, ctrly, ex, ey)
                        local hx, hy = (sx + 2 * ctrlx + ex) / 4, (sy + 2 * ctrly + ey) / 4
                        line_layers.bi[#line_layers.bi + 1] = string.format(
                            '<text x="%.1f" y="%.1f" font-size="20" text-anchor="middle" dominant-baseline="central">💗</text>',
                            hx, hy)
                    end
                else
                    local is_green = info.green_targets[b] == true
                    local bow = math.min(48, math.max(12, len * 0.08))
                    local ctrlx, ctrly = mx + nx * bow, my + ny * bow
                    if e.fixed then
                        line_layers.fixed[#line_layers.fixed + 1] = string.format(
                            '<path d="M%.1f,%.1f Q%.1f,%.1f %.1f,%.1f" fill="none" stroke="#E11D48" stroke-width="2.6" marker-end="url(#arrow-red)" opacity="0.88"/>',
                            sx, sy, ctrlx, ctrly, ex, ey)
                    elseif is_green then
                        line_layers.green[#line_layers.green + 1] = string.format(
                            '<path d="M%.1f,%.1f Q%.1f,%.1f %.1f,%.1f" fill="none" stroke="#10B981" stroke-width="2.3" marker-end="url(#arrow-green)" opacity="0.82"/>',
                            sx, sy, ctrlx, ctrly, ex, ey)
                    else
                        line_layers.normal[#line_layers.normal + 1] = string.format(
                            '<path d="M%.1f,%.1f Q%.1f,%.1f %.1f,%.1f" fill="none" stroke="#60A5FA" stroke-width="1.8" marker-end="url(#arrow-blue)" opacity="0.55"/>',
                            sx, sy, ctrlx, ctrly, ex, ey)
                    end
                end
            end
        end
    end
    for _, layer in ipairs({ line_layers.normal, line_layers.green, line_layers.fixed, line_layers.bi }) do
        for _, item in ipairs(layer) do parts[#parts + 1] = item end
    end

    -- 节点：头像圆 + 绿帽/固定角标 + 防遮挡外置/描边昵称
    for _, qq in ipairs(shown_nodes) do
        local p = pos[qq]
        local name = utf8_clip(display_name(group_id, qq, map), 7)
        local is_fixed = info.fixed_node[qq] == true
        local is_green = info.green_targets[qq] == true
        local is_bi = info.bi_node_set[qq] == true

        local ring_color = "#F9A8D4"
        local ring_w = 3
        if is_green then
            ring_color = "#10B981"
            ring_w = 4.5
        elseif is_fixed or is_bi then
            ring_color = "#FF4081"
            ring_w = 4.5
        end

        parts[#parts + 1] = string.format(
            '<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#FCE4EC"/>',
            p.x, p.y, A / 2)
        parts[#parts + 1] = string.format(
            '<image href="%s" x="%.1f" y="%.1f" width="%d" height="%d" clip-path="url(#clip%d)" preserveAspectRatio="xMidYMid slice"/>',
            avatar_url(qq), p.x - A / 2, p.y - A / 2, A, A, qq)
        parts[#parts + 1] = string.format(
            '<circle cx="%.1f" cy="%.1f" r="%.1f" fill="none" stroke="%s" stroke-width="%s"/>',
            p.x, p.y, A / 2, ring_color, tostring(ring_w))

        if is_green then
            parts[#parts + 1] = string.format(
                '<rect x="%.1f" y="%.1f" width="32" height="16" rx="8" fill="#10B981" stroke="#fff" stroke-width="1.5"/>'
                    .. '<text x="%.1f" y="%.1f" font-size="10" font-weight="700" fill="#fff" text-anchor="middle" dominant-baseline="central">💚%d</text>',
                p.x + A / 2 - 22, p.y - A / 2 - 4,
                p.x + A / 2 - 6, p.y - A / 2 + 4, info.core_in_deg[qq] or 2)
        elseif is_fixed then
            parts[#parts + 1] = string.format(
                '<text x="%.1f" y="%.1f" font-size="15" text-anchor="middle">💍</text>',
                p.x + A / 2 - 4, p.y - A / 2 + 6)
        elseif info.mega_hubs[qq] then
            parts[#parts + 1] = string.format(
                '<text x="%.1f" y="%.1f" font-size="15" text-anchor="middle">👑</text>',
                p.x + A / 2 - 4, p.y - A / 2 + 6)
        end

        local lx, ly, anchor
        if p.outward and p.ang then
            local ca, sa = math.cos(p.ang), math.sin(p.ang)
            local dist = A / 2 + 11
            lx = p.x + dist * ca
            ly = p.y + dist * sa + 4
            if ca > 0.25 then anchor = "start"
            elseif ca < -0.25 then anchor = "end"
            else
                anchor = "middle"
                ly = (sa >= 0) and (p.y + A / 2 + 16) or (p.y - A / 2 - 8)
            end
        else
            lx, ly, anchor = p.x, p.y + A / 2 + 15, "middle"
        end
        parts[#parts + 1] = string.format(
            '<text x="%.1f" y="%.1f" font-size="13" font-weight="700" fill="#1E293B" text-anchor="%s" paint-order="stroke" stroke="#FFFFFF" stroke-width="4" stroke-linejoin="round">%s</text>',
            lx, ly, anchor, xml_escape(name))
    end

    parts[#parts + 1] = "</svg>"
    local roster_html = build_roster_html(group_id, nodes, info, map, shown_set)
    return safe_concat(parts, "\n"), summary_html, roster_html, info.green_count
end

local function do_graph(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local today = ensure_daily_reset(gid)
    local ok, limit = consume_quota(gid, uid, "graph", "max_relationship_graph_count", today)
    if not ok then
        reply(event, tail(string.format("本群今天的关系网生成次数用完啦（上限 %d 次）", limit)))
        return true
    end
    if not jn.t2i or not jn.t2i.is_active() then
        reply(event, tail("当前未启用 T2I 渲染服务，无法生成关系网图"))
        return true
    end
    local nodes, edges, edge_seen, fixed_edges = collect_graph_data(gid, today)
    if #edges == 0 then
        reply(event, tail("本群今天还没有任何老婆配对，先 /随机老婆 抽一个吧"))
        return true
    end
    local bi_count = 0
    local seen_pair = {}
    for _, e in ipairs(edges) do
        if edge_seen[tostring(e.to) .. "->" .. tostring(e.from)] then
            local k = (e.from < e.to) and (tostring(e.from) .. "-" .. tostring(e.to))
                or (tostring(e.to) .. "-" .. tostring(e.from))
            if not seen_pair[k] then
                seen_pair[k] = true
                bi_count = bi_count + 1
            end
        end
    end

    local tpl = get_graph_template()
    if tpl == "" then
        reply(event, tail("关系网模板读取失败"))
        return true
    end

    local group_name = "本群"
    local info = jn.onebot11.get_group_info(gid)
    if type(info) == "table" and info.group_name and tostring(info.group_name) ~= "" then
        group_name = tostring(info.group_name)
    end

    local svg, summary_html, extra_html, green_count = build_svg(gid, nodes, edges, edge_seen, fixed_edges)
    local html = tpl
        :gsub("__GROUP_NAME__", function() return xml_escape(group_name) end)
        :gsub("__GROUP_ID__", function() return tostring(gid) end)
        :gsub("__DATE__", function() return today end)
        :gsub("__NODE_COUNT__", function() return tostring(#nodes) end)
        :gsub("__EDGE_COUNT__", function() return tostring(#edges) end)
        :gsub("__GREEN_COUNT__", function() return tostring(green_count) end)
        :gsub("__BI_COUNT__", function() return tostring(bi_count) end)
        :gsub("__GEN_TIME__", function() return os.date("%Y-%m-%d %H:%M:%S") end)
        :gsub("__SUMMARY_HTML__", function() return summary_html end)
        :gsub("__SVG_CONTENT__", function() return svg end)
        :gsub("__EXTRA_HTML__", function() return extra_html end)

    local url, err = jn.t2i.generate_url(html, {
        viewport_width = 1280,
        viewport_height = 400,
        full_page = true, -- 整页截图：高度随内容自适应，避免底部空白
        -- 注意：该 timeout 单位是毫秒（Playwright 原样透传），
        -- 写成 60 会被当成 60ms 而必然超时；此处给 60s 供大量头像加载。
        timeout = 60000,
    })
    if not url then
        jn.log.error("[" .. PLUGIN_NAME .. "] 关系网渲染失败: " .. tostring(err))
        reply(event, tail("关系网渲染失败了，稍后再试试"))
        return true
    end
    reply(event, { { type = "image", data = { file = url } } })
    return true
end

-- ============================================================================
-- 8. 消息事件：活跃群友记录
-- ============================================================================
function on_message(event)
    if not event or event.message_type ~= "group" then
        return false, nil
    end
    local gid = math.floor(tonumber(event.group_id) or 0)
    if gid <= 0 or not is_enabled_group(gid) then
        return false, nil
    end
    local uid = math.floor(tonumber(event.user_id) or 0)
    if uid <= 0 or uid == get_bot_uin() then
        return false, nil
    end

    -- 节流：同一用户 ACTIVE_THROTTLE 秒内只落库一次
    local key = "act:" .. gid .. ":" .. uid
    if jn.cache.exists(key) > 0 then
        return false, nil
    end
    jn.cache.set(key, "1", ACTIVE_THROTTLE)

    local sender = event.sender or {}
    local nickname = tostring(sender.card or "")
    if nickname == "" then nickname = tostring(sender.nickname or "") end

    local _, db_err = jn.database.exec(
        "INSERT INTO " .. T_ACTIVE .. " (group_id, user_id, nickname, last_seen) VALUES (?, ?, ?, ?) " ..
        "ON CONFLICT (group_id, user_id) DO UPDATE SET nickname = EXCLUDED.nickname, last_seen = EXCLUDED.last_seen",
        { gid, uid, nickname, os.time() })
    if db_err then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 活跃记录写入失败: " .. tostring(db_err))
    end
    return false, nil
end

-- ============================================================================
-- 9. 定时清理
-- ============================================================================
local function cleanup()
    local days = cfg_num("active_days", 3)
    if days < 1 then days = 1 end
    -- 活跃记录保留 active_days*2 天
    local cutoff = os.time() - days * 2 * 86400
    local n1 = jn.database.exec(
        "DELETE FROM " .. T_ACTIVE .. " WHERE last_seen < ?", { cutoff })
    -- 非固定配对与次数保留 7 天
    local keep_date = os.date("%Y-%m-%d", os.time() - 7 * 86400)
    local n2 = jn.database.exec(
        "DELETE FROM " .. T_PAIR .. " WHERE is_fixed = FALSE AND pair_date <> '' AND pair_date < ?",
        { keep_date })
    local n3 = jn.database.exec(
        "DELETE FROM " .. T_COUNT .. " WHERE stat_date < ?", { keep_date })
    jn.log.info(string.format("[%s] 定时清理完成: 活跃=%s 配对=%s 次数=%s",
        PLUGIN_NAME, tostring(n1 or 0), tostring(n2 or 0), tostring(n3 or 0)))
end

function on_timer_response(req_id, ctx, result, err)
    if err then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 定时任务异常: " .. tostring(err))
    end
    if type(ctx) == "table" and ctx.action == "cleanup" then
        pcall(cleanup)
    end
    -- 重新挂载下一次清理
    if jn.timer and jn.timer.after then
        state.timer_id = jn.timer.after(CLEAN_INTERVAL, { action = "cleanup" })
    end
end

-- ============================================================================
-- 10. 命令注册
-- ============================================================================
-- 指令前置校验：
--   true  → 放行
--   false → 静默消费（冷却中，避免刷屏）
--   nil   → 不消费，交还 Agent 处理（私聊或未启用群）
local function guard(event)
    local gid = tonumber(event.group_id) or 0
    if gid <= 0 then
        return nil
    end
    if not is_enabled_group(gid) then
        return nil
    end
    if not check_cooldown(gid, math.floor(tonumber(event.user_id) or 0)) then
        return false
    end
    return true
end

local function reg(paths, handler)
    for _, p in ipairs(paths) do
        jn.command.register(p, function(args, event)
            local g = guard(event)
            if g == nil then
                return false
            end
            if g == false then
                return true
            end
            local ok, err = pcall(handler, args, event)
            if not ok then
                jn.log.error("[" .. PLUGIN_NAME .. "] 指令 " .. p .. " 执行异常: " .. tostring(err))
                reply(event, tail("指令执行出错了，请稍后再试"))
            end
            return true
        end, { description = "今日老婆：" .. paths[1] })
    end
end

reg({ "今日老婆", "查老婆", "我的老婆" }, show_wives)
reg({ "随机老婆", "娶老婆", "抽老婆" }, do_random_wife)
reg({ "强娶" }, do_force_marry)
reg({ "离婚", "休妻" }, do_divorce)
reg({ "所有人都是我老婆", "全都要" }, do_marry_all_active)
reg({ "强娶全体成员", "全员老婆" }, do_force_marry_all)
reg({ "全部离婚", "净身出户" }, do_divorce_all)
reg({ "老婆关系网", "绿帽图", "本群关系" }, do_graph)
reg({ "固定老婆" }, do_fix_invite)
reg({ "同意固定老婆" }, do_fix_accept)
reg({ "拒绝固定老婆" }, do_fix_reject)
reg({ "解除固定老婆" }, do_fix_unbind_request)
reg({ "同意解除固定老婆" }, do_fix_unbind_accept)

-- ============================================================================
-- 11. 启动
-- ============================================================================
init_db()
if jn.timer and jn.timer.after then
    state.timer_id = jn.timer.after(CLEAN_INTERVAL, { action = "cleanup" })
end
jn.log.info("[" .. PLUGIN_NAME .. "] 今日老婆插件已加载：随机/强娶/离婚/关系网/固定永恒配对")
