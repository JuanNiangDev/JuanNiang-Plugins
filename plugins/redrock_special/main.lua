-- ====================================================================
-- redrock_special
-- 卷娘彩蛋关键词插件
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- 回复规则
-- ====================================================================

local RULES = {
    -- 年龄
    {
        keywords = { "年龄", "年纪", "芳龄", "多大了" },
        reply = "有些事情你还是不要知道的好",
        images = { "img/q1/image 1.png", "img/q1/image 25.png" },
    },
    -- 身高
    {
        keywords = { "身高" },
        reply = "不会吧，不会吧，不会真的有人要问女生的身高吧。",
        images = { "img/q2/image 10.png", "img/q2/image 19.png" },
    },
    -- 体重
    {
        keywords = { "体重" },
        reply = "emmmm你要不问问别的？",
        images = { "img/q3/image 28.png", "img/q3/image 6.png" },
    },
    -- 颜色
    {
        keywords = { "喜欢什么颜色", "喜欢啥颜色", "什么颜色" },
        reply = "当然是红色！毕竟我是红岩网校的卷娘～",
    },
    -- 周末
    {
        keywords = { "周末干嘛", "周末干什么", "周末做什么" },
        reply = "帮管理员整理文件，偶尔偷偷玩'猜单词'和'快问快答' —— 悄悄说我胜率 80% 哦，来挑战吗？",
    },
}

-- ====================================================================
-- 辅助函数
-- ====================================================================

local BOT_NAME = "卷娘"
local bot_qq = nil

local function get_bot_qq()
    if bot_qq == nil then
        local info, _ = jn.onebot11.get_login_info()
        if info and info.user_id then
            bot_qq = tonumber(info.user_id)
        end
    end
    return bot_qq
end

local function is_mentioned(raw)
    local qq = get_bot_qq()
    if qq then
        if raw:find("[CQ:at,qq=" .. tostring(qq), 1, true) then
            return true
        end
    end
    return raw:find("@" .. BOT_NAME, 1, true) ~= nil
end

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

local function match_kw(lower, kw)
    if kw:match("^[a-z]+$") then
        -- 英文按独立单词匹配
        local from = 1
        while true do
            local s = lower:find(kw, from, true)
            if not s then return false end
            local prev = s > 1 and lower:sub(s - 1, s - 1) or ""
            local next = lower:sub(s + #kw, s + #kw)
            if not prev:match("[a-z]") and not next:match("[a-z]") then
                return true
            end
            from = s + #kw
        end
    end
    return lower:find(kw, 1, true) ~= nil
end

local function pick_image(images)
    if not images or #images == 0 then return nil end
    return images[math.random(#images)]
end

-- ====================================================================
-- on_message
-- ====================================================================
function on_message(event)
    local raw = (event.raw_message or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return false, nil end

    -- 群聊需要 @ 卷娘
    if event.message_type == "group" and not is_mentioned(raw) then
        return false, nil
    end

    local lower = raw:lower()

    for _, rule in ipairs(RULES) do
        for _, kw in ipairs(rule.keywords) do
            if match_kw(lower, kw) then
                local img = pick_image(rule.images)
                reply(event, rule.reply, img)
                jn.log.info(string.format("[redrock_special] %d 触发彩蛋: %s", event.user_id, kw))
                return true
            end
        end
    end

    return false, nil
end

jn.log.info("[redrock_special] 彩蛋插件已加载")
