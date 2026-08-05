-- ====================================================================
-- redrock_faq
-- 红岩网校招新群关键词问答 + 卷娘语料库
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- 回复内容
-- ====================================================================
local REPLIES = {
    -- 部门介绍
    redrock = "我们红岩网校是重邮团委旗下唯一一个从事互联网开发运营的学生组织，不仅培育出了一大批优秀的人才，还荣获多个荣誉奖项，深受大企青睐！\n\n🔗 了解更多：https://docs.qq.com/doc/DWWpYYXZPdGFUZVRT",
    product = "产品策划及运营部是点子不冻港，产品的设计蓝图都出自他们之手。\n\n🔗 了解更多：https://docs.qq.com/doc/DWXRZRWFMUE5sRXJw",
    visual = "视觉设计部的同学是创意设计者，用色彩渲染世界。\n\n🔗 了解更多：https://docs.qq.com/doc/DWW9YdERBU1FIWkhT",
    frontend = "他们是网站前台的画师。小程序、网站、webAPP里都有他们的影子。打造完美的网页是前端的宗旨！\n\n🔗 了解更多：https://docs.qq.com/doc/DWWZsdWtNVGtBYXFw",
    backend = [[后端是数据架构师，千万别小看它，这可是网校背后最可靠的保障。

🔗 了解更多：https://docs.qq.com/doc/DWWpEc1dYUEhRVEph]],
    mobile = "移动开发部的同学是APP的开发者，想解锁APP的无限可能吗？\n\n🔗 了解更多：https://docs.qq.com/doc/DWXRjZGZyRk9MVmxW",
    ops = "运维安全部的成员技术高超，多亏了他们的存在，网校的系统才维持着安全稳定！\n\n🔗 了解更多：https://docs.qq.com/doc/DWXpiSnBwdEN1TGps",
    android = "Android是移动开发部从事安卓系统APP研发的子部门。他们利用Java和Kotlin来创造无限的可能，想在手机拥有一个自己创造的APP吗？加入Android吧！\n\n🔗 移动开发部：https://docs.qq.com/doc/DWXRjZGZyRk9MVmxW",
    ios = "iOS是移动开发部从事苹果系统APP研发的子部门，拥有着强大的苹果生态与无限的可能。想从App Store上看到自己的应用吗？想成为下一个Apple Developer吗？来iOS吧！\n\n🔗 移动开发部：https://docs.qq.com/doc/DWXRjZGZyRk9MVmxW",
    ai = "人工智能开发与应用部是红岩网校的新兴部门，主攻AI应用落地，具有广阔的发展前景。\n\n🔗 了解更多：https://docs.qq.com/doc/DWVhJY0pwSm9iSXpu",
    study = "扎实的技术，互联网前沿知识，独一无二的项目经验，志同道合的朋友，都在红岩网校等着你呢！快来提升你的自学能力和沟通能力，强化你的自驱和自制力吧！\n\n🔗 了解更多：https://docs.qq.com/doc/DWWpYYXZPdGFUZVRT",
    recruit = "网校的招新活动已经开始火热筹备！届时会开设招新宣讲会，帮助你进一步的了解红岩网校。会上我们还准备了精美的礼品等你来拿，时刻关注群消息，一定不要错过哦！\n\n🔗 了解更多：https://docs.qq.com/doc/DWWpYYXZPdGFUZVRT",
    join = [[扫描下方二维码，进入"青春邮约"，选择红岩网校工作站，让redrocker成为你最骄傲的自称吧~~]],
    achievement = [[嘿嘿，红岩网校的成果有这些："重邮帮"小程序，"重邮小帮手"公众号，"掌上重邮"APP，美育学分管理系统，H5页面……]],
    location = [[太极运动场西3号门和西4号门都可以进入，具体可以到达西3号门查看楼内地图噢]],
    freshman = "新生导航：https://gis.cqupt.edu.cn/",
    fun = "被你发现啦！试试玩游戏吧！\n【清单】\n戳一戳\n猜单词: /猜单词\n快问快答: /来一局\n运行代码: /code",
    daily = "卷娘今天也在努力回答邮子们的问题呢！给自己加鸡腿~",
    moyu = "嘘！",

    -- 卷娘语料库
    six = "6，卷娘给你扣个666，你也很会冲浪嘛〜",
    here = "在的在的，卷娘24小时在线（除了睡觉和偷偷摸鱼的时候）",
    dating = "有啊，红岩网校就是我的对象，你要来认识一下吗？",
    juan = "别卷了别卷了，在红岩你可以慢慢学，没人逼你〜",
    bailan = "摆烂可以，但摆烂也要摆得有技术含量——来运维部学习怎么优雅地躺平（bushi）",
    emo_casual = "别emo啦！来群里聊聊天，卷娘请你云吃中心食堂杂酱面〜",
    food = "卷娘推荐中心食堂杂酱面！滨湖也行，但别去三食堂（嘘）",
    morning = "早八人早八魂，早八都是人上人",
    senior = "别叫大佬，叫redrocker！大家都一样，都是从0开始的〜",
    cqupt = "重邮很好，有红岩网校的重邮更有意思！",
    thanks = "不客气！有问题随时找卷娘，卷娘一直在〜",
    bye = "拜拜〜记得常来群里看看卷娘哦，不然卷娘会孤单的💔",
    beauty = "cqupt的校花呀，正是卷卷呀，嘿嘿",
    hard = "心急则味散，卷卷陪你慢慢来",
    bored = "来杯好茶摇一摇，摇一摇",
    redrock_special_trait = "那让我来告诉你，重邮人这辈子都要保护的3样东西:3G芯片，世界一流早操工程，校园跑工程呀～",
    chip3g = [[检测到您的语句中含有"3G"，触发关键词，我将为您科普重邮3G:
2005年10月9日下午2:30，重庆市人民政府新闻办公室在重庆市新闻发布中心举行了新闻发布会。会议郑重发布了"世界第一颗0.13微米工艺的TD-SCDMA 3G手机核心芯片在重庆诞生"这一令国人自豪和骄傲的重大喜讯。它是世界上第一颗采用0.13微米工艺的TD-SCDMA手机基带芯片，功耗低，内核尺寸小，成本低，标志着中国3G通信核心芯片的关键技术达到了世界领先水平。重邮信科"通芯一号"芯片是符合3GPP TD-SCDMA标准自主研发的手机芯片，它具有优良的总体构架和实现算法，经过了充分的仿真和验证，具有极高的性能和稳定性，可完成TD-SCDMA手机物理层、协议栈和应用软件所有处理工作。"通芯一号"芯片的开发成功，是邮电学院从1998年开始参与大唐电信为首组织的TD-SCDMA标准研究，并在2003年采用通用芯片独立开发出世界上第一部TD-SCDMA（TSM）手机后在TD-SCDMA自主创新上的又一重大突破，是重邮信科对TD-SCDMA产业化的重大贡献，标志着重邮信科在TD-SCDMA终端产业链上已经确立了重要的基础地位。]],
}

-- ====================================================================
-- 关键词规则
-- ====================================================================
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
    { keywords = { "运维", "运维安全部", "运维安全", "安全", "sre", "SRE" }, reply = REPLIES.ops },
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

    -- 红岩兜底
    { keywords = { "红岩", "网校", "redrock", "红岩网校", "红岩网校工作站" },
        reply = REPLIES.redrock },
}

-- ====================================================================
-- 卷娘语料库（loose 模式，消息中出现即触发）
-- ====================================================================
local CHAT_RULES = {
    { keywords = { "6", "牛", "绝了" },                     reply = REPLIES.six },
    { keywords = { "在吗", "在不在" },                       reply = REPLIES.here },
    { keywords = { "有对象", "单身", "有男朋友", "有女朋友" },    reply = REPLIES.dating },
    { keywords = { "内卷" },                         reply = REPLIES.juan },
    { keywords = { "摆烂", "躺平" },                         reply = REPLIES.bailan },
    { keywords = { "emo", "难过", "呜呜" },                   reply = REPLIES.emo_casual },
    { keywords = { "吃饭", "吃什么", "食堂" },                  reply = REPLIES.food },
    { keywords = { "早八", "困", "好困", "好累", "累死了" },       reply = REPLIES.morning },
    { keywords = { "学长学姐", "大佬", "大神" },                reply = REPLIES.senior },
    { keywords = { "重邮", "学校" },                         reply = REPLIES.cqupt },
    { keywords = { "感谢", "谢谢", "谢谢卷娘" },               reply = REPLIES.thanks },
    { keywords = { "拜拜", "再见", "晚安" },                   reply = REPLIES.bye },
    { keywords = { "校花" },                               reply = REPLIES.beauty },
    { keywords = { "学不懂", "学不会", "太难了" },              reply = REPLIES.hard },
    { keywords = { "无聊" },                               reply = REPLIES.bored },
    { keywords = { "特色" },                               reply = REPLIES.redrock_special_trait },
    { keywords = { "3g", "3G" },                           reply = REPLIES.chip3g },
    { keywords = { "干嘛", "今天干嘛", "在干嘛", "你在干嘛", "干啥" }, reply = REPLIES.daily },
    { keywords = { "摸鱼", "在摸鱼" },                       reply = REPLIES.moyu, image = "xu.png" },
}

-- ====================================================================
-- 辅助函数
-- ====================================================================
local SUFFIXES = {
    "是干什么的", "是做什么的", "是什么", "怎么样", "如何", "什么",
    "介绍",
    "吗", "呢", "啊", "吧", "么", "的", "了", "呀", "啦", "嘛", "哦", "哟",
    "？", "?", "！", "!", "。", "～", "~", "…",
}

local BOT_NAME = jn.config.get("bot_name") or "卷娘"
local bot_qq = nil

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

local function clean(raw)
    local s = raw:gsub("%[CQ:[^%]]*%]", "")
    s = s:gsub("@[^%s@]+", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return strip_suffixes(s)
end

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

local function match_kw(lower, kw)
    if kw:match("^[a-z0-9]+$") then return find_word(lower, kw) end
    return lower:find(kw, 1, true) ~= nil
end

local function has_anchor(lower)
    for _, a in ipairs(ANCHORS) do
        if match_kw(lower, a) then return true end
    end
    return false
end

local function get_bot_qq()
    if bot_qq == nil then
        local info, _ = jn.onebot11.get_login_info()
        if info and info.user_id then bot_qq = tonumber(info.user_id) end
    end
    return bot_qq
end

local function is_mentioned(raw)
    local qq = get_bot_qq()
    if qq and raw:find("[CQ:at,qq=" .. tostring(qq), 1, true) then return true end
    return raw:find("@" .. BOT_NAME, 1, true) ~= nil
end

local function reply(event, text, image)
    if event.message_type == "group" then
        local segments = {
            { type = "at",   data = { qq = tostring(event.user_id) } },
            { type = "text", data = { text = " " .. text } },
        }
        if image then segments[#segments + 1] = { type = "image", data = { file = image } } end
        jn.onebot11.send_group_msg(event.group_id, segments)
    else
        jn.onebot11.send_private_msg(event.user_id, text)
    end
end

-- ====================================================================
-- on_message
-- ====================================================================
local greeted = {}

function on_message(event)
    local raw = (event.raw_message or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return false, nil end
    local lower = raw:lower()

    -- 私聊引导
    if event.message_type == "private" then
        local uid = tostring(event.user_id)
        if raw == "1" then reply(event, REPLIES.redrock); return true
        elseif raw == "2" then
            reply(event, [[红岩网校七个部门：
1. 产品策划及运营部
2. 视觉设计部
3. 前端研发部
4. 后端研发部
5. 移动开发部（Android / iOS）
6. 运维安全部
7. 人工智能开发及应用部
回复部门名了解更多～]])
            return true
        elseif raw == "3" then reply(event, REPLIES.recruit); return true
        elseif raw == "4" then
            reply(event, [[【常见问题】
红岩网校介绍 | 部门介绍 | 能学到什么
如何加入 | 成果 | 位置 | 新生导航 | 趣味功能
直接打字问我吧～]])
            return true
        elseif raw == "5" then reply(event, REPLIES.fun); return true
        end

        if not greeted[uid] then
            greeted[uid] = true
            reply(event, [[嗨！欢迎来到红岩网校～这里是卷娘的秘密基地！
你想了解什么？点下面的数字吧👇
1️⃣ 网校介绍  2️⃣ 部门介绍  3️⃣ 最近活动  4️⃣ 常见问题  5️⃣ 找卷娘玩
或者直接打字告诉我～]])
            return true
        end

        -- 私聊语料库匹配（可配置开关）
        if jn.config.get("enable_chat_rules") ~= false then
            for _, rule in ipairs(CHAT_RULES) do
                for _, kw in ipairs(rule.keywords) do
                    if match_kw(lower, kw) then reply(event, rule.reply, rule.image); return true end
                end
            end
        end
        return false, nil
    end

    -- 群聊需要 @ 卷娘
    if not is_mentioned(raw) then return false, nil end

    local cleaned = clean(raw):lower()
    local anchored = has_anchor(lower)

    -- 数字菜单
    if cleaned == "1" then reply(event, REPLIES.redrock); return true
    elseif cleaned == "2" then
        reply(event, [[红岩网校七个部门：
1. 产品策划及运营部 — 产品的设计蓝图都出自他们之手
2. 视觉设计部 — 用色彩渲染世界
3. 前端研发部 — 小程序、网站、webAPP的幕后画师
4. 后端研发部 — 网校最可靠的保障
5. 移动开发部 — APP的无限可能
6. 运维安全部 — 系统安全稳定的守护者
7. 人工智能开发及应用部 — 主攻AI应用落地
试试 @卷娘 + 部门名 了解更多～]])
        return true
    elseif cleaned == "3" then reply(event, REPLIES.recruit); return true
    elseif cleaned == "4" then
        reply(event, [[【常见问题】
红岩网校介绍 | 部门介绍 | 能学到什么
如何加入 | 成果 | 位置 | 新生导航 | 趣味功能
试试 @卷娘 + 关键词 问我吧～]])
        return true
    elseif cleaned == "5" then reply(event, REPLIES.fun); return true
    end

    -- 语料库优先（loose 匹配，≤2字符做精确匹配避免误触）
    if jn.config.get("enable_chat_rules") ~= false then
        for _, rule in ipairs(CHAT_RULES) do
            for _, kw in ipairs(rule.keywords) do
                local hit = false
                if #kw <= 2 then
                    hit = (cleaned == kw)
                elseif match_kw(lower, kw) then
                    hit = true
                end
                if hit then
                    reply(event, rule.reply, rule.image)
                    return true
                end
            end
        end
    end

    -- 部门/官方问答
    for _, rule in ipairs(RULES) do
        for _, kw in ipairs(rule.keywords) do
            local hit = false
            if cleaned == kw:lower() then hit = true
            elseif anchored and match_kw(lower, kw) then hit = true
            end
            if hit then reply(event, rule.reply, rule.image); return true end
        end
    end

    return false, nil
end

-- ====================================================================
-- /redrock 命令
-- ====================================================================
jn.command.register("redrock", function(args, event)
    local text = [[有问题就找卷娘吧！试试问我如下问题吧：
记得先@我哦 格式【@卷娘＋关键词】

📋 快捷菜单（回复数字即可）：
1️⃣ 红岩网校是什么？
2️⃣ 七个部门介绍
3️⃣ 最近有什么活动？
4️⃣ 常见问题（FAQ）
5️⃣ 玩个游戏放松一下

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
end, { description = "查看红岩网校问答清单", usage = "/redrock" })

jn.log.info("[redrock_faq] 关键词问答插件已加载")
