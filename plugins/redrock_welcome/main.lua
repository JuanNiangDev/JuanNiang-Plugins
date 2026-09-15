-- ====================================================================
-- redrock_welcome
-- 红岩网校招新群欢迎插件
-- 有新成员加入时先进缓冲区攒批：攒满 batch_size 人立即发送；
-- 首人入队起算 flush_seconds 秒未攒满也统一发送，避免逐条刷屏。
-- ====================================================================

local jn = require("jn")

local DEFAULT_BATCH_SIZE = 15     -- 攒满多少人立即发送
local DEFAULT_FLUSH_SECONDS = 3   -- 首人入队起算的发送窗口（秒）

-- 入群缓冲区：group_id -> { members = {user_id, ...}, seq = 代际号 }
-- LState 常驻、事件与 timer 回调串行派发，纯内存即可，无需加锁或持久化
local buffers = {}

--- 读取数值型配置（config.yaml 无 number 类型，用 string 存，非法值回退默认）
local function num_config(key, default)
    local n = tonumber(jn.config.get(key))
    return n or default
end

--- 发送一个群的欢迎缓冲；发送后清空缓冲并递增代际号，
--- 让仍在途的旧窗口 timer 到点后因 seq 不匹配空转（等效计时器清零）
local function flush(group_id)
    local buf = buffers[group_id]
    if not buf or #buf.members == 0 then return end

    local segments = {}
    for _, user_id in ipairs(buf.members) do
        segments[#segments + 1] = { type = "at", data = { qq = tostring(user_id) } }
    end
    segments[#segments + 1] = {
        type = "text",
        data = { text = jn.config.get("welcome_text")
            or " 欢迎到来！这里是红岩网校工作站的新生群，有什么问题都可以问我哦！没有头绪就试试发送/redrock吧。" },
    }
    segments[#segments + 1] = {
        type = "image",
        data = { file = jn.config.get("welcome_image") or "welcome.png" },
    }

    jn.onebot11.send_group_msg(group_id, segments)
    jn.log.info(string.format("[redrock_welcome] 群 %d 攒批欢迎 %d 名新成员", group_id, #buf.members))

    buf.members = {}
    buf.seq = buf.seq + 1
end

--- 监听群成员增加事件，攒批发送欢迎语
---@param event jn.Event
function on_notice(event)
    if event.notice_type ~= "group_increase" then return end
    if jn.config.get("enabled") == false then return end

    local group_id = event.group_id

    local buf = buffers[group_id]
    if not buf then
        buf = { members = {}, seq = 0 }
        buffers[group_id] = buf
    end
    buf.members[#buf.members + 1] = event.user_id

    if #buf.members >= num_config("batch_size", DEFAULT_BATCH_SIZE) then
        -- 攒满：立即发送；已排队的窗口 timer 到点后在 on_timer_response 里空转
        flush(group_id)
    elseif #buf.members == 1 then
        -- 本批首人：开启发送窗口计时
        local seconds = num_config("flush_seconds", DEFAULT_FLUSH_SECONDS)
        -- 提交失败（返回 0）时立即发送，退化为逐条即发，不丢欢迎
        local ok = (jn.timer and jn.timer.after(seconds, { group_id = group_id, seq = buf.seq })) or 0
        if ok == 0 then flush(group_id) end
    end
end

--- 引擎异步定时回调：发送窗口到点，统一发送本批欢迎（过期 timer 在此空转）
---@param req_id number jn.timer.after 的返回值
---@param ctx table|nil after 调用时传入的现场表 { group_id, seq }
---@param result any 未使用
---@param err string|nil 非 nil 表示定时器异常
function on_timer_response(req_id, ctx, result, err)
    if not ctx or not ctx.group_id then return end
    local buf = buffers[ctx.group_id]
    -- 代际号不匹配说明本批已因攒满提前发送，旧 timer 到点直接忽略
    if not buf or ctx.seq ~= buf.seq or #buf.members == 0 then return end
    if err and err ~= "" then
        jn.log.warn(string.format(
            "[redrock_welcome] 群 %d 发送窗口定时器异常: %s，仍发送缓冲", ctx.group_id, tostring(err)))
    end
    flush(ctx.group_id)
end
