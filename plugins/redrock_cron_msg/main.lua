-- ====================================================================
-- redrock_cron_msg
-- 定时向指定群发送消息
--
-- CronJob Payload 示例:
--   {
--     "groups": [123456, 789012],
--     "message": "今天晚上12点卷娘可要清理掉不按规矩改名的同学了哦！"
--   }
-- ====================================================================

local jn = require("jn")

function on_timer_call(event)
    local payload = event.payload or {}
    local groups = payload.groups
    local message = payload.message

    if not groups or #groups == 0 then
        jn.log.error("[cron_msg] payload 缺少 groups 数组")
        return
    end
    if not message or message == "" then
        jn.log.error("[cron_msg] payload 缺少 message")
        return
    end

    for _, gid in ipairs(groups) do
        jn.onebot11.send_group_msg(tonumber(gid), message)
        jn.log.info(string.format("[cron_msg] 已向群 %s 发送: %s", tostring(gid), message))
    end
end

jn.log.info("[redrock_cron_msg] 定时消息插件已加载")
