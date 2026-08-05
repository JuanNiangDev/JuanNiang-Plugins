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

-- 上次发送的索引，避免连续两次一样
local last_index = 0

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

    local from_qq = event.user_id

    -- 选一条回复，避免连续重复
    local idx
    repeat
        idx = math.random(#REPLIES)
    until idx ~= last_index or #REPLIES <= 1
    last_index = idx

    local text = REPLIES[idx]

    -- 群聊 @ 戳的人 + 回复
    local msg = string.format("[CQ:at,qq=%d] %s", from_qq, text)
    jn.onebot11.send_group_msg(group_id, msg)

    jn.log.info(string.format("[redrock_poke] %d 戳了卷娘 在群 %d", from_qq, group_id))
end

jn.log.info("[redrock_poke] 卷娘戳一戳插件已加载")
