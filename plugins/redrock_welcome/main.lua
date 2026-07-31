-- ====================================================================
-- redrock_welcome
-- 红岩网校招新群欢迎插件
-- 有新成员加入时，发送欢迎消息和招新海报。
-- ====================================================================

local jn = require("jn")

--- 监听群成员增加事件，发送欢迎语
---@param event jn.Event
function on_notice(event)
    if event.notice_type ~= "group_increase" then return end

    local user_id = event.user_id
    local group_id = event.group_id

    jn.onebot11.send_group_msg(group_id, {
        { type = "at",    data = { qq = tostring(user_id) } },
        { type = "text",  data = { text = " 欢迎到来！这里是红岩网校工作站的新生群，有什么问题都可以问我哦！没有头绪就试试发送/redrock吧。" } },
        { type = "image", data = { file = "welcome.png" } },
    })

    jn.log.info(string.format("[redrock_welcome] %d 加入群 %d", user_id, group_id))
end
