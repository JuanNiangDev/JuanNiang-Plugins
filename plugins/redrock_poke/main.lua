-- ====================================================================
-- redrock_poke 戳一戳回复插件
-- ====================================================================
-- 当群聊内发生 notify.poke 戳一戳事件，且被戳目标为机器人自己时：
-- 随机选择一条回复语发送到群聊。
-- 优先使用 config.yaml 中配置的 poke_replies；未配置时使用插件内置默认回复库。
--
-- 表情包增强（需要 image 权限）：
--   * emoji_folders 可配置多个图床虚拟文件夹合并为图片池
--   * emoji_images 可额外跨目录指定多个具体图片名称，与目录池合并随机
--   * emoji_files 可在目录池内做文件名白名单过滤
--   * 按 emoji_weight:text_weight 加权随机选择「表情包回复」或「文本回复」
--   * 文本回复时可按 emoji_rate% 概率附带一张图床表情包
--   * 图片以 [CQ:image,file=imgs://<id>] 发送，发送层统一解析为 base64
-- ====================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

-- 内置默认回复库（用户未配置 poke_replies 时兜底使用）
local DEFAULT_REPLIES = {
    "不要戳我啦 >_<",
    "戳我干嘛？",
    "哎呀，好痒！",
    "有什么事吗？",
    "再戳我就生气了！",
    "本姑娘在呢～",
    "别戳啦，在忙呢！",
    "呜……轻点戳！",
    "戳脸会长皱纹的！",
    "抓住你的小手！(｀・ω・´)",
}

-- 解析数字配置（防御非法字符 / 缺失），回退 default
local function num_config(key, default)
    local v = jn.config.get(key)
    if v == nil or v == "" then
        return default
    end
    local n = tonumber(v)
    return n or default
end

-- 解析列表配置
local function list_config(key)
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

-- 兼容读取单个目录与多个目录
local function get_emoji_folders()
    local list = list_config("emoji_folders")
    if #list == 0 then
        local single = tostring(jn.config.get("emoji_folder") or ""):match("^%s*(.-)%s*$")
        if single and single ~= "" then
            list = { single }
        end
    end
    return list
end

local EMOJI_FILES = list_config("emoji_files")
local EMOJI_IMAGES = list_config("emoji_images")
local EMOJI_RATE = math.min(math.max(num_config("emoji_rate", 30), 0), 100)
local EMOJI_W = math.max(num_config("emoji_weight", 1), 0)
local TEXT_W = math.max(num_config("text_weight", 2), 0)

-- 图床候选池缓存（10 分钟刷新；配置重载时本脚本重跑即重建）
local emoji_pool = nil
local pool_loaded_at = 0
local POOL_TTL = 600

-- 表情包来源是否可用：存在目录或独立图片 且 SDK 提供 images API（需 image 权限）
local function has_emoji_source()
    local folders = get_emoji_folders()
    local images = list_config("emoji_images")
    return (#folders > 0 or #images > 0) and jn.images ~= nil
end

-- 刷新候选池：汇总多个目录 + 多个具体指定图片，同时支持文件名白名单过滤
local function refresh_pool(force)
    if not has_emoji_source() then
        return nil
    end
    local now = os.time()
    if not force and emoji_pool and now - pool_loaded_at < POOL_TTL then
        return emoji_pool
    end

    local pool = {}
    local seen_ids = {}

    -- 1. 遍历多个目录
    local folders = get_emoji_folders()
    local want_files = {}
    for _, n in ipairs(list_config("emoji_files")) do
        want_files[tostring(n)] = true
    end

    for _, folder in ipairs(folders) do
        local ok, list = pcall(function()
            return jn.images.list(folder)
        end)
        if ok and type(list) == "table" then
            for _, it in ipairs(list) do
                if type(it) == "table" and it.id and not seen_ids[it.id] then
                    if next(want_files) == nil or want_files[it.name] then
                        seen_ids[it.id] = true
                        pool[#pool + 1] = it
                    end
                end
            end
        else
            jn.log.warn("[redrock_poke] 图床目录枚举失败: " .. tostring(folder) .. " err=" .. tostring(list))
        end
    end

    -- 2. 遍历额外指定的具体单张图片（跨目录模糊/精确搜索）
    local images = list_config("emoji_images")
    for _, img_name in ipairs(images) do
        local ok, list = pcall(function()
            return jn.images.search(img_name, 5)
        end)
        if ok and type(list) == "table" then
            for _, it in ipairs(list) do
                if type(it) == "table" and it.id and not seen_ids[it.id] then
                    if tostring(it.name) == img_name or tostring(it.name):find(img_name, 1, true) then
                        seen_ids[it.id] = true
                        pool[#pool + 1] = it
                    end
                end
            end
        end
    end

    emoji_pool = pool
    pool_loaded_at = now
    jn.log.info(string.format("[redrock_poke] 表情包候选池: %d 张（目录数=%d，独立图片=%d，文件白名单=%d）",
        #pool, #folders, #images, #EMOJI_FILES))
    return pool
end

local function pick_emoji()
    local pool = refresh_pool(false)
    if not pool or #pool == 0 then
        return nil
    end
    return pool[math.random(#pool)]
end

-- 上次发送的索引，避免连续两次一样
local last_index = 0

-- 机器人自身 QQ（惰性获取并缓存；配置变更重载后自动重新解析）
local self_qq = nil
local self_qq_warned = false

-- 获取机器人自身 QQ：优先配置 bot_qq，其次自动调用 get_login_info。
local function get_self_qq()
    if self_qq then
        return self_qq
    end
    local cfg_qq = jn.config.get("bot_qq")
    if cfg_qq and tostring(cfg_qq) ~= "" then
        self_qq = tonumber(cfg_qq)
        return self_qq
    end
    local info, err = jn.onebot11.get_login_info()
    if info and info.user_id then
        self_qq = tonumber(info.user_id)
        return self_qq
    end
    if not self_qq_warned then
        self_qq_warned = true
        jn.log.warn(string.format("[redrock_poke] 获取机器人QQ失败(%s)，戳一戳回复暂时停用，可在配置中指定 bot_qq", tostring(err)))
    end
    return nil
end

-- ====================================================================
-- 事件入口
-- ====================================================================

function on_notice(event)
    if event.notice_type ~= "notify" or event.sub_type ~= "poke" then
        return false, nil
    end

    local enabled = jn.config.get("enabled")
    if enabled == false or enabled == "false" then
        return false, nil
    end

    local my_qq = get_self_qq()
    if not my_qq then
        return false, nil
    end
    if tonumber(event.target_id) ~= my_qq then
        return false, nil
    end

    -- 决策：发纯表情包还是走文本回复路径
    local emoji = pick_emoji()
    local is_emoji_only = false
    if emoji and (EMOJI_W > 0 or TEXT_W > 0) then
        local roll = math.random(EMOJI_W + TEXT_W)
        if roll <= EMOJI_W then
            is_emoji_only = true
        end
    end

    if is_emoji_only and emoji then
        local msg = string.format("[CQ:image,file=imgs://%s]", emoji.id)
        if event.group_id and tonumber(event.group_id) > 0 then
            jn.onebot11.send_group_msg(tonumber(event.group_id), msg)
        else
            jn.onebot11.send_private_msg(tonumber(event.user_id), msg)
        end
        return false, nil
    end

    -- 文本回复分支
    local list = jn.config.get("poke_replies")
    local replies = (type(list) == "table" and #list > 0) and list or DEFAULT_REPLIES

    local count = #replies
    local idx
    if count == 1 then
        idx = 1
    else
        repeat
            idx = math.random(count)
        until idx ~= last_index
    end
    last_index = idx

    local text = replies[idx]

    -- 概率带图
    if emoji and EMOJI_RATE > 0 and math.random(100) <= EMOJI_RATE then
        text = text .. "\n" .. string.format("[CQ:image,file=imgs://%s]", emoji.id)
    end

    if event.group_id and tonumber(event.group_id) > 0 then
        jn.onebot11.send_group_msg(tonumber(event.group_id), text)
    else
        jn.onebot11.send_private_msg(tonumber(event.user_id), text)
    end

    return false, nil
end

math.randomseed(os.time())
jn.log.info("[redrock_poke] 戳一戳回复插件已加载（支持多图床目录与独立图片指定）")
