-- ====================================================================
-- redrock_poke
-- 卷娘戳一戳回复插件
-- 戳卷娘时，以卷娘的人设（18岁狮子座女生，活泼可爱俏皮）
-- 结合红岩网校信息进行多样化的俏皮回复。
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- 内置默认回复库（可在 Web 面板配置 poke_replies 覆盖）
-- ====================================================================
local DEFAULT_REPLIES = {
    -- 俏皮傲娇类
    "哼！别戳了，再戳狮子座可是会炸毛的哦～🦁",
    "哎呀，戳坏了你赔吗！卷娘才18岁，很娇贵的！(〃＞＿＜;〃)",
    "戳一戳已收到——已读不回，卷娘就是这么大牌 😎",
    "干嘛干嘛！卷娘正在打扫卫生呢，爱干净的女生最讨厌被突然戳到了！🧹",
    "哼哼，又戳我！身高162的可爱女生是你随便戳的吗！",

    -- 红岩招新类
    "戳卷娘不如戳 /redrock 呀！红岩网校招新了解一下？✨",
    "戳我的时间，都够问卷娘一个问题啦～试试 @卷娘 后端介绍 吧！",
    "诶嘿，想了解红岩网校吗？发送 /redrock 看看卷娘知道些什么～📋",
    "戳戳戳！有这功夫不如来红岩网校写代码！发送 /redrock 开始了解～",

    -- 游戏功能引导
    "无聊的话来玩猜单词呀！发送 /猜单词 开一局～🎮",
    "想测测你对红岩的了解吗？发送 /来一局 挑战快问快答～🧠",
    "戳卷娘不如戳代码！发送 /code py 试试在线运行代码吧～💻",
    "又戳我！信不信我用 Python 写个脚本自动回戳你！（并不会）🐍",

    -- 性格相关 + 红岩
    "EVER YOUTHFUL, EVER WEEPING～这是卷娘的座右铭呢！✨",
    "卷娘是重庆南岸区土生土长的狮子座女孩，红岩网校最可爱的存在不接受反驳！🏔️",
    "悄悄告诉你，卷娘生日是7月31号哦～记好了没！🎂",
    "虽然卷娘很俏皮，但红岩网校的技术可是认真的！想学什么我都能指路～",
    "卷娘今年18岁，在红岩网校等你来！这里有一群超棒的小伙伴～",
}

-- 回复库：优先使用配置的 poke_replies，否则回退内置默认库
local REPLIES = jn.config.get("poke_replies") or DEFAULT_REPLIES
if type(REPLIES) ~= "table" or #REPLIES == 0 then
    REPLIES = DEFAULT_REPLIES
end

-- ====================================================================
-- 表情包回复配置（图床）
-- emoji_folder: 图床虚拟文件夹（如 表情包）；emoji_files: 指定文件名列表（非空时优先）
-- emoji_rate: 文本回复时附带表情包的概率（0~100，%）
-- emoji_weight / text_weight: 表情包回复 vs 文本回复的加权随机
-- ====================================================================
local function num_config(key, default)
    local n = tonumber(jn.config.get(key))
    if n == nil then
        return default
    end
    return n
end

local EMOJI_FOLDER = tostring(jn.config.get("emoji_folder") or "")
local EMOJI_FILES = jn.config.get("emoji_files")
if type(EMOJI_FILES) ~= "table" then
    EMOJI_FILES = {}
end
local EMOJI_RATE = math.min(math.max(num_config("emoji_rate", 0), 0), 100)
local EMOJI_W = math.max(num_config("emoji_weight", 1), 0)
local TEXT_W = math.max(num_config("text_weight", 1), 0)

-- 图床候选池缓存（10 分钟刷新；配置重载时本脚本重跑即重建）
local emoji_pool = nil
local pool_loaded_at = 0
local POOL_TTL = 600

-- 表情包来源是否可用：目录非空 且 SDK 提供 images API（需 image 权限）
local function has_emoji_source()
    return EMOJI_FOLDER ~= "" and jn.images ~= nil
end

-- 刷新候选池：emoji_files 非空时仅保留指定名称（在目录内存在的）
local function refresh_pool(force)
    if not has_emoji_source() then
        return nil
    end
    local now = os.time()
    if not force and emoji_pool and now - pool_loaded_at < POOL_TTL then
        return emoji_pool
    end
    local ok, list = pcall(function()
        return jn.images.list(EMOJI_FOLDER)
    end)
    if not ok or type(list) ~= "table" then
        jn.log.warn("[redrock_poke] 图床枚举失败: " .. tostring(list))
        return emoji_pool -- 保留旧缓存继续用
    end
    local want = {}
    for _, n in ipairs(EMOJI_FILES) do
        want[tostring(n)] = true
    end
    local pool = {}
    for _, it in ipairs(list) do
        if type(it) == "table" and it.id then
            if next(want) == nil or want[it.name] then
                pool[#pool + 1] = it
            end
        end
    end
    emoji_pool = pool
    pool_loaded_at = now
    jn.log.info(string.format("[redrock_poke] 表情包候选池: %d 张（目录=%s，指定文件=%d）",
        #pool, EMOJI_FOLDER, #EMOJI_FILES))
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
-- 失败时返回 nil（不缓存，下次事件重试），避免启动时适配器未连接导致永久失效。
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
-- on_notice: 戳一戳事件
-- ====================================================================
function on_notice(event)
    -- 戳一戳：notice_type = "notify", sub_type = "poke"
    if event.notice_type ~= "notify" or event.sub_type ~= "poke" then
        return
    end

    -- 启用开关
    if jn.config.get("enabled") == false then return end

    local group_id = event.group_id
    if group_id == 0 then return end

    -- 只响应"被戳对象是机器人自己"的戳一戳：
    -- OneBot11 poke 事件中 user_id=戳人者，target_id=被戳者。
    -- 若 target_id 缺失（=0）或不是机器人自己，直接忽略，避免误回戳别人的戳一戳。
    local bot_qq = get_self_qq()
    if not bot_qq then
        return
    end
    local target = tonumber(event.target_id)
    if not target or target ~= bot_qq then
        return
    end

    local from_qq = event.user_id

    -- 选一条回复，避免连续重复
    local idx
    repeat
        idx = math.random(#REPLIES)
    until idx ~= last_index or #REPLIES <= 1
    last_index = idx

    local text = REPLIES[idx]

    -- 回复类型：emoji_weight : text_weight 加权随机
    -- 文本回复再按 emoji_rate% 概率附带一张表情包
    local use_emoji = false
    if EMOJI_W + TEXT_W > 0 and has_emoji_source() then
        use_emoji = math.random(EMOJI_W + TEXT_W) <= EMOJI_W
    end
    local attach_to_text = (not use_emoji) and EMOJI_RATE > 0
        and has_emoji_source()
        and math.random(100) <= EMOJI_RATE

    local img = nil
    if use_emoji or attach_to_text then
        img = pick_emoji()
    end
    if use_emoji and not img then
        use_emoji = false -- 候选池为空，回退文本回复
    end

    -- 群聊 @ 戳的人 + 回复（图床引用 imgs:// 由发送层解析为 base64）
    local msg = string.format("[CQ:at,qq=%d] ", from_qq)
    if use_emoji and img then
        msg = msg .. string.format("[CQ:image,file=imgs://%s]", img.id)
    else
        msg = msg .. text
        if attach_to_text and img then
            msg = msg .. string.format(" [CQ:image,file=imgs://%s]", img.id)
        end
    end
    jn.onebot11.send_group_msg(group_id, msg)

    jn.log.info(string.format("[redrock_poke] %d 戳了卷娘 在群 %d（%s）",
        from_qq, group_id, (use_emoji and img) and "表情包回复" or
        (img and "文本+表情包" or "文本回复")))
end

jn.log.info("[redrock_poke] 卷娘戳一戳插件已加载（表情包支持已启用）")
