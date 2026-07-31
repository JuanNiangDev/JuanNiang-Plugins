-- ====================================================================
-- redrock_welcome
-- 红岩网校招新群欢迎插件（新手引导升级版）
-- 有新成员加入时，发送欢迎消息和快捷菜单。
-- ====================================================================

local jn = require("jn")

--- 监听群成员增加事件，发送欢迎语
---@param event jn.Event
function on_notice(event)
    if event.notice_type ~= "group_increase" then return end

    local user_id = event.user_id
    local group_id = event.group_id

    jn.onebot11.send_group_msg(group_id, {
        { type = "at",   data = { qq = tostring(user_id) } },
        { type = "text", data = { text = [[ 欢迎邮子来到红岩网校工作站招新群！🎉

卷娘给你准备了几个快捷入口，回复数字就能了解：
1️⃣ 红岩网校是什么？
2️⃣ 六个部门介绍
3️⃣ 最近有什么活动？
4️⃣ 常见问题（FAQ）
5️⃣ 玩个游戏放松一下

💡 小提示：有问题直接 @卷娘 + 关键词，比如「@卷娘 产品」「@卷娘 宣讲会」
🤫 卷娘的小秘密：试试问我一些奇怪的问题，有惊喜哦～]] } },
    })

    jn.log.info(string.format("[redrock_welcome] %d 加入群 %d，已发送引导", user_id, group_id))
end
