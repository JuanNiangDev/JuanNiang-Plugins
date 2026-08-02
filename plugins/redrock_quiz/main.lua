-- ====================================================================
-- redrock_quiz
-- 红岩知识快问快答小游戏
-- 触发: /来一局 /快问快答
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- 题库
-- ====================================================================
local QUESTIONS = {
    {
        q = "红岩网校成立于什么时候？",
        a = "2000年10月",
        match = { "2000年10月", "2000年十月份", "2000年10月份" },
        hint = "世纪之交的那一年～再精确到月份试试？",
    },
    {
        q = "红岩网校成立于哪一年？",
        a = "2000年",
        match = { "2000年", "2000", "两千年" },
        hint = "20世纪的最后一年～",
    },
    {
        q = "红岩网校是重庆邮电大学唯一一个从事互联网产品开发运营的团委下属校级学生组织吗？",
        a = "是",
        match = { "是", "是的", "对的", "没错", "对" },
        hint = "答案很简洁，一个字～",
    },
    {
        q = "红岩网校下设六个部门还是七个部门？",
        a = "七个部门",
        match = { "七", "七个", "7", "七个部门", "7个", "七" },
        hint = "比六多一个哦～",
    },
    {
        q = "红岩网校的七个部门分别是？",
        a = "产品策划及运营部、视觉设计部、前端研发部、后端研发部、移动开发部、运维安全部、人工智能开发及应用部",
        match = { "产品", "视觉", "前端", "后端", "移动", "运维", "人工智能" },
        match_all = true,
        hint = "产品、视觉、前端、后端、移动、运维，还有一个AI相关的～",
    },
    {
        q = "红岩网校有哪些知名产品？",
        a = "重邮小帮手、掌上重邮APP、重邮地图、美育后台等",
        match = { "小帮手", "掌上重邮", "重邮地图", "美育" },
        match_min = 2,
        hint = "微信公众号、APP、地图……至少说出两个～",
    },
    {
        q = "红岩网校的核心产品",
        a = "掌上重邮APP、重邮帮小程序",
        match = { "掌上重邮", "重邮帮" },
        match_all = true,
        hint = "一个APP和一个小程序～",
    },
    {
        q = "怎么加入红岩网校？",
        a = "跟着学长学姐学习，自主探索，通过寒假暑假考核",
        match = { "考核", "寒假", "暑假", "学长", "学姐", "学习", "探索" },
        match_min = 3,
        hint = "关键词：学习、探索、考核、寒暑假～",
    },
}

-- ====================================================================
-- 游戏状态（模块级表，key = "group_id:user_id"）
-- ====================================================================
local games = {}

-- ====================================================================
-- 奖励语录
-- ====================================================================
local PRAISE = {
    "🎉 太厉害了！红岩知识满分选手就是你！",
    "✨ 完全正确！你已经比 80% 的老红岩人还懂啦～",
    "👏 厉害厉害！卷娘对你刮目相看！",
    "🌟 答对了！送你一朵小红花 🌹",
    "💯 满分答案！你就是红岩百事通！",
    "🔥 精准命中！这知识储备，稳～",
}

local WRONG_REPLY = {
    "😅 差一点～再想想？",
    "🤔 不太对哦，看看提示吧～",
    "💨 偏了偏了，卷娘给你个小提示～",
    "😜 接近了但不是正确答案哦～",
}

local FINISH_PERFECT = "🏆 满分通关！你对红岩网校的了解已经超越了卷娘！"
local FINISH_GREAT = "🎯 太棒了！%d/%d 正确，你是红岩知识达人！"
local FINISH_GOOD = "👍 不错哦！%d/%d 正确，再来一局冲击满分？"
local FINISH_OK = "📖 %d/%d 正确，多了解一点红岩的故事吧～\n小卷提示：https://ncnmb0lnxlng.feishu.cn/wiki/AxqGwtJjgiAIEZklvGncnSTjnpf"

-- ====================================================================
-- 辅助函数
-- ====================================================================
local function reply(event, text)
    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, {
            { type = "at",   data = { qq = tostring(event.user_id) } },
            { type = "text", data = { text = " " .. text } },
        })
    else
        jn.onebot11.send_private_msg(event.user_id, text)
    end
end

local function game_key(group_id, user_id)
    return tostring(group_id) .. ":" .. tostring(user_id)
end

local function shuffle(t)
    local n = #t
    for i = n, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

local function check_answer(question, user_answer)
    local lower = user_answer:lower():gsub("%s+", ""):gsub("[%p]+", "")
    local cm = question.match

    -- 多词全匹配
    if question.match_all then
        for _, kw in ipairs(cm) do
            if not lower:find(kw, 1, true) then
                return false
            end
        end
        return true
    end

    -- 最少匹配 N 个
    if question.match_min then
        local count = 0
        for _, kw in ipairs(cm) do
            if lower:find(kw, 1, true) then count = count + 1 end
        end
        return count >= question.match_min
    end

    -- 任意匹配
    for _, kw in ipairs(cm) do
        if lower:find(kw, 1, true) then
            return true
        end
    end
    return false
end

-- ====================================================================
-- 命令: /来一局 /快问快答
-- ====================================================================
local function start_quiz(event)
    local group_id = event.group_id or 0
    local user_id = event.user_id
    local key = game_key(group_id, user_id)

    local pool = {}
    for i, q in ipairs(QUESTIONS) do
        pool[i] = q
    end
    shuffle(pool)

    local total = 5
    local selected = {}
    for i = 1, math.min(total, #pool) do
        selected[i] = pool[i]
    end

    games[key] = {
        questions = selected,
        current = 1,
        score = 0,
        total = #selected,
    }

    local q = selected[1]
    reply(event, "🎮 红岩知识快问快答开始！共 " .. #selected .. " 题\n\n" ..
        "第 1 题：" .. q.q)

    jn.log.info(string.format("[quiz] %d 开始答题", user_id))
end

jn.command.register("来一局", function(args, event)
    start_quiz(event)
    return true
end, {
    description = "开始红岩知识快问快答",
    usage = "/来一局",
})

jn.command.register("快问快答", function(args, event)
    start_quiz(event)
    return true
end, {
    description = "开始红岩知识快问快答",
    usage = "/快问快答",
})

jn.command.register("结束快答", function(args, event)
    local key = game_key(event.group_id or 0, event.user_id)
    local game = games[key]
    if not game then
        reply(event, "你还没有进行中的快问快答哦～发送 /来一局 开始吧！")
        return true
    end
    games[key] = nil
    reply(event, "快问快答已结束～得分: " .. game.score .. "/" .. game.total)
    return true
end, {
    description = "结束当前快问快答",
    usage = "/结束快答",
})

-- ====================================================================
-- on_message: 答题
-- ====================================================================
function on_message(event)
    if event.message_type ~= "group" then return false, nil end

    local raw = (event.raw_message or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return false, nil end

    local key = game_key(event.group_id, event.user_id)
    local game = games[key]
    if not game then return false, nil end

    local q = game.questions[game.current]
    local correct = check_answer(q, raw)

    if correct then
        game.score = game.score + 1
        local praise = PRAISE[math.random(#PRAISE)]
        game.current = game.current + 1

        -- 所有题目答完
        if game.current > game.total then
            local msg
            local score = game.score
            local total = game.total
            if score == total then
                msg = praise .. "\n\n" .. FINISH_PERFECT
            elseif score >= total * 0.8 then
                msg = praise .. "\n\n" .. string.format(FINISH_GREAT, score, total)
            elseif score >= total * 0.5 then
                msg = praise .. "\n\n" .. string.format(FINISH_GOOD, score, total)
            else
                msg = praise .. "\n\n" .. string.format(FINISH_OK, score, total)
            end
            reply(event, msg)
            games[key] = nil
            return true
        end

        -- 下一题
        local next_q = game.questions[game.current]
        reply(event, praise .. "\n\n第 " .. game.current .. " 题：" .. next_q.q)
        return true
    end

    -- 答错了
    local msg = WRONG_REPLY[math.random(#WRONG_REPLY)]
    if q.hint then
        msg = msg .. "\n💡 提示：" .. q.hint
    end
    reply(event, msg)
    return true
end

jn.log.info("[redrock_quiz] 红岩快问快答插件已加载")
