-- ====================================================================
-- redrock_fanzha
-- 开学季反诈提醒插件
-- 命令：
--   /反诈提醒      向当前会话发送完整反诈指南图文
--   /全体反诈提醒  群聊中发送，指南前附加 @全体成员
-- 示意图 anticheat.jpg 需放在插件目录下（自动转 base64 发送）。
-- ====================================================================

local jn = require("jn")

local ENABLED = jn.config.get("enabled")

-- 反诈指南文本
local ANTI_FRAUD_TEXT = [[开学季是诈骗高发期，骗子的"KPI"可能就指望你了。请务必熟读这份反诈指南，守住你的学费和生活费！
一、警惕各类缴费陷阱
· 官方渠道是唯一标准：所有学费、住宿费等官方缴费，请务必以辅导员在官方班级群的通知和学校官网的渠道为准。
· 拒绝不明链接/二维码：任何通过私聊、短信发送的缴费链接或二维码，无论对方自称是谁，一律不要信、不要点、不要付！
· 警惕"威逼利诱"：任何以"不办卡/不交钱就无法报到、选课、进宿舍"为由头的收费，均为诈骗！
· 不要加入"新生群聊"：警惕任何邀请加入的"交流群""资料墙""勤工俭学群"，这些往往是推销高价课程、诱导贷款的骗局。
二、拒绝"天上掉馅饼"的诱惑
· 刷单兼职100%是诈骗：所有声称"动动手指、日入斗金"的刷单兼职，都是骗子设下的圈套。记住，任何需要你提前垫付资金的工作，都是陷阱！
· 远离非法"校园贷"：树立健康的消费观，切勿被"无抵押、低利息、秒到账"的宣传迷惑。如有资金需求，请务必咨询学校或正规金融机构。
· 警惕"免费"礼品：路边或宿舍推销中，以"创业学长/学姐"名义求支持、或扫码送礼品的，背后往往是高价推销或个人信息窃取的陷阱。请礼貌但坚定地拒绝。
三、守护你的个人信息与账号安全
· 警惕钓鱼邮件/网站：警惕任何自称"教务处"、"学校官方"的邮件。务必检查发件人邮箱地址，非 `@sdnu.edu.cn` 官方后缀的都是假的！骗子会用假冒页面骗取你的账号密码，你的QQ号也被骗子利用诈骗其他同学！
· QQ/微信好友借钱要核实：如果"好友"或"老同学"在社交软件上突然求助，并用各种理由借钱，请务必通过电话或视频直接确认！声音可以模仿，但视频通话很难伪装。
· 守住最后防线：身份证、银行卡、手机验证码是你的财产最后防线，绝不透露给任何人，更不要把手机交给陌生人操作！
四、卷娘的终极提醒
✅ 黄金法则：万事走官方渠道！ 遇到任何不确定的情况，第一时间联系你的辅导员或班导核实。
🆘 如果不幸被骗：不要慌张，更不要因为觉得丢脸而隐瞒。第一时间保留所有聊天记录、转账凭证等证据，并立即联系辅导员和大学城派出所报警！
以下是几种常见骗局的示意图，请牢记于心：]]

--- 发送反诈提醒图文
---@param event jn.Event
---@param at_all boolean 是否在文本前附加 @全体成员（仅群聊）
local function send_reminder(event, at_all)
    local image_file = jn.config.get("image_file") or "anticheat.jpg"
    local segments = {}
    if at_all then
        segments[#segments + 1] = { type = "at", data = { qq = "all" } }
    end
    segments[#segments + 1] = { type = "text",  data = { text = ANTI_FRAUD_TEXT } }
    segments[#segments + 1] = { type = "image", data = { file = image_file } }

    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, segments)
        jn.log.info(string.format("[redrock_fanzha] 已向群 %d 发送反诈提醒%s", event.group_id,
            at_all and "（@全体成员）" or ""))
    else
        jn.onebot11.send_private_msg(event.user_id, segments)
        jn.log.info(string.format("[redrock_fanzha] 已向 QQ %d 发送反诈提醒", event.user_id))
    end
end

--- /反诈提醒 命令：发送反诈指南图文
---@param args string[]
---@param event jn.Event
jn.command.register("反诈提醒", function(args, event)
    if ENABLED == false then
        return true, "反诈提醒功能未启用"
    end
    send_reminder(event, false)
    -- 已手动发送富文本，返回 consumed=true 阻止 Agent 处理
    return true, ""
end, {
    description = "发送开学季反诈提醒指南",
    usage = "/反诈提醒",
})

--- /全体反诈提醒 命令：发送 @全体成员 版反诈指南图文（仅群聊）
---@param args string[]
---@param event jn.Event
jn.command.register("全体反诈提醒", function(args, event)
    if ENABLED == false then
        return true, "反诈提醒功能未启用"
    end
    if event.message_type ~= "group" then
        return true, "该命令仅限群聊使用"
    end
    send_reminder(event, true)
    -- 已手动发送富文本，返回 consumed=true 阻止 Agent 处理
    return true, ""
end, {
    description = "发送@全体成员版反诈提醒（仅群聊）",
    usage = "/全体反诈提醒",
})

jn.log.info("[redrock_fanzha] 反诈提醒插件已加载")
