-- ====================================================================
-- redrock_group_manager
-- 红岩群管理工具
-- 图片刷屏 / +1复读 / 政治/广告/色情敏感词 / 数据监控
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- 配置（可在 Web 面板配置）
-- ====================================================================

-- 图片刷屏：IMGP_SPAM_WINDOW 秒内 IMG_SPAM_THRESHOLD 张触发警告
local IMG_SPAM_WINDOW = tonumber(jn.config.get("img_spam_window")) or 2
local IMG_SPAM_THRESHOLD = tonumber(jn.config.get("img_spam_threshold")) or 3
local IMG_MUTE_DURATION = tonumber(jn.config.get("img_mute_duration")) or 60

-- +1 复读：COPY_THRESHOLD 人连续发相同消息触发
local COPY_THRESHOLD = tonumber(jn.config.get("copy_threshold")) or 3

-- ====================================================================
-- 敏感词库
-- ====================================================================

-- 政治敏感
local POLITICAL_WORDS = {
    "台湾", "湾湾", "乌克兰",
    "台独", "港独", "藏独",
    "两个中国", "简中", "辱华",
    "资本主义", "社会主义",
    "女权", "女拳", "田园女权", "小仙女", "xxn",
    "孙笑川", "男凝",
    "砍人", "杀人", "爱男", "爱女",
    "美国大选", "特朗普", "拜登",
}

-- 广告
local AD_WORDS = {
    "买校园卡", "买卡",
    "卖校园卡", "卖卡",
    "出校园卡", "出卡",
    "出物", "收物",
    "买被子", "卖被子", "出被子",
    "招聘", "兼职", "驾校",
    "二手交易",
}

-- 色情敏感
local NSFW_WORDS = {
    "约炮", "裸聊", "援交", "包养", "嫖娼",
    "小姐上门", "特殊服务", "一夜情",
    "色情", "黄色网站", "成人网站",
    "性爱", "做爱", "操逼", "日逼",
    "鸡巴", "逼", "屌",
}

-- ====================================================================
-- 辅助函数
-- ====================================================================

local function now_ts()
    return os.time()
end

-- ====================================================================
-- 存储层：内存缓存 + SQLite (表自动前缀 pluggin_redrock_group_manager_)
-- ====================================================================

-- 初始化数据库表
local function init_db()
    jn.database.exec([[
        CREATE TABLE IF NOT EXISTS pluggin_redrock_group_manager_kv (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    ]])
end
init_db()

-- 模块级内存缓存
local store = {}

local function get_kv(key)
    local v = store[key]
    if v ~= nil then return v end
    local rows, err = jn.database.query(
        string.format("SELECT value FROM pluggin_redrock_group_manager_kv WHERE key = '%s'", key))
    if rows and #rows > 0 then
        v = rows[1].value
        if v then store[key] = v end
    end
    return v
end

local function set_kv(key, val)
    store[key] = val
    local v = type(val) == "string" and val or tostring(val)
    jn.database.exec(string.format(
        "INSERT INTO pluggin_redrock_group_manager_kv (key, value) VALUES ('%s', '%s') " ..
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        key, v))
end

local function incr_kv(key)
    local v = tonumber(get_kv(key)) or 0
    v = v + 1
    set_kv(key, v)
    return v
end

local function del_kv(key)
    store[key] = nil
    jn.database.exec(string.format("DELETE FROM pluggin_redrock_group_manager_kv WHERE key = '%s'", key))
end

--- 构建 key（带群前缀）
local function gkey(group_id, suffix)
    return tostring(group_id) .. ":" .. suffix
end

--- 消息中是否包含图片/表情
local function has_image(raw)
    -- CQ 图片码 / 表情码 / 文本占位符
    return raw:find("%[CQ:image") ~= nil
        or raw:find("%[CQ:face") ~= nil
        or raw:find("%[CQ:mface") ~= nil
        or raw:find("%[图片%]") ~= nil
        or raw:find("%[表情%]") ~= nil
end

--- 匹配任意敏感词
local function match_any(text, words)
    local lower = text:lower()
    for _, w in ipairs(words) do
        if lower:find(w, 1, true) then
            return w
        end
    end
    return nil
end

--- 判断是否为管理员
local function is_admin(event)
    if event.admins then
        for _, qq in ipairs(event.admins) do
            if tostring(qq) == tostring(event.user_id) then
                return true
            end
        end
    end
    return false
end

--- 私聊通知所有管理员
local function notify_admins(event, text)
    if not event.admins then return end
    local group_id = event.group_id
    local group_info, _ = jn.onebot11.get_group_info(group_id)
    local group_name = group_info and group_info.group_name or tostring(group_id)
    local msg = "【群管理通知】\n群: " .. group_name .. "\n" .. text
    for _, qq in ipairs(event.admins) do
        jn.onebot11.send_private_msg(tonumber(qq), msg)
    end
end

--- 撤回消息
local function delete_msg(event)
    if event.message_id then
        jn.onebot11.delete_msg(event.message_id)
    end
end

--- 回复（群聊 @ 发信人）
local function reply(event, text, image)
    if event.message_type ~= "group" then return end
    local segments = {
        { type = "at",   data = { qq = tostring(event.user_id) } },
        { type = "text", data = { text = " " .. text } },
    }
    if image then
        segments[#segments + 1] = { type = "image", data = { file = image } }
    end
    jn.onebot11.send_group_msg(event.group_id, segments)
end

-- ====================================================================
-- 1. 图片刷屏检测
-- ====================================================================
local function check_image_spam(event)
    if not has_image(event.raw_message) then return false end

    local group_id = event.group_id
    local user_id = event.user_id
    jn.log.info(string.format("[group_mgr] 检测到图片: user=%d 群=%d", user_id, group_id))

    local key = gkey(group_id, "ims:" .. tostring(user_id))
    local warn_key = gkey(group_id, "ims_w:" .. tostring(user_id))

    -- 获取历史时间戳
    local raw_ts = get_kv(key) or ""
    local timestamps = {}
    if raw_ts ~= "" then
        for ts in raw_ts:gmatch("[^,]+") do
            timestamps[#timestamps + 1] = tonumber(ts)
        end
    end

    -- 清理过期时间戳
    local cutoff = now_ts() - IMG_SPAM_WINDOW
    local recent = {}
    for _, ts in ipairs(timestamps) do
        if ts >= cutoff then
            recent[#recent + 1] = ts
        end
    end
    -- 加上当前
    recent[#recent + 1] = now_ts()

    -- 保存
    local vals = {}
    for _, ts in ipairs(recent) do
        vals[#vals + 1] = tostring(ts)
    end
    set_kv(key, table.concat(vals, ","))

    -- 判断
    if #recent >= IMG_SPAM_THRESHOLD then
        local warned = get_kv(warn_key)
        if warned == "1" then
            -- 已经警告过，还在刷 → 禁言
            jn.onebot11.ban_group_member(group_id, user_id, IMG_MUTE_DURATION)
            incr_kv(gkey(group_id, "stats:mute"))
            jn.log.info(string.format("[group_mgr] %d 刷屏禁言 %ds 群 %d", user_id, IMG_MUTE_DURATION, group_id))
            notify_admins(event, user_id .. " 因图片刷屏被禁言 " .. IMG_MUTE_DURATION .. "s")
        else
            -- 首次警告
            set_kv(warn_key, "1")
            reply(event, "做文明群友，杜绝刷屏哦！", "img/shuaping.png")
            incr_kv(gkey(group_id, "stats:warn"))
        end
        return true
    elseif #recent == 1 then
        -- 解除警告标记（重新开始计数）
        set_kv(warn_key, "0")
    end

    return false
end

-- ====================================================================
-- 2. +1 复读检测
-- ====================================================================
local function check_copy_spam(event)
    local raw = (event.raw_message or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return false end
    -- 只检测纯文本消息
    if raw:find("%[CQ:") then return false end

    local group_id = event.group_id
    local user_id = event.user_id
    local last_key = gkey(group_id, "cp:last")
    local count_key = gkey(group_id, "cp:count")
    local users_key = gkey(group_id, "cp:users")

    -- 复读检测开关
    if jn.config.get("enable_copy_check") == false then return false end

    local last_msg = get_kv(last_key) or ""

    if raw == last_msg then
        -- 同一消息，检查用户是否已参与
        local users = get_kv(users_key) or ""
        if users:find(tostring(user_id)) then
            return false -- 同一用户不算复读
        end
        users = users .. "," .. tostring(user_id)
        set_kv(users_key, users)

        local count = incr_kv(count_key)

        if count >= COPY_THRESHOLD then
            jn.log.info(string.format("[group_mgr] 复读触发: count=%d 群=%d", count, group_id))
            -- 触发复读警告（仅首次）
            local triggered_key = gkey(group_id, "cp:trig")
            if get_kv(triggered_key) ~= "1" then
                jn.onebot11.send_group_msg(group_id, {
                    { type = "text", data = { text = "你们这群人机能不能别刷屏了" } },
                    { type = "image", data = { file = "img/shuaping_2.png" } },
                })
                set_kv(triggered_key, "1")
                -- 10 秒后重置触发标记
                -- (无法做延迟，用 TTL 近似：下次不同消息时重置)
                incr_kv(gkey(group_id, "stats:copy_warn"))
            end
            return true
        end
        return false
    else
        -- 不同消息，重置
        set_kv(last_key, raw)
        set_kv(count_key, "1")
        set_kv(users_key, tostring(user_id))
        set_kv(gkey(group_id, "cp:trig"), "0")
        return false
    end
end

-- ====================================================================
-- 3. 敏感内容检测
-- ====================================================================
local function check_sensitive(event)
    local raw = event.raw_message or ""
    local user_id = event.user_id
    local group_id = event.group_id

    -- 管理员豁免
    if is_admin(event) then return false end

    -- 政治敏感
    local pw = match_any(raw, POLITICAL_WORDS)
    if pw then
        delete_msg(event)
        reply(event, "小鬼，别碰这个话题")
        incr_kv(gkey(group_id, "stats:political"))
        jn.log.info(string.format("[group_mgr] %d 触发政治敏感词: %s", user_id, pw))
        return true
    end

    -- 广告
    local aw = match_any(raw, AD_WORDS)
    if aw then
        delete_msg(event)
        reply(event, "打广告先交200宣传费")
        incr_kv(gkey(group_id, "stats:ad"))
        jn.log.info(string.format("[group_mgr] %d 触发广告词: %s", user_id, aw))
        notify_admins(event, tostring(user_id) .. " 发送广告被撤回\n关键词: " .. aw)
        return true
    end

    -- 色情
    local nw = match_any(raw, NSFW_WORDS)
    if nw then
        delete_msg(event)
        incr_kv(gkey(group_id, "stats:nsfw"))
        jn.log.info(string.format("[group_mgr] %d 触发色情敏感词: %s", user_id, nw))
        notify_admins(event, tostring(user_id) .. " 发送色情敏感内容被撤回\n关键词: " .. nw)
        return true
    end

    return false
end

-- ====================================================================
-- on_message
-- ====================================================================
function on_message(event)
    if event.message_type ~= "group" then return false, nil end

    -- 敏感内容检测（优先级最高）
    if check_sensitive(event) then return true end

    -- 图片刷屏
    if check_image_spam(event) then return true end

    -- +1 复读
    if check_copy_spam(event) then return true end

    return false, nil
end

-- ====================================================================
-- on_notice: 入群统计
-- ====================================================================
function on_notice(event)
    if event.notice_type ~= "group_increase" then return end
    local group_id = event.group_id
    local date = os.date("%Y-%m-%d")
    incr_kv(gkey(group_id, "stats:join:" .. date))
end

-- ====================================================================
-- 命令: /groupstats —— 管理员查看统计
-- ====================================================================
jn.command.register("groupstats", function(args, event)
    if not is_admin(event) then
        reply(event, "只有管理员可以查看统计数据哦～")
        return true
    end

    local group_id = event.group_id
    local date = os.date("%Y-%m-%d")

    local joins = tonumber(get_kv(gkey(group_id, "stats:join:" .. date)) or "0")
    local warns = tonumber(get_kv(gkey(group_id, "stats:warn")) or "0")
    local mutes = tonumber(get_kv(gkey(group_id, "stats:mute")) or "0")
    local political = tonumber(get_kv(gkey(group_id, "stats:political")) or "0")
    local ad = tonumber(get_kv(gkey(group_id, "stats:ad")) or "0")
    local nsfw = tonumber(get_kv(gkey(group_id, "stats:nsfw")) or "0")
    local copy_warn = tonumber(get_kv(gkey(group_id, "stats:copy_warn")) or "0")

    local text = string.format([[
📊 群管理统计 (%s)
────────────────
今日入群: %d 人
刷屏警告: %d 次
刷屏禁言: %d 次
复读警告: %d 次
政治撤回: %d 次
广告撤回: %d 次
色情撤回: %d 次]],
        date, joins, warns, mutes, copy_warn, political, ad, nsfw)

    reply(event, text)
    return true
end, {
    description = "查看群管理统计数据（管理员）",
    usage = "/groupstats",
})

jn.log.info("[redrock_group_manager] 群管理插件已加载")
