-- ====================================================================
-- 戳一戳回复插件
-- 监听 on_notice(notify, poke) 事件，回复消息。
-- 支持判断戳的发送者和目标，避免戳自己时重复回复。
-- ====================================================================

local jn = require("jn")

-- 可自定义回复语列表
local REPLIES = {
    "别戳了别戳了！(〃＞＿＜;〃)",
    "戳我干嘛！",
    "再戳我要生气了！(#`Д´)ﾉ",
    "戳一戳已收到，已读不回。",
    "你戳我一下，我回你一下 🤏",
}

-- 机器人自身 QQ（惰性获取并缓存；配置 bot_qq 优先，否则 get_login_info）
local self_qq = nil
local self_qq_warned = false

local function get_self_qq()
    if self_qq then return self_qq end
    local cfg_qq = jn.config.get("bot_qq")
    if cfg_qq and tostring(cfg_qq) ~= "" then
        self_qq = tonumber(cfg_qq)
        return self_qq
    end
    local info, _ = jn.onebot11.get_login_info()
    if info and info.user_id then
        self_qq = tonumber(info.user_id)
        return self_qq
    end
    if not self_qq_warned then
        self_qq_warned = true
        jn.log.warn("[poke-reply] 获取机器人QQ失败，戳一戳回复暂时停用，可在配置中指定 bot_qq")
    end
    return nil
end

---@param event jn.Event
function on_notice(event)
    -- 戳一戳事件：notice_type = "notify", sub_type = "poke"
    if event.notice_type ~= "notify" or event.sub_type ~= "poke" then
        return
    end

    -- 是否启用戳一戳回复
    if jn.config.get("enable_poke_reply") == false then
        return
    end

    -- 只响应"被戳对象是机器人自己"的戳一戳：
    -- OneBot11 poke 事件中 user_id=戳人者，target_id=被戳者。
    -- target_id 缺失（=0）或不是机器人自己时直接忽略，避免误回戳别人的戳一戳。
    local bot_qq = get_self_qq()
    if not bot_qq then return end
    local target = tonumber(event.target_id)
    if not target or target ~= bot_qq then return end

    local from_qq = event.user_id       -- 发起戳一戳的人
    local to_qq = event.target_id       -- 被戳的人（机器人自己）
    local group_id = event.group_id

    if group_id == 0 then
        return  -- 私聊戳一戳暂不处理（私聊戳一戳通常没有 group_id）
    end

    -- 读取自定义回复语列表，为空则使用内置默认
    local replies = jn.config.get("replies")
    if type(replies) ~= "table" or #replies == 0 then
        replies = REPLIES
    end

    -- 随机选一条回复
    local reply_text = replies[math.random(#replies)]

    -- 是否 @ 发起戳一戳的人，用 CQ 码 @
    local msg
    if jn.config.get("mention_sender") then
        msg = string.format("[CQ:at,qq=%d] %s", from_qq, reply_text)
    else
        msg = reply_text
    end
    jn.onebot11.send_group_msg(group_id, msg)

    jn.log.info(string.format("[poke-reply] %d 戳了 %d 在群 %d", from_qq, to_qq, group_id))
end
