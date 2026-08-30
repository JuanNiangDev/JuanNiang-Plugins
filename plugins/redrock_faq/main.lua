-- ====================================================================
-- redrock_faq
-- 红岩网校 FAQ 查询插件（命令式）
-- 用法: /redrock [参数] —— 无参数显示查询清单，带参数查询对应信息
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

🔗 了解更多：https://docs.qq.com/pdf/DYkJCR2xVUnVKeUt5]],
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

    -- 卷娘语料库（命令式触发）
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

-- 部门清单（/redrock 部门）
local DEPARTMENT_LIST = [[红岩网校七个部门：
1. 产品策划及运营部 — 产品的设计蓝图都出自他们之手
2. 视觉设计部 — 用色彩渲染世界
3. 前端研发部 — 小程序、网站、webAPP的幕后画师
4. 后端研发部 — 网校最可靠的保障
5. 移动开发部 — APP的无限可能（Android / iOS）
6. 运维安全部 — 系统安全稳定的守护者
7. 人工智能开发及应用部 — 主攻AI应用落地

使用 /redrock <部门名> 查看具体介绍，如：/redrock 前端]]

-- ====================================================================
-- 查询条目：names 为可查询的参数别名（忽略大小写），reply 为回复内容
-- ====================================================================
local QUERIES = {
    -- 网校介绍
    { names = { "网校", "红岩", "redrock", "介绍", "是什么", "网校介绍", "红岩网校" }, reply = REPLIES.redrock },
    -- 部门
    { names = { "部门", "部门介绍", "有哪些部门" }, reply = DEPARTMENT_LIST },
    { names = { "产品", "产品策划", "产品策划及运营部" }, reply = REPLIES.product },
    { names = { "视觉", "视觉设计部" }, reply = REPLIES.visual },
    { names = { "前端", "前端研发部" }, reply = REPLIES.frontend },
    { names = { "后端", "后端研发部" }, reply = REPLIES.backend },
    { names = { "移动", "移动开发", "移动开发部", "移动部" }, reply = REPLIES.mobile },
    { names = { "安卓", "android", "android开发" }, reply = REPLIES.android },
    { names = { "ios", "ios开发" }, reply = REPLIES.ios },
    { names = { "运维", "运维安全", "运维安全部", "安全", "sre" }, reply = REPLIES.ops },
    { names = { "ai", "人工智能", "人工智能开发", "人工智能开发及应用部" }, reply = REPLIES.ai },
    -- 加入/报名
    { names = { "加入", "报名", "怎么加入", "如何加入", "加入方式", "报名方式" }, reply = REPLIES.join, image = "join.png" },
    -- 地点
    { names = { "位置", "地点", "在哪", "地址", "怎么去", "太极运动场" }, reply = REPLIES.location },
    -- 学习/收获
    { names = { "学习", "能学到", "能学到什么", "学到什么", "收获" }, reply = REPLIES.study },
    -- 招新/成果
    { names = { "招新", "活动", "宣讲会", "招新宣讲会" }, reply = REPLIES.recruit },
    { names = { "成果", "成就" }, reply = REPLIES.achievement },
    -- 新生导航
    { names = { "新生导航", "导航" }, reply = REPLIES.freshman },
    -- 趣味功能
    { names = { "趣味功能", "功能", "游戏", "玩什么" }, reply = REPLIES.fun },
    -- 重邮特色彩蛋
    { names = { "3g", "芯片", "3g芯片" }, reply = REPLIES.chip3g },
    { names = { "特色" }, reply = REPLIES.redrock_special_trait },
    -- 闲聊彩蛋（命令式触发）
    { names = { "在吗", "在不在" }, reply = REPLIES.here },
    { names = { "对象", "单身", "有对象" }, reply = REPLIES.dating },
    { names = { "内卷" }, reply = REPLIES.juan },
    { names = { "摆烂", "躺平" }, reply = REPLIES.bailan },
    { names = { "emo", "难过" }, reply = REPLIES.emo_casual },
    { names = { "吃饭", "吃什么", "食堂" }, reply = REPLIES.food },
    { names = { "早八", "好困", "好累" }, reply = REPLIES.morning },
    { names = { "学长", "大佬" }, reply = REPLIES.senior },
    { names = { "重邮", "学校" }, reply = REPLIES.cqupt },
    { names = { "感谢", "谢谢" }, reply = REPLIES.thanks },
    { names = { "拜拜", "再见", "晚安" }, reply = REPLIES.bye },
    { names = { "校花" }, reply = REPLIES.beauty },
    { names = { "学不会", "学不懂", "太难了" }, reply = REPLIES.hard },
    { names = { "无聊" }, reply = REPLIES.bored },
    { names = { "6", "666" }, reply = REPLIES.six },
    { names = { "干嘛", "在干嘛" }, reply = REPLIES.daily },
    { names = { "摸鱼", "在摸鱼" }, reply = REPLIES.moyu, image = "xu.png" },
}

-- 查询清单菜单（无参数时显示）
local MENU = [[【红岩网校查询】发送 /redrock <关键词> 查询对应信息～

📋 可查询内容：
- 网校介绍
- 部门介绍
- 前端
- 后端
- 产品
- 视觉
- 移动/安卓/ios
- 运维
- AI
- 如何加入
- 网校位置
- 能学到什么
- 招新活动
- 网校成果
- 新生导航
- 趣味功能
- 3G 科普]]

-- ====================================================================
-- 辅助函数
-- ====================================================================
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

-- 查询匹配：先精确匹配，再双向包含匹配（过短的词不参与包含匹配，避免误命中）
local function query(key)
    for _, q in ipairs(QUERIES) do
        for _, n in ipairs(q.names) do
            if n == key then return q end
        end
    end
    for _, q in ipairs(QUERIES) do
        for _, n in ipairs(q.names) do
            if #n >= 2 and #key >= 2 and (key:find(n, 1, true) or n:find(key, 1, true)) then
                return q
            end
        end
    end
    return nil
end

-- ====================================================================
-- /redrock [参数] 命令
-- ====================================================================
jn.command.register("redrock", function(args, event)
    -- 无参数 → 查询清单
    if #args == 0 then
        reply(event, MENU)
        return true
    end

    local key = table.concat(args, " "):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if key == "" then
        reply(event, MENU)
        return true
    end

    local q = query(key)
    if q then
        reply(event, q.reply, q.image)
        return true
    end

    reply(event, "没有找到与「" .. key .. "」相关的内容，试试 /redrock 查看查询清单吧～")
    return true
end, { description = "查询红岩网校相关信息", usage = "/redrock <关键词>" })

jn.log.info("[redrock_faq] 红岩网校查询插件已加载")
