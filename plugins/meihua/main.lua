-- ====================================================================
-- meihua 梅花易数占卜插件
-- --------------------------------------------------------------------
-- 移植自 astrbot_plugin_meihua (985892345)，算法与输出格式与原版逐行对齐：
--   /梅花 <问题>            → 随机 3-6 位数字起卦
--   /梅花 <两位以上数字> <问题> → 指定数字起卦
-- 起卦纯本地计算（先天八卦数），卦象文本先回复，再经主程序 LLM（jn.llm）
-- 异步断卦，回调里剥掉 Markdown 标记后补发（QQ 纯文本环境不吃 Markdown）。
-- 断卦提示词可在面板 config.judge_prompt 修改。
-- ====================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

-- --------------------------------------------------------------------
-- 八卦数据（先天八卦数：乾1 兑2 离3 震4 巽5 坎6 艮7 坤8）
-- --------------------------------------------------------------------
local BAGUA = { [1] = "乾", [2] = "兑", [3] = "离", [4] = "震", [5] = "巽", [6] = "坎", [7] = "艮", [8] = "坤" }
local BAGUA_SYMBOL = {["乾"] = "☰",["兑"] = "☱",["离"] = "☲",["震"] = "☳",["巽"] = "☴",["坎"] = "☵",["艮"] = "☶",["坤"] = "☷" }
-- 三爻卦的爻象（1 阳爻 / 0 阴爻，自下而上）
local BAGUA_YAO = {
    [1] = { 1, 1, 1 }, [2] = { 1, 1, 0 }, [3] = { 1, 0, 1 }, [4] = { 1, 0, 0 },
    [5] = { 0, 1, 1 }, [6] = { 0, 1, 0 }, [7] = { 0, 0, 1 }, [8] = { 0, 0, 0 },
}

-- 六十四卦名表：GUA64[上卦][下卦]（x 为上、y 为下，与原版 gua_64 一致）
local GUA64 = {
    ["乾"] = {["乾"] = "乾为天",["兑"] = "天泽履",["离"] = "天火同人",["震"] = "天雷无妄",["巽"] = "天风姤",["坎"] = "天水讼",["艮"] = "天山遁",["坤"] = "天地否" },
    ["兑"] = {["乾"] = "泽天夬",["兑"] = "兑为泽",["离"] = "泽火革",["震"] = "泽雷随",["巽"] = "泽风大过",["坎"] = "泽水困",["艮"] = "泽山咸",["坤"] = "泽地萃" },
    ["离"] = {["乾"] = "火天大有",["兑"] = "火泽睽",["离"] = "离为火",["震"] = "火雷噬嗑",["巽"] = "火风鼎",["坎"] = "火水未济",["艮"] = "火山旅",["坤"] = "火地晋" },
    ["震"] = {["乾"] = "雷天大壮",["兑"] = "雷泽归妹",["离"] = "雷火丰",["震"] = "震为雷",["巽"] = "雷风恒",["坎"] = "雷水解",["艮"] = "雷山小过",["坤"] = "雷地豫" },
    ["巽"] = {["乾"] = "风天小畜",["兑"] = "风泽中孚",["离"] = "风火家人",["震"] = "风雷益",["巽"] = "巽为风",["坎"] = "风水涣",["艮"] = "风山渐",["坤"] = "风地观" },
    ["坎"] = {["乾"] = "水天需",["兑"] = "水泽节",["离"] = "水火既济",["震"] = "水雷屯",["巽"] = "水风井",["坎"] = "坎为水",["艮"] = "水山蹇",["坤"] = "水地比" },
    ["艮"] = {["乾"] = "山天大畜",["兑"] = "山泽损",["离"] = "山火贲",["震"] = "山雷颐",["巽"] = "山风蛊",["坎"] = "山水蒙",["艮"] = "艮为山",["坤"] = "山地剥" },
    ["坤"] = {["乾"] = "地天泰",["兑"] = "地泽临",["离"] = "地火明夷",["震"] = "地雷复",["巽"] = "地风升",["坎"] = "地水师",["艮"] = "地山谦",["坤"] = "坤为地" },
}

local function gua_name(upper, lower)
    local t = GUA64[upper]
    return (t and t[lower]) or "未知卦"
end

-- 三爻爻象 → 先天卦数（找不到时默认乾 1，与原版 yao_to_gua 一致）
local YAO2GUA = {}
for num, yao in pairs(BAGUA_YAO) do
    YAO2GUA[table.concat(yao)] = num
end
local function yao_to_gua(yao)
    return YAO2GUA[table.concat(yao)] or 1
end

-- --------------------------------------------------------------------
-- 起卦算法（与原版 meihua_by_number 逐行对齐）
-- --------------------------------------------------------------------
local function meihua_by_number(number)
    local len = #number
    local upper, lower, moving
    if len == 2 then
        -- 两位：第一位为上卦，第二位为下卦，两位之余 6 则为动爻
        upper = tonumber(number:sub(1, 1))
        lower = tonumber(number:sub(2, 2))
        moving = tonumber(number) % 6
    elseif len == 3 then
        -- 三位：前两位为上下卦，第三位为动爻
        upper = tonumber(number:sub(1, 1))
        lower = tonumber(number:sub(2, 2))
        moving = tonumber(number:sub(3, 3))
    else
        -- 四位及以上：前一半为上卦，后一半为下卦，所有数之和为动爻
        local mid = math.floor(len / 2)
        upper, lower, moving = 0, 0, 0
        for i = 1, len do
            local d = tonumber(number:sub(i, i))
            if i <= mid then upper = upper + d else lower = lower + d end
            moving = moving + d
        end
    end

    local function mod8(n) return (n - 1) % 8 + 1 end
    local function mod6(n) return (n - 1) % 6 + 1 end
    local ug, lg, mg = mod8(upper), mod8(lower), mod6(moving)

    local full = {}                          -- 六爻，index 1 = 初爻；下卦在前
    for i = 1, 3 do full[i] = BAGUA_YAO[lg][i] end
    for i = 1, 3 do full[3 + i] = BAGUA_YAO[ug][i] end

    -- 互卦：234 爻为下卦，345 爻为上卦
    local hu_lower = { full[2], full[3], full[4] }
    local hu_upper = { full[3], full[4], full[5] }

    -- 变卦：动爻阴阳互换（Lua 下标从 1 起，动爻 mg 正好对应 full[mg]）
    local bian = {}
    for i = 1, 6 do bian[i] = full[i] end
    bian[mg] = 1 - bian[mg]
    local bian_lower = { bian[1], bian[2], bian[3] }
    local bian_upper = { bian[4], bian[5], bian[6] }

    -- 综卦：整卦倒转（初爻变上爻）
    local zong = { full[6], full[5], full[4], full[3], full[2], full[1] }
    local zong_lower = { zong[1], zong[2], zong[3] }
    local zong_upper = { zong[4], zong[5], zong[6] }

    -- 错卦：所有爻阴阳互换
    local cuo = {}
    for i = 1, 6 do cuo[i] = 1 - full[i] end
    local cuo_lower = { cuo[1], cuo[2], cuo[3] }
    local cuo_upper = { cuo[4], cuo[5], cuo[6] }

    -- 体用：动爻在 1-3 爻下卦为用上卦为体；4-6 爻相反
    local ti_label = mg <= 3 and "体" or "用"
    local yong_label = mg <= 3 and "用" or "体"

    local function nm(gua_num) return BAGUA[gua_num] .. BAGUA_SYMBOL[BAGUA[gua_num]] end

    local out = {}
    out[#out + 1] = string.format("%s %s %s %s %s %s",
        ti_label, nm(ug), nm(yao_to_gua(hu_upper)), nm(yao_to_gua(bian_upper)),
        nm(yao_to_gua(zong_upper)), nm(yao_to_gua(cuo_upper)))
    out[#out + 1] = string.format("%s %s %s %s %s %s",
        yong_label, nm(lg), nm(yao_to_gua(hu_lower)), nm(yao_to_gua(bian_lower)),
        nm(yao_to_gua(zong_lower)), nm(yao_to_gua(cuo_lower)))
    out[#out + 1] = string.format("动爻：第%d爻", mg)
    out[#out + 1] = "本卦：" .. gua_name(BAGUA[ug], BAGUA[lg])
    out[#out + 1] = "互卦：" .. gua_name(BAGUA[yao_to_gua(hu_upper)], BAGUA[yao_to_gua(hu_lower)])
    out[#out + 1] = "变卦：" .. gua_name(BAGUA[yao_to_gua(bian_upper)], BAGUA[yao_to_gua(bian_lower)])
    out[#out + 1] = "错卦：" .. gua_name(BAGUA[yao_to_gua(cuo_upper)], BAGUA[yao_to_gua(cuo_lower)])
    out[#out + 1] = "综卦：" .. gua_name(BAGUA[yao_to_gua(zong_upper)], BAGUA[yao_to_gua(zong_lower)])
    return table.concat(out, "\n")
end

-- --------------------------------------------------------------------
-- Markdown 剥离（LLM 输出进 QQ 纯文本前清理）
-- --------------------------------------------------------------------
local function strip_markdown(s)
    if not s then return "" end
    s = tostring(s)
    s = s:gsub("```%w*\r?\n?", "")          -- 代码块围栏（带语言标记）
    s = s:gsub("```", "")
    s = s:gsub("`([^`]*)`", "%1")            -- 行内代码
    s = s:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")   -- 图片 → alt
    s = s:gsub("%[([^%]]*)%]%(([^%)]+)%)", "%1（%2）") -- 链接 → 文字（url）
    s = s:gsub("%*%*%*([^%*]+)%*%*%*", "%1") -- 粗斜体
    s = s:gsub("%*%*([^%*]+)%*%*", "%1")     -- 粗体
    s = s:gsub("%*([^%*\n]+)%*", "%1")       -- 斜体
    s = s:gsub("___([^_]+)___", "%1")
    s = s:gsub("__([^_]+)__", "%1")
    s = s:gsub("~~([^~]+)~~", "%1")          -- 删除线
    s = s:gsub("==([^=]+)==", "%1")          -- 高亮
    s = s:gsub("\r\n", "\n")
    -- 逐行清理行首标记（标题 #、引用 >、水平线 ---）
    local lines = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("^#+%s+", "")
        line = line:gsub("^>%s?", "")
        if not line:match("^%-%s*%-*%s*%-*$") or line == "" then
            lines[#lines + 1] = line
        end
    end
    s = table.concat(lines, "\n")
    s = s:gsub("\n\n\n+", "\n\n")
    return s
end

-- --------------------------------------------------------------------
-- LLM 断卦（异步：chat_async → on_chat_response 回调补发）
-- --------------------------------------------------------------------
local llm_ctx = {} -- req_id → {message_type, group_id, user_id}

local function llm_ready()
    return jn.llm ~= nil and jn.llm.available and jn.llm.available()
end

function on_chat_response(req_id, content, err)
    local ctx = llm_ctx[req_id]
    if not ctx then return end
    llm_ctx[req_id] = nil
    local text
    if err then
        text = "错误：梅花插件大模型调用失败: " .. tostring(err)
    else
        text = strip_markdown(content)
        if text == "" then text = "断卦结果为空，请重试" end
    end
    if ctx.message_type == "group" then
        jn.onebot11.send_group_msg(ctx.group_id, text)
    else
        jn.onebot11.send_private_msg(ctx.user_id, text)
    end
end

-- --------------------------------------------------------------------
-- /梅花 命令
-- --------------------------------------------------------------------
local function sender_name(event)
    local s = event.sender
    if type(s) == "table" then
        if s.card and s.card ~= "" then return tostring(s.card) end
        if s.nickname and s.nickname ~= "" then return tostring(s.nickname) end
    end
    return tostring(event.user_id or "未知")
end

local DEFAULT_JUDGE_PROMPT = "你擅长各种玄学占卜，请使用梅花易数详细分析下求卦者的现状、过程、结果以及可能会发生的状况，要求 200 字以内。直接输出纯文本，不要使用任何 Markdown 标记（不要 **、#、`、列表符号等）。"

jn.command.register("梅花", function(args, event)
    local number, question, is_random = "", "未提供问题", false
    if args[1] and args[1]:match("^%d+$") then
        number = args[1]
        if #number < 2 then
            return true, "错误：数字位数不能小于两位，当前数字为 " .. number
        end
        if #args > 1 then question = table.concat(args, " ", 2) end
    else
        -- 未提供纯数字：随机生成 3-6 位数字（允许 0 开头，与原版一致）
        local t = {}
        for _ = 1, math.random(3, 6) do t[#t + 1] = tostring(math.random(0, 9)) end
        number = table.concat(t)
        is_random = true
        if #args > 0 then question = table.concat(args, " ") end
    end

    local text = "🌸 梅花易数占卜 🌸\n"
        .. "问卜者：" .. sender_name(event) .. "\n"
        .. "问题：" .. question .. "\n"
        .. "起卦数字：" .. number .. (is_random and " (随机)" or "") .. "\n"
        .. "--------------------\n"
        .. meihua_by_number(number)

    if not llm_ready() then
        return true, text .. "\n（当前无可用文本模型，仅起卦不断卦）"
    end

    local prompt = jn.config.get("judge_prompt")
    if not prompt or prompt == "" then prompt = DEFAULT_JUDGE_PROMPT end
    local rid = jn.llm.chat_async({
        { role = "system", content = prompt },
        { role = "user", content = text },
    }, { timeout = 90 }) -- 不设 max_tokens：glm-5.3-flash 是思考模型，
    -- max_tokens 过小会被 reasoning_content 吃光导致 content 为空；缺省回退 Bot Provider 配置
    if not rid or rid == 0 then
        return true, text .. "\n（断卦任务提交失败，请稍后重试）"
    end
    llm_ctx[rid] = {
        message_type = event.message_type,
        group_id = event.group_id,
        user_id = event.user_id,
    }
    return true, text .. "\n\n大模型断卦中..."
end, {
    description = "梅花易数占卜：起卦并 LLM 断卦",
    usage = "/梅花 <问题> 或 /梅花 <两位以上数字> <问题>",
})

jn.log.info("[meihua] 梅花易数占卜插件已加载")
