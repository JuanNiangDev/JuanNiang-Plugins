-- ====================================================================
-- redrock_faq
-- 红岩网校招新群关键词问答插件
-- 用户 @卷娘 并包含关键词时，回复对应的红岩网校介绍内容。
--
-- 匹配策略：
--   · 完全匹配：清洗（去 @/CQ 码/语气词/标点）后消息等于关键词 → 直接触发
--   · 不完全匹配：关键词嵌在更长句子里时，必须同时出现红岩相关词
--     （红岩/网校/redrock/工作站/招新）才触发，
--     避免"安卓手机""加入牛魔团""蓝山在哪里"等无关消息误触发
--   · 英文关键词（AI/Android/iOS/redrock）按独立单词匹配
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- 回复内容
-- ====================================================================

local REPLIES = {
    redrock = "我们红岩网校是重邮团委旗下唯一一个从事互联网开发运营的学生组织，不仅培育出了一大批优秀的人才，还荣获多个荣誉奖项，深受大企青睐！",
    product = "产品策划及运营部是点子不冻港，产品的设计蓝图都出自他们之手。",
    visual = "视觉设计部的同学是创意设计者，用色彩渲染世界。",
    frontend = "他们是网站前台的画师。小程序、网站、webAPP里都有他们的影子。打造完美的网页是前端的宗旨！",
    backend = "后端是数据架构师，千万别小看它，这可是网校背后最可靠的保障。",
    mobile = "移动开发部的同学是APP的开发者，想解锁APP的无限可能吗？",
    ops = "运维安全部的成员技术高超，多亏了他们的存在，网校的系统才维持着安全稳定！",
    android = "Android是移动开发部从事安卓系统APP研发的子部门。他们利用Java和Kotlin来创造无限的可能，想在手机拥有一个自己创造的APP吗？加入Android吧！",
    ios = "iOS是移动开发部从事苹果系统APP研发的子部门，拥有着强大的苹果生态与无限的可能。想从App Store上看到自己的应用吗？想成为下一个Apple Developer吗？来iOS吧！",
    ai = "人工智能开发与应用部是红岩网校的新兴部门，主攻AI应用落地，具有广阔的发展前景。",
    study = "扎实的技术，互联网前沿知识，独一无二的项目经验，志同道合的朋友，都在红岩网校等着你呢！快来提升你的自学能力和沟通能力，强化你的自驱和自制力吧！",
    recruit = "网校的招新活动已经开始火热筹备！届时会开设招新宣讲会，帮助你进一步的了解红岩网校。会上我们还准备了精美的礼品等你来拿，时刻关注群消息，一定不要错过哦！",
    join = "扫描下方二维码，进入“青春邮约”，选择红岩网校工作站，让redrocker成为你最骄傲的自称吧~~",
    achievement = "嘿嘿，红岩网校的成果有这些：“重邮帮”小程序，“重邮小帮手”公众号，“掌上重邮”APP，美育学分管理系统，H5页面……",
    location = "太极运动场西3号门和西4号门都可以进入，具体可以到达西3号门查看楼内地图噢",
    freshman = "新生导航：https://gis.cqupt.edu.cn/",
    fun = "被你发现啦！试试玩游戏吧！\n【清单】\n戳一戳\n猜单词: /猜单词\n运行代码: /code",
    daily = "卷娘今天也在努力回答邮子们的问题呢！给自己加鸡腿~",
    moyu = "嘘！",
}

-- ====================================================================
-- 关键词规则（按优先级排列）
-- 匹配规则见文件头：完全匹配直接触发，不完全匹配需带红岩锚点
-- image 非空时，回复末尾附带插件目录下的图片
-- ====================================================================

-- 红岩相关锚点词（不完全匹配时消息里必须出现其一）
local ANCHORS = { "红岩", "网校", "redrock", "工作站", "招新" }

local RULES = {
    -- 子部门/部门
    { keywords = { "android", "安卓", "android开发", "安卓开发" }, reply = REPLIES.android },
    { keywords = { "ios", "ios开发" },                      reply = REPLIES.ios },
    { keywords = { "ai", "人工智能", "人工智能开发与应用部", "人工智能开发及应用部" }, reply = REPLIES.ai },
    { keywords = { "前端", "前端研发部" },                   reply = REPLIES.frontend },
    { keywords = { "后端", "后端研发部" },                   reply = REPLIES.backend },
    { keywords = { "产品", "产品策划", "产品策划及运营部" },    reply = REPLIES.product },
    { keywords = { "视觉", "视觉设计部" },                   reply = REPLIES.visual },
    { keywords = { "运维", "运维安全部" },                   reply = REPLIES.ops },
    { keywords = { "移动", "移动开发", "移动开发部", "移动部" }, reply = REPLIES.mobile },

    -- 加入/报名/进入
    { keywords = { "加入", "报名", "进入", "怎么进", "怎么加入", "如何加入",
        "在哪报名", "怎么报名", "如何报名", "加入方式", "报名方式" },
        reply = REPLIES.join, image = "join.png" },

    -- 地点
    { keywords = { "太极运动场", "西3号门", "西4号门", "楼内地图",
        "地点", "在哪", "哪里", "地址", "位置", "怎么去" },
        reply = REPLIES.location },

    -- 学习/收获
    { keywords = { "能学到", "可以学到", "学到", "学习", "收获",
        "收获什么", "有什么收获" },
        reply = REPLIES.study },

    -- 招新/成果
    { keywords = { "招新", "宣讲会", "招新宣讲会" },          reply = REPLIES.recruit },
    { keywords = { "成果", "成就" },                         reply = REPLIES.achievement },

    -- 新生导航
    { keywords = { "新生导航", "导航" },                       reply = REPLIES.freshman },

    -- 趣味功能
    { keywords = { "趣味功能", "有哪些功能", "有什么功能", "功能" }, reply = REPLIES.fun },

    -- 日常闲聊
    { keywords = { "干嘛", "今天干嘛", "在干嘛", "你在干嘛", "干啥" },            reply = REPLIES.daily, loose = true },
    { keywords = { "摸鱼", "在摸鱼" },                                 reply = REPLIES.moyu, image = "xu.png", loose = true },

    -- 红岩兜底
    { keywords = { "红岩", "网校", "redrock", "红岩网校", "红岩网校工作站" },
        reply = REPLIES.redrock },
}

-- 尾部语气词/标点/问法后缀（完全匹配前剥离，最长优先）
local SUFFIXES = {
    "是干什么的", "是做什么的", "是什么", "怎么样", "如何", "什么",
    "介绍",
    "吗", "呢", "啊", "吧", "么", "的", "了", "呀", "啦", "嘛", "哦", "哟",
    "？", "?", "！", "!", "。", "～", "~", "…",
}

-- 机器人的称呼（纯文本 @ 时的兜底匹配）
local BOT_NAME = "卷娘"

-- 机器人 QQ（懒加载缓存，避免每条消息都调用 get_login_info）
local bot_qq = nil

-- ====================================================================
-- 辅助函数
-- ====================================================================

--- 反复剥离消息尾部的语气词/标点/问法后缀
---@param s string
---@return string
local function strip_suffixes(s)
    while true do
        local changed = false
        for _, sfx in ipairs(SUFFIXES) do
            if s:sub(-#sfx) == sfx then
                s = s:sub(1, -#sfx - 1)
                changed = true
                break
            end
        end
        if not changed then break end
    end
    return s
end

--- 清洗消息：去掉 CQ 码、纯文本 @、首尾空白，并剥离尾部语气词
---@param raw string
---@return string
local function clean(raw)
    local s = raw:gsub("%[CQ:[^%]]*%]", "")
    s = s:gsub("@[^%s@]+", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return strip_suffixes(s)
end

--- 纯 ASCII 关键词按独立单词匹配（避免 ai 命中 main/email 等）
---@param lower string 已转小写的消息
---@param word string 全小写英文关键词
---@return boolean
local function find_word(lower, word)
    local from = 1
    while true do
        local s = lower:find(word, from, true)
        if not s then return false end
        local prev = s > 1 and lower:sub(s - 1, s - 1) or ""
        local next = lower:sub(s + #word, s + #word)
        if not prev:match("[a-z]") and not next:match("[a-z]") then
            return true
        end
        from = s + #word
    end
end

--- 匹配单个关键词（英文按单词边界，中文按子串）
---@param lower string
---@param kw string
---@return boolean
local function match_kw(lower, kw)
    if kw:match("^[a-z]+$") then
        return find_word(lower, kw)
    end
    return lower:find(kw, 1, true) ~= nil
end

--- 判断消息中是否出现红岩相关锚点词
---@param lower string
---@return boolean
local function has_anchor(lower)
    for _, a in ipairs(ANCHORS) do
        if match_kw(lower, a) then
            return true
        end
    end
    return false
end

--- 获取机器人自身 QQ
---@return number?
local function get_bot_qq()
    if bot_qq == nil then
        local info, _ = jn.onebot11.get_login_info()
        if info and info.user_id then
            bot_qq = tonumber(info.user_id)
        end
    end
    return bot_qq
end

--- 判断消息是否 @ 了机器人（CQ at 码或纯文本 @卷娘）
---@param raw string
---@return boolean
local function is_mentioned(raw)
    local qq = get_bot_qq()
    if qq then
        if raw:find("[CQ:at,qq=" .. tostring(qq), 1, true) then
            return true
        end
    end
    return raw:find("@" .. BOT_NAME, 1, true) ~= nil
end

--- 回复消息（群聊 @ 提问者，私聊直接发文本）
---@param event jn.Event
---@param text string
---@param image string?
local function reply(event, text, image)
    if event.message_type == "group" then
        local segments = {
            { type = "at",   data = { qq = tostring(event.user_id) } },
            { type = "text", data = { text = " " .. text } },
        }
        if image then
            segments[#segments + 1] = { type = "image", data = { file = image } }
        end
        jn.onebot11.send_group_msg(event.group_id, segments)
    else
        jn.onebot11.send_private_msg(event.user_id, text)
    end
end

-- ====================================================================
-- on_message: 关键词问答
-- ====================================================================
function on_message(event)
    local raw = (event.raw_message or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return false, nil end

    -- 群聊需要 @ 机器人；私聊无需 @
    if event.message_type == "group" and not is_mentioned(raw) then
        return false, nil
    end

    local lower = raw:lower()
    local cleaned = clean(raw):lower()
    local anchored = has_anchor(lower)

    for _, rule in ipairs(RULES) do
        for _, kw in ipairs(rule.keywords) do
            local kw_lower = kw:lower()
            local hit = false

            -- 宽松模式：闲聊类关键词，消息中出现即触发
            if rule.loose and match_kw(lower, kw) then
                hit = true
            -- 完全匹配：清洗后消息与关键词相等 → 直接触发
            elseif cleaned == kw_lower then
                hit = true
            -- 不完全匹配：关键词出现 + 消息带红岩锚点 → 触发
            elseif anchored and match_kw(lower, kw) then
                hit = true
            end

            if hit then
                reply(event, rule.reply, rule.image)
                jn.log.info(string.format("[redrock_faq] %d 触发关键词: %s", event.user_id, kw))
                return true
            end
        end
    end

    return false, nil
end

-- ====================================================================
-- 命令: /redrock —— 查看提问清单
-- ====================================================================
jn.command.register("redrock", function(args, event)
    local text = [[有问题就找卷娘吧！试试问我如下问题吧：
记得先@我哦 格式【@卷娘＋关键词】
【提问清单】
红岩网校介绍
产品策划及运营部介绍
视觉设计部介绍
前端介绍
后端介绍
移动开发部介绍
运维安全部介绍
人工智能开发及应用部介绍
在红岩网校能学到什么
如何加入红岩网校
红岩网校成果
红岩网校在哪里
新生导航
趣味功能]]
    reply(event, text)
    return true
end, {
    description = "查看红岩网校问答清单",
    usage = "/redrock",
})

jn.log.info("[redrock_faq] 关键词问答插件已加载")
