-- ====================================================================
-- turtle_soup 海龟汤（情境推理）插件
-- --------------------------------------------------------------------
-- 移植自 lanmei-dream internal/bizplugin/turtle_soup.go，规则一致：
--   /开汤（别名 /海龟汤）→ LLM 生成一局谜题：汤面公开、汤底隐藏
--   /问 <问题>  → 主持人只回答 是 / 否 / 无关，不作任何补充
--   /猜 <猜测>  → 命中才揭晓结算；未命中只给固定的"方向正确/猜错了"
--                 整体判断（LLM 只输出布尔值，杜绝泄露汤底细节）
--   /认输（别名 /放弃 /看汤底 /汤底）→ 直接揭晓汤底
-- 防混乱约束：同一群/私聊同时只能开一局；未结束前 /开汤 被拒绝；
-- 局超过 12 小时自动作废；同一聊天同时只有一个异步 LLM 任务。
-- 状态存 jn.cache（Redis，12h TTL，重启不丢）；cache 不可用时退化为
-- 进程内存（重载/重启后丢失进行中的局）。
-- ====================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

local GAME_TTL = 12 * 3600 -- 局的最长寿命（秒），与 lanmei 一致

-- --------------------------------------------------------------------
-- Markdown 剥离（LLM 输出进 QQ 纯文本前清理）
-- --------------------------------------------------------------------
local function strip_markdown(s)
    if not s then return "" end
    s = tostring(s)
    s = s:gsub("```%w*\r?\n?", "")
    s = s:gsub("```", "")
    s = s:gsub("`([^`]*)`", "%1")
    s = s:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")
    s = s:gsub("%[([^%]]*)%]%(([^%)]+)%)", "%1（%2）")
    s = s:gsub("%*%*%*([^%*]+)%*%*%*", "%1")
    s = s:gsub("%*%*([^%*]+)%*%*", "%1")
    s = s:gsub("%*([^%*\n]+)%*", "%1")
    s = s:gsub("___([^_]+)___", "%1")
    s = s:gsub("__([^_]+)__", "%1")
    s = s:gsub("~~([^~]+)~~", "%1")
    s = s:gsub("==([^=]+)==", "%1")
    s = s:gsub("\r\n", "\n")
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

-- 从 LLM 输出中提取 JSON 串（容错：剥离代码块围栏后取首尾大括号）
local function extract_json(s)
    if not s or s == "" then return nil end
    s = s:gsub("```%w*", ""):gsub("```", "")
    local a = s:find("{", 1, true)
    if not a then return nil end
    local b
    for i = #s, a, -1 do
        if s:sub(i, i) == "}" then b = i break end
    end
    if not b or b <= a then return nil end
    return s:sub(a, b)
end

-- --------------------------------------------------------------------
-- 局状态：内存为主，cache 尽力持久化（重启恢复）
-- --------------------------------------------------------------------
local games = {}     -- chat_key → game 表
local in_flight = {} -- chat_key → true（同一聊天同时只允许一个异步 LLM 任务）

local function chat_key(event)
    if event.message_type == "group" then
        return "g" .. tostring(event.group_id)
    end
    return "u" .. tostring(event.user_id)
end

local function cache_get(key)
    if not jn.cache then return nil end
    local ok, v = pcall(jn.cache.get, key)
    if not ok then return nil end
    return v
end

local function cache_set(key, value, ttl)
    if not jn.cache then return end
    pcall(jn.cache.set, key, value, ttl)
end

local function cache_del(key)
    if not jn.cache then return end
    pcall(jn.cache.del, key)
end

local CK_PREFIX = "game:"

local function game_load(key)
    local g = games[key]
    if g == nil then
        g = cache_get(CK_PREFIX .. key) -- 重启后从 Redis 恢复
        if g ~= nil then games[key] = g end
    end
    if g == nil then return nil end
    if type(g) ~= "table" or not g.face or not g.base then
        games[key] = nil
        cache_del(CK_PREFIX .. key)
        return nil
    end
    if os.time() - (g.created or 0) > GAME_TTL then
        games[key] = nil
        cache_del(CK_PREFIX .. key)
        return nil
    end
    return g
end

local function game_save(key, g)
    games[key] = g
    cache_set(CK_PREFIX .. key, g, GAME_TTL)
end

local function game_clear(key)
    games[key] = nil
    cache_del(CK_PREFIX .. key)
end

-- --------------------------------------------------------------------
-- 发送与 LLM
-- --------------------------------------------------------------------
local function send_to(ctx, text)
    if ctx.message_type == "group" then
        jn.onebot11.send_group_msg(ctx.group_id, text)
    else
        jn.onebot11.send_private_msg(ctx.user_id, text)
    end
end

local function llm_ready()
    return jn.llm ~= nil and jn.llm.available and jn.llm.available()
end

-- 异步任务上下文：req_id → 回调现场
local llm_ctx = {}

local function chat_json(system, user, ctx)
    local rid = jn.llm.chat_async({
        { role = "system", content = system },
        { role = "user", content = user },
    }, { timeout = 90 }) -- 不设 max_tokens：glm-5.3-flash 是思考模型，max_tokens 过小会被
    -- reasoning_content 吃光导致 content 为空；缺省回退 Bot Provider 配置
    if not rid or rid == 0 then return false end
    llm_ctx[rid] = ctx
    return true
end

-- --------------------------------------------------------------------
-- 汤底风格（/开汤 可指定；不指定则从安全池随机）
-- --------------------------------------------------------------------
-- 安全风格池：随机汤底只从这里选
local SOUP_STYLES = {
  { alias = "清汤", names = { "清汤", "白汤" },
    desc = "日常生活细节、误会、冷知识或视线盲区，完全不涉及暴力或死伤" },
  { alias = "暖汤", names = { "暖汤", "甜汤", "粉汤" },
    desc = "结局温馨治愈或浪漫，核心是亲情、默默的爱意、善意的谎言或可爱的巧合，无恐怖元素" },
  { alias = "沙雕汤", names = { "沙雕汤", "搞笑汤", "绿汤" },
    desc = "幽默荒诞、无厘头反转或谐音梗，猜中后令人会心一笑" },
  { alias = "硬核逻辑汤", names = { "硬核逻辑汤", "推理汤" },
    desc = "严密的因果链与本格推理，注重物理机关、时间差、视角盲区或精确动线" },
  { alias = "脑洞汤", names = { "脑洞汤", "奇幻汤", "科幻汤" },
    desc = "超现实设定，如超能力、时空穿越、AI 觉醒、规则怪谈，需跳出现实常理还原世界观" },
  { alias = "文字游戏汤", names = { "文字游戏汤", "梗汤", "双关汤" },
    desc = "谜底依托汤面的字面陷阱、同音错觉、歧义修辞或行业黑话" },
  { alias = "悬疑汤", names = { "悬疑汤", "惊悚汤" },
    desc = "悬念铺设与反常情境，允许适当的紧张氛围与轻度恐怖，但不得出现血腥、暴力或死亡描写" },
}

-- 违禁风格：用户点名这些直接拒绝（扭曲伦理/人性、精神摧残、血腥、暴力、色情、敏感时政）
local FORBIDDEN_WORDS = {
  "红汤", "黑汤", "暗黑汤", "变态汤", "猎奇汤", "重口",
  "血腥", "暴力", "凶杀", "杀人", "自杀", "尸体", "虐杀",
  "色情", "擦边", "性爱", "情色",
  "扭曲", "精神污染", "精神摧残", "反伦理", "伦理禁忌",
  "时政", "政治", "敏感话题",
}

-- 归一化用户输入：去空白、去掉尾部"汤"以外的冗余后再比对
local function normalize_style(input)
  local s = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

-- 判断是否违禁：整词与别名（含不带"汤"字的简称，如 /开汤 红）都拦
local function is_forbidden_style(raw)
  local s = normalize_style(raw)
  if s == "" then return false end
  local bare = s:gsub("汤$", "")
  for _, w in ipairs(FORBIDDEN_WORDS) do
    if s == w or s:find(w, 1, true) then return true end
    local wbare = w:gsub("汤$", "")
    if #wbare > 0 and (bare == wbare or s == w) then return true end
  end
  return false
end

-- 按别名/别名简称找安全风格（清汤/白/暖/甜/粉/沙雕/搞笑/绿/推理/脑洞/梗/悬疑…）
local function find_safe_style(raw)
  local s = normalize_style(raw)
  if s == "" then return nil end
  local bare = s:gsub("汤$", "")
  for _, st in ipairs(SOUP_STYLES) do
    for _, name in ipairs(st.names) do
      local nbare = name:gsub("汤$", "")
      if s == name or bare == nbare then return st end
    end
  end
  return nil
end

local function pick_random_style()
  return SOUP_STYLES[math.random(#SOUP_STYLES)]
end

-- 出题提示词：style 为已解析的风格描述（安全池条目 desc 或用户自定义文本）
local function prompt_generate(style)
    local style_line = ""
    if style and style ~= "" then
        style_line = "\n本局汤底风格要求（必须贴合）：" .. style .. "\n"
    end
    return [[你是一个海龟汤（情境推理谜题）出题人。请生成一个经典风格的海龟汤谜题：]] .. style_line .. [[
- 汤面（soup_face）：简短、离奇、让人困惑的情境描述（1-3 句话），只陈述现象，不含任何解释
- 汤底（soup_base）：完整合理的真相（1-3 句话），能自洽解释汤面
- 判定要点（hints）：供主持人回答"是/否/无关"时参考的关键事实列表（2-4 条，严禁出现完整答案）
内容红线（任何风格都必须遵守）：不得涉及血腥、暴力、凶杀、自杀、扭曲伦理或人性、精神摧残或污染、色情或擦边、敏感时政；适合校园群聊；可以有适当的悬念与轻度惊悚。谜题要有趣且逻辑自洽；全部字段使用纯文本，不要使用任何 Markdown 标记。
仅输出 JSON，不要其他内容：{"soup_face":"...","soup_base":"...","hints":["...","..."]}]]
end

local function prompt_judge(g, question)
    local sb = {}
    sb[#sb + 1] = "你正在主持一个海龟汤（情境推理）游戏，只回答 是/否/无关。\n"
    sb[#sb + 1] = "汤面：" .. g.face .. "\n"
    sb[#sb + 1] = "汤底：" .. g.base .. "\n"
    if g.hints and #g.hints > 0 then
        sb[#sb + 1] = "判定要点：" .. table.concat(g.hints, "；") .. "\n"
    end
    if g.qa and #g.qa > 0 then
        sb[#sb + 1] = "\n玩家已提问（历史）：\n"
        for i, qa in ipairs(g.qa) do
            sb[#sb + 1] = string.format("%d. 问：%s → 答：%s\n", i, qa.q, qa.a)
        end
    end
    sb[#sb + 1] = "\n玩家最新提问：" .. question .. "\n\n"
    sb[#sb + 1] = [[判定规则：
- "是"：提问符合汤底描述
- "否"：提问与汤底矛盾
- "无关"：提问无法从汤底判断或与游戏无关
严格只回答 是 / 否 / 无关 三者之一，严禁附加任何解释、提示或多余文字。
仅输出 JSON：{"answer":"是"}]]
    return table.concat(sb)
end

local function prompt_guess_system()
    return [[你是海龟汤主持人，判断玩家的猜测是否命中汤底。判定标准（从严执行）：
- 猜对（correct=true）：猜测必须完整覆盖汤底的核心因果链与关键事实（谁做了什么、如何导致汤面现象），允许措辞不同，但不得遗漏关键环节
- 大方向正确（direction=true）：猜测的总体思路/切入角度与汤底大方向一致（如围绕同一主题、同一类成因），但关键事实或因果仍有缺失或错误。direction 只表达大方向对不对，是整体判断，不针对汤底任何具体元素
- 大方向错误（direction=false）：猜测的主题、成因类型与汤底南辕北辙，或过于含糊无法判断方向
注意：direction=true 不等于猜对；宁可整体从严，拿不准时 direction=false。
严禁输出任何解释、提示或与汤底内容相关的信息，只输出判定结果。]]
end

-- --------------------------------------------------------------------
-- 异步回调（引擎级注册表 kind "chat"）
-- --------------------------------------------------------------------
function on_chat_response(req_id, content, err)
    local ctx = llm_ctx[req_id]
    if not ctx then return end
    llm_ctx[req_id] = nil
    in_flight[ctx.key] = nil

    if err then
        if ctx.kind == "open" then game_clear(ctx.key) end
        send_to(ctx, "海龟汤 LLM 调用失败：" .. tostring(err))
        return
    end

    local raw = extract_json(content)

    if ctx.kind == "open" then
        local ok, gen = pcall(jn.json.decode, raw or "")
        if not ok or type(gen) ~= "table" or not gen.soup_face or gen.soup_face == ""
            or not gen.soup_base or gen.soup_base == "" then
            game_clear(ctx.key)
            send_to(ctx, "起汤失败：LLM 返回的谜题不完整，请重新 /开汤")
            return
        end
        local g = {
            face = strip_markdown(gen.soup_face),
            base = strip_markdown(gen.soup_base),
            hints = type(gen.hints) == "table" and gen.hints or {},
            qa = {},
            created = os.time(),
        }
        game_save(ctx.key, g)
        send_to(ctx, "🐢 海龟汤开汤！\n"
            .. "【汤面】" .. g.face .. "\n"
            .. "———————\n"
            .. "/问 <问题>：主持人只答 是/否/无关\n"
            .. "/猜 <推理>：直接猜汤底，猜中结算\n"
            .. "/认输：揭晓汤底")
        return
    end

    if ctx.kind == "ask" then
        local g = game_load(ctx.key)
        if g == nil then
            send_to(ctx, "当前没有进行中的海龟汤（本局可能已超时结束）")
            return
        end
        local ok, jd = pcall(jn.json.decode, raw or "")
        local answer = "无关"
        if ok and type(jd) == "table" then
            if jd.answer == "是" or jd.answer == "否" then
                answer = jd.answer
            end
        end
        g.qa = g.qa or {}
        g.qa[#g.qa + 1] = { q = ctx.question, a = answer }
        game_save(ctx.key, g)
        send_to(ctx, "❓ " .. ctx.question .. "\n答：" .. answer)
        return
    end

    if ctx.kind == "guess" then
        local g = game_load(ctx.key)
        if g == nil then
            send_to(ctx, "当前没有进行中的海龟汤（本局可能已超时结束）")
            return
        end
        local ok, jd = pcall(jn.json.decode, raw or "")
        local correct = ok and type(jd) == "table" and jd.correct == true
        local direction = ok and type(jd) == "table" and jd.direction == true
        if correct then
            game_clear(ctx.key)
            send_to(ctx, "🎉 恭喜你猜中了！本局结束。\n"
                .. "【汤面】" .. g.face .. "\n"
                .. "【汤底】" .. g.base .. "\n"
                .. "再开一局请 /开汤")
        elseif direction then
            send_to(ctx, "👉 方向正确，继续！")
        else
            send_to(ctx, "❌ 猜错了，再想想！")
        end
        return
    end
end

-- --------------------------------------------------------------------
-- 命令
-- --------------------------------------------------------------------
local function cmd_open(args, event)
    local style_arg = table.concat(args, " ")
    local style_desc, style_label

    if style_arg ~= "" then
        -- 违禁汤底：直接拒绝（点名红汤/黑汤/变态汤等或包含血腥/暴力/色情/时政等字样）
        if is_forbidden_style(style_arg) then
            return true, "🚫 这个汤底不接：血腥、暴力、扭曲伦理、精神污染、色情、敏感时政类统统不煮。\n"
                .. "可以试试：清汤、暖汤、沙雕汤、悬疑汤、推理汤、脑洞汤、梗汤，或任意自定义安全风格～"
        end
        local known = find_safe_style(style_arg)
        if known then
            style_desc, style_label = known.desc, known.alias
        else
            -- 自定义风格：原文交给 LLM，红线由出题提示词的内容约束兜底
            style_desc, style_label = style_arg, style_arg
        end
    else
        local known = pick_random_style()
        style_desc, style_label = known.desc, known.alias
    end

    local key = chat_key(event)
    if game_load(key) ~= nil then
        return true, "本群已有进行中的海龟汤，用 /问 /猜 继续，或 /认输 结束"
    end
    if in_flight[key] then
        return true, "上一碗汤还在煮，请稍候"
    end
    if not llm_ready() then
        return true, "需要 LLM 才能开汤，请先在面板启用文本模型"
    end
    in_flight[key] = true
    local ok = chat_json(prompt_generate(style_desc), "请生成一局海龟汤。",
        { kind = "open", key = key, style = style_label, message_type = event.message_type,
          group_id = event.group_id, user_id = event.user_id })
    if not ok then
        in_flight[key] = nil
        return true, "起汤任务提交失败，请稍后重试"
    end
    return true, "🔮 正在起一锅「" .. style_label .. "」，稍等片刻…"
end

local function cmd_ask(args, event)
    local question = table.concat(args, " ")
    if question == "" then
        return true, "用法：/问 <问题>"
    end
    local key = chat_key(event)
    if game_load(key) == nil then
        return true, "当前没有进行中的海龟汤，先 /开汤 吧"
    end
    if in_flight[key] then
        return true, "主持人还在处理上一条，稍等"
    end
    if not llm_ready() then
        return true, "需要 LLM 才能主持海龟汤，请先在面板启用文本模型"
    end
    in_flight[key] = true
    local g = game_load(key)
    local ok = chat_json("你是海龟汤主持人，回答必须严格基于汤底事实。", prompt_judge(g, question),
        { kind = "ask", key = key, question = question, message_type = event.message_type,
          group_id = event.group_id, user_id = event.user_id })
    if not ok then
        in_flight[key] = nil
        return true, "提问任务提交失败，请稍后重试"
    end
    return true, "🤔 主持人思考中…"
end

local function cmd_guess(args, event)
    local guess = table.concat(args, " ")
    if guess == "" then
        return true, "用法：/猜 <你的推理>"
    end
    local key = chat_key(event)
    if game_load(key) == nil then
        return true, "当前没有进行中的海龟汤，先 /开汤 吧"
    end
    if in_flight[key] then
        return true, "主持人还在处理上一条，稍等"
    end
    if not llm_ready() then
        return true, "需要 LLM 才能主持海龟汤，请先在面板启用文本模型"
    end
    in_flight[key] = true
    local g = game_load(key)
    local ok = chat_json(prompt_guess_system(),
        "汤底：" .. g.base .. "\n\n玩家猜测：" .. guess .. "\n\n仅输出 JSON：{\"correct\":false,\"direction\":false}",
        { kind = "guess", key = key, message_type = event.message_type,
          group_id = event.group_id, user_id = event.user_id })
    if not ok then
        in_flight[key] = nil
        return true, "判定任务提交失败，请稍后重试"
    end
    return true, "🤔 主持人思考中…"
end

local function cmd_give_up(event)
    local key = chat_key(event)
    local g = game_load(key)
    if g == nil then
        return true, "当前没有进行中的海龟汤"
    end
    game_clear(key)
    return true, "🍜 本局结束，汤底揭晓：\n"
        .. "【汤面】" .. g.face .. "\n"
        .. "【汤底】" .. g.base .. "\n"
        .. "再开一局请 /开汤"
end

jn.command.register("开汤", function(args, event) return cmd_open(args, event) end, {
    description = "海龟汤：开一局新汤（LLM 出题，汤底保密）",
    usage = "/开汤 [汤底类型]（不指定则随机；如 /开汤 暖汤 /开汤 推理汤）",
})
jn.command.register("海龟汤", function(args, event) return cmd_open(args, event) end, {
    description = "/开汤 的别名：开一局海龟汤",
    usage = "/海龟汤 [汤底类型]",
})
jn.command.register("问", function(args, event) return cmd_ask(args, event) end, {
    description = "海龟汤：向主持人提问，只答 是/否/无关",
    usage = "/问 <问题>",
})
jn.command.register("猜", function(args, event) return cmd_guess(args, event) end, {
    description = "海龟汤：猜汤底，猜中结算揭晓",
    usage = "/猜 <你的推理>",
})
jn.command.register("认输", function(_, event) return cmd_give_up(event) end, {
    description = "海龟汤：认输并揭晓汤底",
    usage = "/认输",
})
jn.command.register("放弃", function(_, event) return cmd_give_up(event) end, {
    description = "/认输 的别名",
    usage = "/放弃",
})
jn.command.register("看汤底", function(_, event) return cmd_give_up(event) end, {
    description = "/认输 的别名",
    usage = "/看汤底",
})
jn.command.register("汤底", function(_, event) return cmd_give_up(event) end, {
    description = "/认输 的别名",
    usage = "/汤底",
})

jn.log.info("[turtle_soup] 海龟汤插件已加载")
