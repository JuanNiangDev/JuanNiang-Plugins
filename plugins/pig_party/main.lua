-- ============================================================================
-- pig_party: 猪猪派对（今日小猪 / 随机猪图 / 含猪字自动回复）
-- 作者: Churnie HXCN
-- 复刻自: astrbot_plugin_pig_party（专为 JuanNiang-Neo 架构深度定制）
--
-- 设计要点：
--   * 不合成卡片，直接发送图床/PigHub 原图（GIF 亦按原格式发送）
--   * 今日小猪按「用户 + 逻辑日期」稳定哈希，全天不变（结果落 Redis）
--   * 随机猪图带群内最近去重队列（Redis），避免短时间重复刷屏
--   * 含猪字自动回复默认关闭，开启后受「群白名单 + 概率 + 群冷却」三重保护
--   * 图池 = 卷娘图床目录（可多个）+ 自定义外链（可多条）
--
-- 指令：
--   /今日小猪 /抽小猪 /我的小猪    抽取或查看自己的今日小猪
--   /今日小猪 @某人                查看他人今日小猪（受 at_view_pig 开关）
--   /随机小猪 /随机猪猪 /猪猪      随机发送一张猪图
-- ============================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

local PLUGIN_NAME = "pig_party"

local K_POOL = "pool:v1"     -- 图池缓存
local K_DAILY = "daily"      -- daily:<gid>:<uid>:<date> = {ref,name}
local K_RECENT = "recent"    -- recent:<gid> = {list={ref,...}}
local K_ARCD = "arcd"        -- 自动回复群冷却
local K_CDG = "cd:g"         -- 指令群冷却
local K_CDU = "cd:u"         -- 指令用户冷却

local DAILY_TTL = 86400      -- 今日小猪缓存（跨日自动失效）
local RECENT_TTL = 3600      -- 去重队列有效期

-- 前向声明
local reply
local logical_date
local get_pool

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

-- 列表配置：兼容 table 与逗号分隔字符串
local function cfg_list(key)
    local raw = jn.config.get(key)
    local out = {}
    if type(raw) == "table" then
        for _, v in pairs(raw) do
            local s = tostring(v or ""):match("^%s*(.-)%s*$")
            if s ~= "" then out[#out + 1] = s end
        end
    elseif type(raw) == "string" then
        for item in raw:gmatch("[^,，%s]+") do
            out[#out + 1] = item
        end
    end
    return out
end

-- 启用群列表：留空表示所有群生效
local function is_enabled_group(group_id)
    local gid = tonumber(group_id) or 0
    if gid <= 0 then return false end
    local list = cfg_list("enable_groups")
    if #list == 0 then return true end
    for _, v in ipairs(list) do
        if v == "*" then return true end
        if tonumber(v) == gid then return true end
    end
    return false
end

-- ============================================================================
-- 2. 基础工具
-- ============================================================================
function logical_date()
    return os.date("%Y-%m-%d")
end

function reply(event, message)
    local gid = tonumber(event.group_id) or 0
    if gid > 0 then
        return jn.onebot11.send_group_msg(gid, message)
    end
    return jn.onebot11.send_private_msg(tonumber(event.user_id) or 0, message)
end

-- djb2 哈希：用于「今日小猪」的稳定抽取（Lua number 为 double，2^32 内运算精确）
local function hash32(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return h
end

local function get_bot_uin()
    local info = jn.onebot11.get_login_info()
    if type(info) == "table" and info.user_id then
        return math.floor(tonumber(info.user_id) or 0)
    end
    return 0
end

-- 从参数中解析目标 QQ（@某人 或 直接 QQ 号）
local function parse_target(args)
    local joined = table.concat(args or {}, " ")
    if joined == "" then return nil end
    local qq = joined:match("%[CQ:at,qq=(%d+)%]")
    if qq then return tonumber(qq) end
    qq = joined:match("(%d+)")
    if qq then return tonumber(qq) end
    return nil
end

local function display_name(group_id, user_id)
    local info = jn.onebot11.get_group_member_info(group_id, user_id)
    if type(info) == "table" then
        local name = tostring(info.card or "")
        if name == "" then name = tostring(info.nickname or "") end
        if name ~= "" then return name end
    end
    return tostring(user_id)
end

-- ============================================================================
-- 3. 图池（卷娘图床目录 + 自定义外链）
-- ============================================================================
local function build_pool()
    local entries = {}
    local folders = cfg_list("image_bed_folders")
    if jn.images ~= nil then
        for _, folder in ipairs(folders) do
            local ok, list = pcall(jn.images.list, folder)
            if ok and type(list) == "table" then
                for _, a in ipairs(list) do
                    local id = tostring(a.id or "")
                    if id ~= "" then
                        entries[#entries + 1] = {
                            ref = "imgs://" .. id,
                            name = tostring(a.name or ""),
                        }
                    end
                end
            else
                jn.log.warn("[" .. PLUGIN_NAME .. "] 图床目录读取失败: " .. tostring(folder))
            end
        end
    end

    for _, item in ipairs(cfg_list("custom_pig_images")) do
        local name, url = item:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
        if name and url and url ~= "" then
            entries[#entries + 1] = { ref = url, name = name }
        else
            local url2 = item:match("^%s*(.-)%s*$")
            if url2 ~= "" then
                local base = url2:match("([^/]+)$") or url2
                entries[#entries + 1] = { ref = url2, name = base }
            end
        end
    end

    -- 去重 + 稳定排序：保证同一图池下「今日小猪」的哈希结果稳定
    local seen = {}
    local out = {}
    for _, e in ipairs(entries) do
        if e.ref ~= "" and not seen[e.ref] then
            seen[e.ref] = true
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b) return a.ref < b.ref end)
    return out
end

function get_pool()
    local ttl = cfg_num("pool_cache_seconds", 300)
    if ttl > 0 then
        local cached = jn.cache.get(K_POOL)
        if type(cached) == "table" and type(cached.list) == "table" and #cached.list > 0 then
            local out = {}
            for _, e in ipairs(cached.list) do
                if type(e) == "table" and tostring(e.ref or "") ~= "" then
                    out[#out + 1] = { ref = tostring(e.ref), name = tostring(e.name or "") }
                end
            end
            if #out > 0 then return out end
        end
    end
    local pool = build_pool()
    if ttl > 0 and #pool > 0 then
        jn.cache.set(K_POOL, { list = pool }, ttl)
    end
    return pool
end

-- 今日小猪：优先 Redis 中当天已定结果，未命中则稳定哈希抽取
local function daily_pick(group_id, user_id, pool)
    local key = K_DAILY .. ":" .. group_id .. ":" .. user_id .. ":" .. logical_date()
    local cached = jn.cache.get(key)
    if type(cached) == "table" and tostring(cached.ref or "") ~= "" then
        for _, e in ipairs(pool) do
            if e.ref == cached.ref then
                return e
            end
        end
    end
    local idx = hash32(user_id .. ":" .. logical_date()) % #pool + 1
    local pick = pool[idx]
    jn.cache.set(key, { ref = pick.ref, name = pick.name }, DAILY_TTL)
    return pick
end

-- 随机猪图：避开本群最近发送过的图
local function random_pick(group_id, pool)
    local limit = cfg_num("random_recent_limit", 8)
    local recent = {}
    if limit > 0 then
        local cached = jn.cache.get(K_RECENT .. ":" .. group_id)
        if type(cached) == "table" and type(cached.list) == "table" then
            for _, r in ipairs(cached.list) do
                recent[tostring(r)] = true
            end
        end
    end
    local candidates = {}
    for _, e in ipairs(pool) do
        if not recent[e.ref] then
            candidates[#candidates + 1] = e
        end
    end
    if #candidates == 0 then
        candidates = pool
    end
    local pick = candidates[math.random(#candidates)]

    if limit > 0 then
        local list = { pick.ref }
        for ref in pairs(recent) do
            if ref ~= pick.ref and #list < limit then
                list[#list + 1] = ref
            end
        end
        jn.cache.set(K_RECENT .. ":" .. group_id, { list = list }, RECENT_TTL)
    end
    return pick
end

local function send_pig(event, entry, with_name)
    local msg = { { type = "image", data = { file = entry.ref } } }
    if with_name and entry.name ~= "" then
        msg[#msg + 1] = { type = "text", data = { text = "🐷 " .. entry.name } }
    end
    reply(event, msg)
end

-- ============================================================================
-- 4. 指令实现
-- ============================================================================
local function do_daily_pig(args, event)
    local gid = tonumber(event.group_id) or 0
    local uid = math.floor(tonumber(event.user_id) or 0)
    local target = parse_target(args)
    if target and target ~= uid then
        if not cfg_bool("at_view_pig", true) then
            reply(event, "看别人的今日小猪功能没开哦")
            return true
        end
        local info = jn.onebot11.get_group_member_info(gid, target)
        if type(info) ~= "table" or (tonumber(info.user_id) or 0) == 0 then
            reply(event, "对方不在本群")
            return true
        end
        uid = target
    end

    local pool = get_pool()
    if #pool == 0 then
        reply(event, "图库里还没有猪图，请先在后台配置图床目录或添加图片外链")
        return true
    end
    local pick = daily_pick(gid, uid, pool)
    send_pig(event, pick, true)
    return true
end

local function do_random_pig(args, event)
    local gid = tonumber(event.group_id) or 0
    local pool = get_pool()
    if #pool == 0 then
        reply(event, "图库里还没有猪图，请先在后台配置图床目录或添加图片外链")
        return true
    end
    local pick = random_pick(gid, pool)
    send_pig(event, pick, false)
    return true
end

-- ============================================================================
-- 5. 含猪字自动回复（默认关闭）
-- ============================================================================
local function contains_keyword(raw)
    local raw_cfg = cfg_str("pig_trigger_keywords", "猪,🐷,🐖,🐽")
    for kw in raw_cfg:gmatch("[^,，]+") do
        local k = kw:match("^%s*(.-)%s*$")
        if k ~= "" and raw:find(k, 1, true) then
            return true
        end
    end
    return false
end

function on_message(event)
    if not event or event.message_type ~= "group" then
        return false, nil
    end
    if not cfg_bool("auto_reply_pig_messages", false) then
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
    local raw = tostring(event.raw_message or "")
    if raw == "" or raw:sub(1, 1) == "/" then
        return false, nil
    end
    if not contains_keyword(raw) then
        return false, nil
    end

    -- 概率控制
    local prob = cfg_num("auto_reply_probability", 50)
    if prob <= 0 then
        return false, nil
    end
    if prob < 100 and math.random(100) > prob then
        return false, nil
    end

    -- 群冷却
    local cd = cfg_num("auto_reply_cooldown_seconds", 15)
    local ckey = K_ARCD .. ":" .. gid
    if cd > 0 then
        if jn.cache.exists(ckey) > 0 then
            return false, nil
        end
        jn.cache.set(ckey, "1", cd)
    end

    local pool = get_pool()
    if #pool == 0 then
        return false, nil
    end
    send_pig(event, random_pick(gid, pool), false)
    return false, nil
end

-- ============================================================================
-- 6. 指令注册
-- ============================================================================
-- 指令冷却：true=放行 / false=静默消费 / nil=不消费交还 Agent
local function guard(event)
    local gid = tonumber(event.group_id) or 0
    if gid <= 0 or not is_enabled_group(gid) then
        return nil
    end
    local uid = math.floor(tonumber(event.user_id) or 0)
    local gsec = cfg_num("command_cooldown_seconds", 3)
    if gsec > 0 then
        local gkey = K_CDG .. ":" .. gid
        local ukey = K_CDU .. ":" .. gid .. ":" .. uid
        if jn.cache.exists(gkey) > 0 or jn.cache.exists(ukey) > 0 then
            return false
        end
        jn.cache.set(gkey, "1", gsec)
        jn.cache.set(ukey, "1", gsec)
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
                reply(event, "指令执行出错了，请稍后再试")
            end
            return true
        end, { description = "猪猪派对：" .. paths[1] })
    end
end

reg({ "今日小猪", "抽小猪", "我的小猪", "rollpig" }, do_daily_pig)
reg({ "随机小猪", "随机猪猪", "猪猪", "rollpig_random" }, do_random_pig)

-- ============================================================================
-- 7. 启动
-- ============================================================================
local pool = get_pool()
jn.log.info(string.format("[%s] 猪猪派对已加载：图池 %d 张（图床目录 %d 个 / 自定义外链 %d 条）",
    PLUGIN_NAME, #pool, #cfg_list("image_bed_folders"), #cfg_list("custom_pig_images")))
