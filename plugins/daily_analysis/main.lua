-- ============================================================================
-- daily_analysis: 群聊日常分析与总结插件
-- 作者: Churnie HXCN
-- 复刻自: astrbot_plugin_qq_group_daily_analysis (专为 JuanNiang-Neo 架构深度定制)
-- ============================================================================

local jn = require("jn")
-- 引擎没有给插件目录挂 package.path，共享模块用 jn.file.read + loadstring 载入
local function load_juya()
    local src, err = jn.file.read("juya.lua")
    if not src then return nil, "juya.lua 读取失败: " .. tostring(err) end
    local chunk, lerr = loadstring(src, "juya.lua")
    if not chunk then return nil, "juya.lua 语法错误: " .. tostring(lerr) end
    local ok, factory = pcall(chunk)
    if not ok or type(factory) ~= "function" then return nil, "juya.lua 初始化失败" end
    local ok2, mod = pcall(factory, jn)
    if not ok2 or type(mod) ~= "table" then return nil, "juya.lua 执行失败: " .. tostring(mod) end
    return mod
end
local juya, juya_err = load_juya()
if not juya then jn.log.error("juya 模块加载失败: " .. tostring(juya_err)) end

-- 全局常量
local PLUGIN_NAME = "daily_analysis"
local TABLE_MESSAGES = "pluggin_daily_analysis_messages"
local TABLE_REPORTS = "pluggin_daily_analysis_reports"

-- 内部运行状态
local state = {
    bot_uin = 0,
    timer_id = 0,
    last_daily_date = "",
    manual_running = false,
    manual_triggered_once = false,
}

-- 前向声明
local check_manual_trigger
local check_daily_timer
local prune_expired_messages

-- ============================================================================
-- 1. 数据库初始化
-- ============================================================================
local function init_db()
    local sql = [[
        CREATE TABLE IF NOT EXISTS ]] .. TABLE_MESSAGES .. [[ (
            id BIGSERIAL PRIMARY KEY,
            group_id BIGINT NOT NULL,
            user_id BIGINT NOT NULL,
            nickname TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL DEFAULT '',
            raw_message TEXT NOT NULL DEFAULT '',
            message_id BIGINT DEFAULT 0,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS idx_pdam_group_created ON ]] .. TABLE_MESSAGES .. [[ (group_id, created_at);
        CREATE TABLE IF NOT EXISTS ]] .. TABLE_REPORTS .. [[ (
            id BIGSERIAL PRIMARY KEY,
            group_id BIGINT NOT NULL,
            target_id BIGINT NOT NULL DEFAULT 0,
            report_date DATE NOT NULL DEFAULT CURRENT_DATE,
            mode TEXT NOT NULL DEFAULT '',
            section_count INT NOT NULL DEFAULT 0,
            node_count INT NOT NULL DEFAULT 0,
            sections TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL DEFAULT '',
            created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS idx_pdar_group_date ON ]] .. TABLE_REPORTS .. [[ (group_id, report_date);
    ]]
    local _, err = jn.database.exec(sql)
    if err then
        jn.log.error("[" .. PLUGIN_NAME .. "] 初始化数据库失败: " .. tostring(err))
    else
        jn.log.info("[" .. PLUGIN_NAME .. "] 数据库表初始化就绪")
    end
end

-- ============================================================================
-- 2. 基础辅助函数
-- ============================================================================
local function get_bot_uin()
    if state.bot_uin and state.bot_uin > 0 then
        return state.bot_uin
    end
    if jn.onebot11 and jn.onebot11.get_login_info then
        local info, err = jn.onebot11.get_login_info()
        if info and info.user_id then
            state.bot_uin = tonumber(info.user_id) or 0
            return state.bot_uin
        end
    end
    return 0
end

local function get_target_groups()
    local raw = jn.config.get("target_groups")
    local list = {}
    if type(raw) == "table" then
        for _, v in pairs(raw) do
            local gid = tonumber(v)
            if gid and gid > 0 then
                list[gid] = true
            end
        end
    elseif type(raw) == "string" then
        for item in raw:gmatch("[^,，%s]+") do
            local gid = tonumber(item)
            if gid and gid > 0 then
                list[gid] = true
            end
        end
    end
    return list
end

local function is_target_group(group_id)
    local targets = get_target_groups()
    return targets[tonumber(group_id)] == true
end

local function clean_message_text(raw)
    if not raw or raw == "" then return "" end
    -- 刻意保留图片与合并转发的 CQ 码：这两类搬运内容的正文会在语料展开阶段
    -- 由 jn.llm.vision_url / jn.onebot11.get_forward_msg_sync 补齐（见 expand_cq_content），
    -- 若在此剥离就永远进不了总结语料；只移除回复引用与机器人指令。
    -- 移除回复引用 CQ 码
    local cleaned = raw:gsub("%[CQ:reply,id=%-?%d+%]", "")
    -- 过滤常规以 / 或 # 或 ! 开头的控制命令
    if cleaned:match("^%s*[/#%!]%S+") then
        return ""
    end
    -- 去除首尾空白
    cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
    return cleaned
end

-- ============================================================================
-- 3. 消息采集 (on_message)
-- ============================================================================
function on_message(event)
    if not event or event.message_type ~= "group" then
        return false, nil
    end

    local group_id = tonumber(event.group_id)
    if not group_id or not is_target_group(group_id) then
        return false, nil
    end

    local sender_id = tonumber(event.user_id) or 0

    -- 过滤机器人自身发言
    local filter_bot = jn.config.get("filter_bot_messages")
    if filter_bot == nil then filter_bot = true end
    if filter_bot then
        local bot_uin = get_bot_uin()
        if bot_uin > 0 and sender_id == bot_uin then
            return false, nil
        end
    end

    local nickname = ""
    if event.sender then
        nickname = event.sender.card or ""
        if nickname == "" then
            nickname = event.sender.nickname or ""
        end
    end
    if nickname == "" then
        nickname = "群友" .. tostring(sender_id)
    end

    local raw_msg = event.raw_message or ""
    local clean_text = clean_message_text(raw_msg)
    if clean_text == "" then
        return false, nil
    end

    local msg_id = tonumber(event.message_id) or 0

    local sql = [[
        INSERT INTO ]] .. TABLE_MESSAGES .. [[
        (group_id, user_id, nickname, content, raw_message, message_id)
        VALUES (?, ?, ?, ?, ?, ?)
    ]]
    jn.database.exec(sql, { group_id, sender_id, nickname, clean_text, raw_msg, msg_id })

    -- 顺带检查后台手动触发开关
    check_manual_trigger()

    return false, nil
end

-- ============================================================================
-- 4. 历史记录查询与统计分析 (板块 1：群聊概况与活跃时段)
-- ============================================================================
local function fetch_group_messages(group_id, hours)
    hours = hours or 24
    local sql = [[
        SELECT id, user_id, nickname, content, raw_message, created_at
        FROM ]] .. TABLE_MESSAGES .. [[
        WHERE group_id = ?
          AND created_at >= NOW() - (INTERVAL '1 hour' * ?)
        ORDER BY created_at ASC
        LIMIT 2000
    ]]
    local rows, err = jn.database.query(sql, { group_id, hours })
    if err then
        jn.log.error("[" .. PLUGIN_NAME .. "] 查询群消息历史失败: " .. tostring(err))
        return {}
    end
    return rows or {}
end

local function analyze_statistics(messages)
    local total_count = #messages
    if total_count == 0 then
        return {
            total_count = 0,
            user_count = 0,
            peak_period = "无活跃记录",
            top_users = {},
        }
    end

    local user_counts = {}
    local user_names = {}
    local hour_counts = {}
    for h = 0, 23 do hour_counts[h] = 0 end

    for _, msg in ipairs(messages) do
        local uid = msg.user_id
        user_counts[uid] = (user_counts[uid] or 0) + 1
        user_names[uid] = msg.nickname or ("群友" .. uid)

        local created = tostring(msg.created_at or "")
        local hour_str = created:match("(%d%d):%d%d:%d%d")
        if hour_str then
            local h = tonumber(hour_str)
            if h and h >= 0 and h <= 23 then
                hour_counts[h] = hour_counts[h] + 1
            end
        end
    end

    local unique_users = 0
    local sorted_users = {}
    for uid, count in pairs(user_counts) do
        unique_users = unique_users + 1
        table.insert(sorted_users, { uid = uid, name = user_names[uid], count = count })
    end
    table.sort(sorted_users, function(a, b) return a.count > b.count end)

    local max_period_count = -1
    local peak_start = 0
    for h = 0, 22 do
        local window_sum = hour_counts[h] + hour_counts[h+1]
        if window_sum > max_period_count then
            max_period_count = window_sum
            peak_start = h
        end
    end
    local peak_period = string.format("%02d:00 - %02d:00", peak_start, peak_start + 2)

    return {
        total_count = total_count,
        user_count = unique_users,
        peak_period = peak_period,
        top_users = sorted_users,
    }
end

-- ============================================================================
-- 5a. CQ 码展开：合并转发 / 图片 / 语音视频文件 / 回复引用 → 可读文本
-- 群里大量讨论是围绕搬运内容展开的，原文里的 [CQ:forward,id=...] 与
-- [CQ:image,url=...] 对总结模型毫无语义，这里在生成语料前展开。
-- ============================================================================
local function da_bool(key, default)
    local v = jn.config.get(key)
    if v == nil then return default end
    return v ~= false and v ~= "false" and v ~= "0"
end

local function da_num(key, default)
    local n = tonumber(jn.config.get(key))
    return n or default
end

local function da_string(key, default)
    local v = jn.config.get(key)
    if v == nil or v == "" then return default end
    return tostring(v)
end

local function da_clip(text, max)
    text = tostring(text or "")
    if #text <= max then return text end
    return text:sub(1, max) .. "…"
end

-- 合并转发：jn.onebot11.get_forward_msg_sync 拉取内层节点，按昵称+正文拼接
local function da_forward_text(fid)
    local cached = jn.cache.get("da:fwd:" .. fid)
    if type(cached) == "string" then return cached end
    if not jn.onebot11 or not jn.onebot11.get_forward_msg_sync then
        return "【合并转发】"
    end
    local ok, nodes, err = pcall(jn.onebot11.get_forward_msg_sync, fid)
    if not ok or err or type(nodes) ~= "table" or #nodes == 0 then
        jn.log.warn("[daily_analysis] 合并转发展开失败 id=" .. tostring(fid) .. " err=" .. tostring(err or ok))
        return "【合并转发】"
    end

    local limit = da_num("forward_node_limit", 10)
    local width = da_num("forward_node_chars", 120)
    local parts, inner = {}, #nodes
    for i, n in ipairs(nodes) do
        if i > limit then break end
        local texts = {}
        local content = n.content
        if type(content) == "table" then
            for _, seg in ipairs(content) do
                if type(seg) == "table" and seg.type == "text" and type(seg.data) == "table" then
                    local t = seg.data.text
                    if type(t) == "string" and t ~= "" then texts[#texts + 1] = t end
                elseif type(seg) == "table" and seg.type == "image" then
                    texts[#texts + 1] = "[图]"
                elseif type(seg) == "table" and seg.type == "xml" and type(seg.data) == "table" then
                    -- NapCat 把嵌套的聊天记录当成 xml 段，摘要在 <title> 里
                    local xml = tostring(seg.data.data or "")
                    local titles = {}
                    for title in xml:gmatch("<title[^>]*>([^<]*)</title>") do
                        local v = title:gsub("^%s+", ""):gsub("%s+$", "")
                        if v ~= "" then titles[#titles + 1] = v end
                    end
                    if #titles > 0 then texts[#texts + 1] = table.concat(titles, " / ") end
                end
            end
        elseif type(content) == "string" and content ~= "" then
            texts[#texts + 1] = content
        end
        local who = tostring(n.name or ("群友" .. tostring(n.uin or "")))
        parts[#parts + 1] = who .. "：" .. da_clip(table.concat(texts, " "), width)
    end
    local out = "【合并转发 " .. inner .. " 条】" .. table.concat(parts, " / ")
    if inner > limit then out = out .. " …（另 " .. (inner - limit) .. " 条）" end
    jn.cache.set("da:fwd:" .. fid, out, 7 * 86400)
    return out
end

-- 图片：image_model Provider 描述（每份报告限量，避免总结时间爆炸）
local da_vision_used = 0
local function da_image_text(url)
    local key = "da:img:" .. url
    local cached = jn.cache.get(key)
    if type(cached) == "string" then return cached end
    if not da_bool("vision_describe", true)
        or not jn.llm or not jn.llm.vision_url
        or da_vision_used >= da_num("vision_image_limit", 10) then
        return "[图片]"
    end
    da_vision_used = da_vision_used + 1
    local ok, text, err = pcall(jn.llm.vision_url,
        da_string("vision_provider", "wb-api-image"),
        url,
        "用一句中文描述这张图片的内容，最多30字，只写图中明确可见的内容，不要编造",
        { timeout = 30 })
    if ok and not err and type(text) == "string" and text ~= "" then
        local out = "【图片：" .. da_clip(text, 60) .. "】"
        jn.cache.set(key, out, 7 * 86400)
        return out
    end
    jn.log.warn("[daily_analysis] 图片描述失败 url=" .. da_clip(url, 80) .. " err=" .. tostring(err or text))
    return "[图片]"
end

-- 回复引用：把被回复消息的前 80 字作为上下文带进语料
local function da_reply_text(id)
    local rows, err = jn.database.query([[
        SELECT nickname, content FROM ]] .. TABLE_MESSAGES .. [[
        WHERE message_id = ? LIMIT 1
    ]], { tonumber(id) })
    if err or type(rows) ~= "table" or not rows[1] then return "" end
    local src = rows[1].content or ""
    if src == "" then return "" end
    return "【回复 " .. tostring(rows[1].nickname or "群友") .. "：「" .. da_clip(src, 80) .. "」】"
end

local function expand_cq_content(raw, fallback)
    if type(raw) ~= "string" or raw == "" then return fallback or "" end
    local s = raw
    if da_bool("expand_reply", true) then
        s = s:gsub("%[CQ:reply,id=(%-?%d+)%]", function(id)
            return da_reply_text(id)
        end)
    else
        s = s:gsub("%[CQ:reply,id=%-?%d+%]", "")
    end
    if da_bool("expand_forward", true) then
        s = s:gsub("%[CQ:forward,id=([^,%]]+)%]", function(fid)
            return da_forward_text(fid)
        end)
    end
    s = s:gsub("%[CQ:image,[^%]]*url=([^,%]]+)[^%]]*%]", function(u)
        local url = u:gsub("&amp;", "&")
        return da_image_text(url)
    end)
    s = s:gsub("%[CQ:record,[^%]]*%]", "[语音]")
    s = s:gsub("%[CQ:video,[^%]]*%]", "[视频]")
    s = s:gsub("%[CQ:file,[^%]]*%]", "[文件]")
    return s
end

-- ============================================================================
-- 5. 构建聊天流 (修复 2741226099 多行空行被拆为 3 条消息的 Bug)
-- ============================================================================
local function format_chat_stream(messages)
    local formatted = {}
    local participant_map = {}
    local participant_counter = 0

    for idx, msg in ipairs(messages) do
        local uid = tostring(msg.user_id)
        if not participant_map[uid] then
            participant_counter = participant_counter + 1
            participant_map[uid] = {
                id = participant_counter,
                label = string.format("参与者%d[%s]", participant_counter, uid),
                name = msg.nickname or ("群友" .. uid),
            }
        end

        local p_info = participant_map[uid]
        local created = tostring(msg.created_at or "")
        local time_str = created:match("(%d%d:%d%d)") or "未知时间"

        -- 关键防空行拆分设计：使用 <msg> 标签包裹单条消息全部内容（含内部所有空行与换行）
        local item_text = string.format(
            '<msg id="%d" time="%s" user="%s" nickname="%s">\n%s\n</msg>',
            idx,
            time_str,
            p_info.label,
            p_info.name,
            msg.content or ""
        )
        table.insert(formatted, item_text)
    end

    return table.concat(formatted, "\n"), participant_map
end

-- ============================================================================
-- 6. 复用 Bot 系统人设
-- ============================================================================
local function get_bot_persona_prompt()
    local persona_style = jn.config.get("use_bot_persona") or "deep"
    if persona_style == "none" then
        return "你是一个客观、严谨的中立群聊总结助手。"
    end

    local persona_text = ""
    if jn.agent and jn.agent.get_prompts then
        local prompts, _ = jn.agent.get_prompts()
        if prompts and type(prompts) == "table" then
            for _, p in ipairs(prompts) do
                if p.is_active and (p.type == "personality" or p.type == "system") then
                    if p.content and #p.content > 0 then
                        persona_text = persona_text .. "\n" .. p.content
                    end
                end
            end
        end
    end

    if persona_text ~= "" then
        if persona_style == "deep" then
            return "【你的人格设定（最高优先级，在话题分析、点评和全群总结时，深度还原此人设口吻、口癖与性格特质）】：\n" .. persona_text
        else
            return "【你的人格参考（保持适度幽默风趣，口吻贴合此人设）】：\n" .. persona_text
        end
    end

    return "你是一个风趣幽默、擅长观察但又不失温情的群聊观察员。"
end

-- ============================================================================
-- 7. 构建 LLM 提示词
-- ============================================================================
local function build_analysis_prompt(chat_stream, stats, persona_prompt)
    local max_topics = tonumber(jn.config.get("max_topics") or "5") or 5
    local max_quotes = tonumber(jn.config.get("max_golden_quotes") or "5") or 5
    local max_titles = tonumber(jn.config.get("max_user_titles") or "6") or 6
    local max_critiques = tonumber(jn.config.get("max_critiques") or "4") or 4
    local use_persona = jn.config.get("use_bot_persona") or "deep"
    local topics_rule = ""
    if max_topics > 0 then
        topics_rule = string.format("提取不多于 %d 个今日核心热门话题", max_topics)
    elseif max_topics == -1 then
        topics_rule = "提取今日出现的所有核心热门话题，不限数量上限"
    else
        topics_rule = "无需提取话题（本项已关闭）"
    end

    local quotes_rule = ""
    if max_quotes > 0 then
        quotes_rule = string.format("甄选不多于 %d 句最具冲击力、反差感、神反转的「群圣经/高光金句」", max_quotes)
    elseif max_quotes == -1 then
        quotes_rule = "甄选今日所有的逆天、反差、高光「群圣经/金句」，不限数量上限"
    else
        quotes_rule = "无需提取金句（本项已关闭）"
    end

    local titles_rule = ""
    if max_titles > 0 then
        titles_rule = string.format("为不多于 %d 位发言活跃群友评选极具特色的荣誉头衔与行为特征画像", max_titles)
    elseif max_titles == -1 then
        titles_rule = "为今日所有活跃群友评选极具特色的头衔与行为特征画像，不限数量上限"
    else
        titles_rule = "无需评选头衔（本项已关闭）"
    end

    local critique_rule = ""
    if max_critiques ~= 0 then
        local count_text = (max_critiques > 0) and string.format("不多于 %d 个", max_critiques) or "不限数量"
        if use_persona == "none" then
            critique_rule = string.format("将今日聊天划分为 %s 抽象维度（如技术研讨、职业焦虑、日常摸鱼），为每个维度计算大致占比百分比，并给出客观严谨的分析点评与全天综合表现总结！", count_text)
        else
            critique_rule = string.format("将今日聊天划分为 %s 抽象维度（如技术研讨、职业焦虑、日常摸鱼），为每个维度计算大致占比百分比，并【结合你的人格设定】给出贴合你性格与口吻的精彩、幽默或生动点评，最后附一句全天综合表现总结！", count_text)
        end
    else
        critique_rule = "无需进行聊天质量点评（本项已关闭）"
    end

    local prompt = string.format([[
%s

你现在正在为群聊生成一份智能的「今日群聊日常分析报告」。
请根据下方给出的【群聊记录数据流】，按规则完成分析，并以严格的纯 JSON 格式返回。

## 核心任务要求：
1. 话题分析：%s。具体总结中，提及发言人时必须使用其真实的【QQ昵称】（nickname属性），严禁只写参与者编号或纯QQ号。
2. 群圣经甄选：%s。
   ⚠️【核心防拆分规则·重中之重】：
   在聊天记录中，每一个 `<msg id="...">` 标签内的内容代表单条完整发言。
   无论该发言内部包含多少个空行、换行或段落，必须作为一个完整的金句段落提取，绝对严禁按空行截断拆分成多条！
   content 字段必须完整保留原作者的换行与空行原貌（在 JSON 字符串中使用 \n 转义表示），sender 必须为发言人真实昵称。
3. 群友头衔：%s。user 必须填群友真实昵称。
4. 质量锐评与人设点评：%s。

## 返回 JSON 数据结构规范（严禁包含 markdown 代码块包裹之外的杂质，必须是合法 JSON）：
```json
{
  "topics": [
    {
      "title": "话题标题（2-10字）",
      "summary": "核心脉络与要点概述（50字以内）",
      "participants": "主要讨论者（使用真实昵称，逗号分隔）"
    }
  ],
  "golden_quotes": [
    {
      "msg_id": 1,
      "sender": "发言人真实昵称",
      "content": "完整圣经原文内容（包含原消息所有的多行与空行，严禁截断）",
      "reason": "入选理由（具体说明其逆天逻辑/神人反差/笑点）"
    }
  ],
  "user_titles": [
    {
      "user": "群友真实昵称",
      "title": "幽默专属头衔",
      "description": "获此头衔的行为特征点评"
    }
  ],
  "critique": {
    "dimensions": [
      {
        "name": "抽象维度名称（如职业焦虑/技术交锋/深夜水群）",
        "percentage": 30,
        "comment": "深度还原你人设口吻的犀利点评"
      }
    ],
    "overall_summary": "以你的人设口吻给出的全天群聊综合表现霸气金句总结"
  }
}
```

## 群聊记录数据流（共 %d 条）：
%s
]], persona_prompt, topics_rule, quotes_rule, titles_rule, critique_rule, stats.total_count, chat_stream)

    return prompt
end

-- ============================================================================
-- 8. JSON 解析与健壮清洗 (消除循环 sub 造成的 registry overflow)
-- ============================================================================
local function parse_llm_json(raw)
    if not raw or raw == "" then return nil end
    local json_str = raw:match("```json%s*(.-)%s*```") or raw:match("```%s*(.-)%s*```") or raw

    -- 1. 优先尝试直接解码 (如果大模型已正确输出合法 JSON)
    local ok, res = pcall(jn.json.decode, json_str)
    if ok and type(res) == "table" then
        return res
    end

    -- 2. 若直接解码失败，使用 string.gsub 快速转义字符串字面量中的真实换行符
    -- 针对包含多行文本的字段执行安全替换，不产生 Lua 栈对象堆积
    local fixed = json_str:gsub('("content"%s*:%s*")(.-)(")', function(pre, body, post)
        return pre .. body:gsub("\r\n", "\\n"):gsub("\n", "\\n"):gsub("\r", "") .. post
    end)
    fixed = fixed:gsub('("reason"%s*:%s*")(.-)(")', function(pre, body, post)
        return pre .. body:gsub("\r\n", "\\n"):gsub("\n", "\\n"):gsub("\r", "") .. post
    end)
    fixed = fixed:gsub('("comment"%s*:%s*")(.-)(")', function(pre, body, post)
        return pre .. body:gsub("\r\n", "\\n"):gsub("\n", "\\n"):gsub("\r", "") .. post
    end)
    fixed = fixed:gsub('("overall_summary"%s*:%s*")(.-)(")', function(pre, body, post)
        return pre .. body:gsub("\r\n", "\\n"):gsub("\n", "\\n"):gsub("\r", "") .. post
    end)

    ok, res = pcall(jn.json.decode, fixed)
    if ok and type(res) == "table" then
        return res
    end

    return nil
end


-- ============================================================================
-- 9. 来源采集：仓库 / 公众号文章 / 橘鸦早报
-- ----------------------------------------------------------------------------
-- 水印与 repo-intro / wechat-article-summary 同一套编码：带水印的消息是本机
-- 输出，从中摘出「标题 + 已生成总结」直接复用，不再重复调 LLM。
-- ============================================================================
local WM_TEXT = "Generated by JuanNiang Neo"
local WM_HEAD = "\239\187\191"
local WM_ZERO = "\226\128\139"
local WM_ONE = "\226\128\140"
local WM_LEGACY = "\226\128\139\226\128\140\226\128\141\239\187\191"

-- 解出前若干字节，判断是否为本机输出（新编码前缀匹配，或旧 4 字符标记）
local function is_bot_output(raw)
    if not raw or raw == "" then return false end
    if raw:find(WM_LEGACY, 1, true) then return true end
    local p = raw:find(WM_HEAD, 1, true)
    if not p then return false end
    local bytes, cur, nbits, i = {}, 0, 0, p + #WM_HEAD
    while #bytes < 8 do
        local ch = raw:sub(i, i + 2)
        if ch == WM_ZERO then
            cur = cur * 2; nbits = nbits + 1
        elseif ch == WM_ONE then
            cur = cur * 2 + 1; nbits = nbits + 1
        else
            break
        end
        if nbits == 8 then
            bytes[#bytes + 1] = string.char(cur)
            cur, nbits = 0, 0
        end
        i = i + 3
    end
    local got = table.concat(bytes)
    return #got >= 8 and WM_TEXT:sub(1, #got) == got
end

-- 去掉零宽字符（水印会粘在 📦 行/链接尾部，影响 key 匹配）
local function strip_wm(s)
    s = tostring(s or "")
    s = s:gsub("\226\128\139", ""):gsub("\226\128\140", "")
         :gsub("\226\128\141", ""):gsub("\239\187\191", "")
    return s
end

local function normalize_url(u)
    u = tostring(u or ""):gsub("&amp;", "&")
    return (u:gsub("[%)%,%.%!%?%;:]+$", ""))
end

-- 从本机输出里按 📦/📰 分块，摘出 name/url/title/summary
local function parse_bot_blocks(text)
    local blocks, cur = {}, nil
    local function flush()
        if not cur then return end
        local title, summary = "", ""
        local anchor
        for i, l in ipairs(cur.lines) do
            if l:find("📝", 1, true) or l:find("📰", 1, true) then anchor = i; break end
        end
        if anchor then
            local l = cur.lines[anchor]
            local p1 = l:find("📝", 1, true)
            local p2 = l:find("📰", 1, true)
            local p, mlen = p1, #"📝"
            if not p or (p2 and p2 < p) then p, mlen = p2, #"📰" end
            if p then title = strip_wm(l:sub(p + mlen)):gsub("^%s+", ""):gsub("%s+$", "") end
            for i = anchor + 1, #cur.lines do
                local seg = tostring(cur.lines[i])
                seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
                if seg ~= "" and not seg:find("^https?://") then summary = seg; break end
            end
        end
        blocks[#blocks + 1] = { kind = cur.kind, name = cur.name, url = cur.url,
                                title = title, summary = summary }
        cur = nil
    end

    -- 逐行扫描（不用 gmatch/表达式上直接调方法：gopher-lua 在临时字符串上
    -- 调用字符串方法会触发 nil pointer panic）
    local src = tostring(text or "")
    local pos, len = 1, #src
    while pos <= len do
        local nl = src:find("\n", pos, true)
        local line = (nl and src:sub(pos, nl - 1)) or src:sub(pos)
        pos = (nl and nl + 1) or (len + 1)

        local pbox = line:find("📦", 1, true)
        local pnews = line:find("📰", 1, true)
        if pbox then
            flush()
            local name = strip_wm(line:sub(pbox + #"📦"))
            cur = { kind = "repo", lines = {}, name = name:gsub("^%s+", ""):gsub("%s+$", "") }
        elseif pnews then
            flush()
            cur = { kind = "article", lines = {} }
        end
        if cur then
            if not cur.url then
                local u = line:match("(https?://[^%s]+)")
                if u then cur.url = normalize_url(strip_wm(u)) end
            end
            cur.lines[#cur.lines + 1] = line
        end
    end
    flush()
    return blocks
end

-- 扫描消息：返回 repos、articles（各自保序、带出现次数与 bot 总结）
local function collect_sources(messages)
    local bot_repo, bot_article = {}, {}
    for _, m in ipairs(messages) do
        local raw = m.raw_message or ""
        if is_bot_output(raw) then
            for _, b in ipairs(parse_bot_blocks(raw)) do
                if b.kind == "repo" and b.name and b.name ~= "" then
                    bot_repo[b.name:lower()] = b
                elseif b.kind == "article" and b.url and b.url ~= "" then
                    bot_article[normalize_url(b.url)] = b
                end
            end
        end
    end

    local repos, rindex = {}, {}
    local articles, aindex = {}, {}
    local function add_repo(kind, name, url)
        local key = name:lower()
        if not rindex[key] then
            rindex[key] = #repos + 1
            repos[#repos + 1] = { key = key, kind = kind, name = name, url = url, count = 0 }
        end
        repos[rindex[key]].count = repos[rindex[key]].count + 1
    end
    local function add_article(url)
        url = normalize_url(url)
        if url == "" then return end
        if not aindex[url] then
            aindex[url] = #articles + 1
            articles[#articles + 1] = { url = url, count = 0 }
        end
        articles[aindex[url]].count = articles[aindex[url]].count + 1
    end

    for _, m in ipairs(messages) do
        local raw = m.raw_message or ""
        if not is_bot_output(raw) then
            for owner, repo in raw:gmatch("github%.com/([%w%-_%.]+)/([%w%-_%.]+)") do
                add_repo("github", owner .. "/" .. repo, "https://github.com/" .. owner .. "/" .. repo)
            end
            for sub, owner, repo in raw:gmatch("huggingface%.co/(models|datasets)/([%w%-_%.]+)/([%w%-_%.]+)") do
                add_repo("hf", owner .. "/" .. repo, "https://huggingface.co/" .. sub .. "/" .. owner .. "/" .. repo)
            end
            for owner, repo in raw:gmatch("huggingface%.co/([%w%-_%.]+)/([%w%-_%.]+)") do
                if owner ~= "models" and owner ~= "datasets" and owner ~= "spaces" and owner ~= "api" then
                    add_repo("hf", owner .. "/" .. repo, "https://huggingface.co/" .. owner .. "/" .. repo)
                end
            end
            for _, host in ipairs({ "cn", "ai" }) do
                local pat = "modelscope%." .. host .. "/(models|datasets)/([%w%-_%.]+)/([%w%-_%.]+)"
                for sub, owner, repo in raw:gmatch(pat) do
                    add_repo("ms", owner .. "/" .. repo,
                        "https://modelscope." .. host .. "/" .. sub .. "/" .. owner .. "/" .. repo)
                end
            end
            for u in raw:gmatch("(https?://mp%.weixin%.qq%.com/s[%w%-%._%?%%&=/#]+)") do
                add_article(u)
            end
        end
    end

    for _, r in ipairs(repos) do
        local b = bot_repo[r.key]
        if b then
            r.title = (b.title ~= "" and b.title) or nil
            r.summary = (b.summary ~= "" and b.summary) or nil
        end
    end
    for _, a in ipairs(articles) do
        local b = bot_article[normalize_url(a.url)]
        if b then
            a.title = (b.title ~= "" and b.title) or nil
            a.summary = (b.summary ~= "" and b.summary) or nil
        end
    end
    return repos, articles
end

local function cfg_news_merge_enabled()
    local v = jn.config.get("news_event_merge")
    if v == nil then return true end
    return v ~= false and v ~= "false" and v ~= "0"
end

-- LLM 辅助：要求严格 JSON 输出
local function llm_json(system, user)
    if not (jn.llm and jn.llm.chat) then return nil, "无 LLM" end
    local resp, err = jn.llm.chat({
        { role = "system", content = system },
        { role = "user", content = user },
    })
    if err or not resp or resp == "" then return nil, tostring(err or "空响应") end
    local cleaned = resp:gsub("```[%w]*\n?", ""):gsub("```", "")
    local ok, obj = pcall(jn.json.decode, cleaned)
    if not ok or type(obj) ~= "table" then return nil, "JSON 解析失败" end
    return obj, nil
end

-- 裸链接（没被总结过）的仓库简介：让 LLM 按名字补一句
local function fill_repo_briefs(repos)
    local pending = {}
    for _, r in ipairs(repos) do
        if (not r.title or r.title == "") and (not r.summary or r.summary == "") then
            pending[#pending + 1] = r
        end
    end
    if #pending == 0 then return end

    local lines = {}
    for i, r in ipairs(pending) do
        if i > 20 then break end
        lines[#lines + 1] = string.format("%d. %s", i, r.name)
    end
    -- 与 repo-intro 同一套规范：精炼一句话标题 + 60~120 字介绍，禁止编造
    local system = "你在为群聊日报整理开源项目条目，风格与 repo-intro 插件保持一致。"
        .. "给每个仓库一句中文标题（≤30 字）和一段中文介绍（60~120 字）："
        .. "只写 README 名、仓库名与元数据能确定的内容（是什么、面向什么场景、关键规格），"
        .. "禁止编造参数量、许可证、价格、基准分数、安装命令；不确定的部分直接不写。"
        .. '严格输出 JSON：{"repos":[{"n":"owner/repo","t":"一句话标题","s":"介绍"}]}'
    local obj, err = llm_json(system, table.concat(lines, "\n"))
    if not obj or type(obj.repos) ~= "table" then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 仓库简介生成失败: " .. tostring(err))
        return
    end
    local map = {}
    for _, it in ipairs(obj.repos) do
        if type(it) == "table" and it.n then
            map[tostring(it.n):lower()] = {
                t = tostring(it.t or ""),
                s = tostring(it.s or ""),
            }
        end
    end
    for _, r in ipairs(pending) do
        local e = map[r.key]
        if e then
            if e.t ~= "" then r.title = e.t end
            if e.s ~= "" then r.summary = e.s end
        end
    end
end

-- 新闻：公众号文章 + 橘鸦早报 → LLM 按事件合并，保留全部来源链接
local function merge_news(articles, juya_items, max_items)
    local wechat, juya = {}, {}
    for i, a in ipairs(articles) do
        if i > 40 then break end
        wechat[#wechat + 1] = { i = i, title = a.title or "", summary = a.summary or "",
                                url = a.url, count = a.count }
    end
    local jidx = 0
    for _, it in ipairs(juya_items) do
        if jidx >= math.min(max_items * 2, 80) then break end
        jidx = jidx + 1
        local links = {}
        for _, l in ipairs(it.links) do links[#links + 1] = l.url end
        juya[#juya + 1] = { i = 100 + jidx, title = it.title, summary = it.summary,
                            category = it.category, links = links }
    end
    if #wechat == 0 and #juya == 0 then return {} end

    if not cfg_news_merge_enabled() then
        -- 关闭合并：各自成条
        local out = {}
        for _, a in ipairs(wechat) do
            out[#out + 1] = { title = a.title ~= "" and a.title or "公众号文章",
                              summary = a.summary, links = { a.url } }
        end
        for _, j in ipairs(juya) do
            out[#out + 1] = { title = j.title, summary = j.summary, links = j.links }
        end
        return out
    end

    local payload = jn.json.encode({ wechat = wechat, juya = juya })
    local system = string.format([[
你在整理今日 AI 新闻。输入含两类条目：
- wechat：群里分享的微信公众号文章（title/summary 可能是我们此前的总结，也可能为空；url 为原文链接，count 为分享次数）
- juya：橘鸦 AI 早报的当日条目（title/summary 附带，links 为该事件的多个来源链接）

请把描述同一事件的条目合并成一条新闻，严格输出 JSON：
{"events":[{"title":"标题","summary":"不超过 80 字的简体中文摘要","links":["来源链接"]}]}

规则：
1. links 必须收录该事件的全部来源链接（公众号原文 + 早报来源），不得遗漏、不得编造；
2. 无法判断为同一事件的，各自独立成条；
3. 最多 %d 条，按重要性排序；
4. 标题不得与摘要重复套话，不要输出除 JSON 以外的任何内容。]], max_items)
    local obj, err = llm_json(system, payload)
    if not obj or type(obj.events) ~= "table" then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 新闻合并失败，降级为顺序罗列: " .. tostring(err))
        local out = {}
        for _, j in ipairs(juya) do
            out[#out + 1] = { title = j.title, summary = j.summary, links = j.links }
        end
        for _, a in ipairs(wechat) do
            out[#out + 1] = { title = a.title ~= "" and a.title or "公众号文章",
                              summary = a.summary, links = { a.url } }
        end
        return out
    end
    local out = {}
    for _, e in ipairs(obj.events) do
        if type(e) == "table" and e.title then
            local links = {}
            if type(e.links) == "table" then
                for _, u in ipairs(e.links) do
                    local s = tostring(u)
                    if s:find("^https?://") then links[#links + 1] = s end
                end
            end
            out[#out + 1] = { title = tostring(e.title), summary = tostring(e.summary or ""), links = links }
        end
    end
    return out
end

-- ============================================================================
-- 10. 板块组装与发送（per_item / per_section / forward 三种模式）
-- ============================================================================
local SECTION_DEF = {
    overview = "📊 群聊概况",
    top = "🔥 发言主力军",
    topics = "🔥 今日核心话题",
    quotes = "📖 群圣经 / 高光发言",
    titles = "👑 群友特色头衔 / 画像",
    critique = "🎭 聊天质量分析与人设点评",
    projects = "🧪 开源项目列表",
    news = "📰 今日新闻",
    stats = "📈 本次分析统计",
}

local function parse_sections_config()
    local list = jn.config.get("sections")
    if type(list) ~= "table" or #list == 0 then
        list = { "overview||1", "top||1", "topics||5", "quotes||5", "titles||6",
                 "critique||4", "projects||20", "news||70", "stats||1" }
    end
    local out = {}
    for _, line in ipairs(list) do
        local key, title, cap = tostring(line):match("^%s*([%w_]+)%s*|%s*([^|]*)%s*|%s*(-?%d+)")
        if key then
            local t = (title ~= "" and title) or SECTION_DEF[key] or key
            out[#out + 1] = { key = key, title = t, cap = tonumber(cap) or 0 }
        end
    end
    return out
end

local CN_NUM = { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十" }
local function num_cn(n)
    n = tonumber(n) or 0
    if n <= 10 then return CN_NUM[n] or tostring(n) end
    if n < 20 then return "十" .. (CN_NUM[n - 10] or "") end
    if n < 100 then
        local t, u = math.floor(n / 10), n % 10
        return (CN_NUM[t] or "") .. "十" .. (u == 0 and "" or (CN_NUM[u] or ""))
    end
    return tostring(n)
end

local function chunk_text(text, max)
    max = max or 1500
    local out, buf, size = {}, {}, 0
    local src = tostring(text) .. "\n"
    for line in src:gmatch("([^\n]*)\n") do
        if size + #line + 1 > max and #buf > 0 then
            out[#out + 1] = table.concat(buf, "\n")
            buf, size = {}, 0
        end
        buf[#buf + 1] = line
        size = size + #line + 1
    end
    if #buf > 0 then out[#out + 1] = table.concat(buf, "\n") end
    return out
end

-- 组装各板块条目（每条是一个可直接发送的字符串）
local function build_sections(stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, messages)
    local repos, articles = collect_sources(messages or {})
    local juya_items = {}
    local news_on = false
    for _, s in ipairs(parse_sections_config()) do
        if s.key == "news" and s.cap ~= 0 then news_on = true end
    end
    if news_on then
        local feeds = {}
        local list = jn.config.get("news_feeds")
        if type(list) == "table" then
            for _, v in ipairs(list) do
                local u = tostring(v or "")
                if u ~= "" then
                    if u:find("{date}", 1, true) or u:find("/issues/", 1, true) then
                        feeds.issue = feeds.issue or u
                    else
                        feeds.rss = feeds.rss or u
                    end
                end
            end
        end
        if not feeds.rss and not feeds.issue then
            feeds.rss = "https://daily.juya.uk/rss.xml"
            feeds.issue = "https://daily.juya.uk/issues/{date}/"
        end
        local ok, url, html, source, ferr = false, nil, nil, nil, "juya 模块未加载"
        if juya then
            ok, url, html, source, ferr = pcall(function()
                return juya.fetch_issue(feeds, os.date("%Y-%m-%d"))
            end)
        end
        if ok and html then
            juya_items = juya.flatten(juya.parse_issue(html))
            jn.log.info(string.format("[%s] 橘鸦早报抓取成功: %s（%d 条）", PLUGIN_NAME, tostring(url), #juya_items))
        else
            jn.log.warn("[" .. PLUGIN_NAME .. "] 橘鸦早报抓取失败: " .. tostring(ok and ferr or url))
        end
    end

    local sections = {}
    local function emit(key, title, cap, items)
        if cap == 0 then return end
        if cap > 0 and #items > cap then
            local cut = {}
            for i = 1, cap do cut[i] = items[i] end
            items = cut
        end
        if #items > 0 then sections[#sections + 1] = { key = key, title = title, items = items } end
    end

    for _, s in ipairs(parse_sections_config()) do
        local items = {}
        if s.key == "overview" then
            items[1] = string.format("🏢 分析群聊: %s (%d)\n📅 统计时间: %s\n💬 消息总量: %d 条\n👥 参与人数: %d 人\n⏰ 最活跃时段: %s",
                group_name, group_id, os.date("%Y年%m月%d日"), stats.total_count, stats.user_count, stats.peak_period)
        elseif s.key == "top" then
            if stats.top_users and #stats.top_users > 0 then
                local lines = {}
                for idx = 1, math.min(3, #stats.top_users) do
                    local u = stats.top_users[idx]
                    lines[#lines + 1] = string.format("👑 Top%d: %s (%d条)", idx, u.name, u.count)
                end
                items[1] = table.concat(lines, "\n")
            end
        elseif s.key == "stats" then
            items[1] = string.format("🤖 总结模型: %s\n⏱️ 分析耗时: %.1f 秒\n📝 输入字符: ~%d 字\n⚡ 消耗 Token: ~%d tokens",
                model_name, dur_sec, stats.total_chars or 0, est_tokens)
        elseif s.key == "topics" and type(analysis_data.topics) == "table" then
            for idx, t in ipairs(analysis_data.topics) do
                local part = (t.participants and t.participants ~= "") and (" (参聊: " .. t.participants .. ")") or ""
                items[#items + 1] = string.format("【%d】%s%s\n%s", idx, t.title or "核心话题", part, t.summary or "")
            end
        elseif s.key == "quotes" and type(analysis_data.golden_quotes) == "table" then
            for idx, q in ipairs(analysis_data.golden_quotes) do
                local reason = (q.reason and q.reason ~= "") and ("\n💡 甄选理由: " .. q.reason) or ""
                items[#items + 1] = string.format("📜 金句 #%d · %s:\n「\n%s\n」%s", idx, q.sender or "群友", q.content or "", reason)
            end
        elseif s.key == "titles" and type(analysis_data.user_titles) == "table" then
            for _, u in ipairs(analysis_data.user_titles) do
                items[#items + 1] = string.format("🎖️ %s —— 获封「%s」\n点评: %s",
                    u.user or "群友", u.title or "活跃群友", u.description or "表现优异")
            end
        elseif s.key == "critique" and type(analysis_data.critique) == "table" then
            local crit = analysis_data.critique
            if type(crit.dimensions) == "table" then
                for _, d in ipairs(crit.dimensions) do
                    local pct = d.percentage and (tostring(d.percentage) .. "%") or ""
                    items[#items + 1] = string.format("▪ %s [%s]\n%s", d.name or "维度", pct, d.comment or "")
                end
            end
            if crit.overall_summary and crit.overall_summary ~= "" then
                items[#items + 1] = "🎯 终极表现总评:\n" .. crit.overall_summary
            end
        elseif s.key == "projects" then
            if #repos == 0 then
                items[1] = "今日没有检测到开源项目 / 模型仓库链接"
            end
            if #repos > 0 then fill_repo_briefs(repos) end
            for _, r in ipairs(repos) do
                local parts = { "📦 " .. r.name }
                if r.title and r.title ~= "" then parts[#parts + 1] = "📝 " .. r.title end
                if r.summary and r.summary ~= "" then parts[#parts + 1] = r.summary end
                if r.count > 1 then parts[#parts + 1] = string.format("（今日被分享 %d 次）", r.count) end
                parts[#parts + 1] = r.url
                items[#items + 1] = table.concat(parts, "\n")
            end
        elseif s.key == "news" then
            local lim = (s.cap > 0) and s.cap or ((s.cap == -1) and 200 or 70)
            local n = 0
            for _, e in ipairs(merge_news(articles, juya_items, lim)) do
                n = n + 1
                local parts = { num_cn(n) .. "、" .. e.title }
                if e.summary and e.summary ~= "" then parts[#parts + 1] = e.summary end
                for _, u in ipairs(e.links) do parts[#parts + 1] = u end
                items[#items + 1] = table.concat(parts, "\n")
            end
        end
        if s.key == "news" and #items > 0 then
            s.title = string.format("%s（%d条）", s.title, #items)
        end
        emit(s.key, s.title, s.cap, items)
    end
    return sections
end

local function send_report(sections, target_type, target_id)
    if #sections == 0 then return 0, 0 end
    local mode = tostring(jn.config.get("report_mode") or "forward")

    local function send_text(text)
        if target_type == "group" then
            return jn.onebot11.send_group_msg(target_id, text)
        end
        return jn.onebot11.send_private_msg(target_id, text)
    end

    -- 兜底：把节点拼成少量文本再发。绝不逐节点发送——那会把日报拆成几十条消息。
    local function send_nodes_as_text(nodes)
        local parts = {}
        for _, n in ipairs(nodes) do
            if type(n.content) == "string" and n.content ~= "" then parts[#parts + 1] = n.content end
        end
        local chunks = chunk_text(table.concat(parts, "\n\n"), 1500)
        for _, c in ipairs(chunks) do send_text(c) end
        return #chunks
    end

    if mode == "forward" then
        local name = jn.config.get("custom_sender_name")
        if not name or name == "" then
            -- 未配置时用机器人自己的昵称，避免多实例串名字
            local nick = "Bot"
            if jn.onebot11.get_login_info then
                local info = jn.onebot11.get_login_info()
                if info and info.nickname and info.nickname ~= "" then nick = tostring(info.nickname) end
            end
            name = nick .. "·群聊日报"
        end
        local uin = get_bot_uin()
        if uin <= 0 then uin = 1772023368 end
        local nodes = {}
        local function push(c)
            nodes[#nodes + 1] = { user_id = uin, nickname = name, content = c }
        end
        -- 不加分割线：合并转发里每个节点已是独立气泡，--- 纯属噪音
        for _, s in ipairs(sections) do
            if #s.items == 1 then
                push(s.title .. "\n" .. s.items[1])
            else
                push(s.title)
                for _, item in ipairs(s.items) do
                    push(item)
                end
            end
        end
        if target_type == "group" and jn.onebot11.send_group_forward_msg_sync then
            local id, ferr = jn.onebot11.send_group_forward_msg_sync(target_id, nodes)
            if ferr == nil then return 1, #nodes end -- 成功时返回 message_id（可能为 0），只有带错误串才算失败
            jn.log.warn("[" .. PLUGIN_NAME .. "] 群合并转发失败，改用合并文本: " .. tostring(ferr))
        elseif target_type ~= "group" and jn.onebot11.send_private_forward_msg_sync then
            local id, ferr = jn.onebot11.send_private_forward_msg_sync(target_id, nodes)
            if ferr == nil then return 1, #nodes end
            jn.log.warn("[" .. PLUGIN_NAME .. "] 私聊合并转发失败，改用合并文本: " .. tostring(ferr))
        else
            jn.log.warn("[" .. PLUGIN_NAME .. "] 当前引擎无" .. (target_type == "group" and "群" or "私聊")
                .. "合并转发接口，改用合并文本发送")
        end
        local n = send_nodes_as_text(nodes)
        return n, #nodes
    end

    local count = 0
    for _, s in ipairs(sections) do
        local n = #s.items
        if mode == "per_section" then
            for _, chunk in ipairs(chunk_text(s.title .. "\n" .. table.concat(s.items, "\n\n"), 1500)) do
                send_text(chunk)
                count = count + 1
            end
        else
            for i, item in ipairs(s.items) do
                local head = (n > 1) and string.format("%s (%d/%d)\n", s.title, i, n) or (s.title .. "\n")
                send_text(head .. item)
                count = count + 1
            end
        end
    end
    return count, count
end

-- ============================================================================
-- 10a. 报告持久化：成功生成的日报落 Postgres，重启后可查历史
-- ============================================================================
local function persist_report(group_id, target_id, sections, mode, node_count)
    local flat = {}
    for _, sec in ipairs(sections or {}) do
        flat[#flat + 1] = "## " .. tostring(sec.title or sec.key or "")
        for _, item in ipairs(sec.items or {}) do
            flat[#flat + 1] = tostring(item)
        end
    end
    local content = table.concat(flat, "\n")
    local ok_enc, encoded = pcall(jn.json.encode, sections)
    if not ok_enc then encoded = "" end
    local _, err = jn.database.exec([[INSERT INTO ]] .. TABLE_REPORTS .. [[
        (group_id, target_id, report_date, mode, section_count, node_count, sections, content)
        VALUES (?, ?, CURRENT_DATE, ?, ?, ?, ?, ?)
    ]], { group_id, target_id, tostring(mode), #sections, node_count or 0,
          tostring(encoded or ""), content })
    if err then
        jn.log.error("[" .. PLUGIN_NAME .. "] 日报持久化失败: " .. tostring(err))
    else
        jn.log.info(string.format("[%s] 日报已落库 group=%d 板块=%d 字符=%d",
            PLUGIN_NAME, group_id, #sections, #content))
    end
end

-- ============================================================================
-- 11. 自动清理过期记录 (默认保留 7 天)
-- ============================================================================
function prune_expired_messages()
    local retention = tonumber(jn.config.get("retention_days") or "7") or 7
    if retention <= 0 then retention = 7 end

    local sql = [[
        DELETE FROM ]] .. TABLE_MESSAGES .. [[
        WHERE created_at < NOW() - (INTERVAL '1 day' * ?)
    ]]
    local count, err = jn.database.exec(sql, { retention })
    if err then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 清理过期消息历史失败: " .. tostring(err))
    elseif count and count > 0 then
        jn.log.info(string.format("[%s] 自动清理 %d 天前的过期消息: %d 条", PLUGIN_NAME, retention, count))
    end

    -- 报告保留更久（默认 90 天）
    local report_days = tonumber(jn.config.get("report_retention_days") or "90") or 90
    if report_days <= 0 then report_days = 90 end
    local _, rerr = jn.database.exec("DELETE FROM " .. TABLE_REPORTS ..
        " WHERE created_at < NOW() - (INTERVAL '1 day' * ?)", { report_days })
    if rerr then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 清理过期报告失败: " .. tostring(rerr))
    end
end

-- ============================================================================
-- 12. 执行分析主流程 (do_group_analysis)
-- ============================================================================
-- 智能匹配文本模型服务商 (支持服务商名称、模型名称、组合形式或 UUID)
local function match_text_provider(input_str, providers)
    if not input_str or input_str == "" then return nil end
    local s = input_str:lower():gsub("%s+", "")

    local text_providers = {}
    for _, p in ipairs(providers or {}) do
        local p_type = tostring(p.Type or p.type or "")
        if p_type == "text_model" then
            table.insert(text_providers, p)
        end
    end

    -- 1. 精确匹配：ID / 服务商名 / 模型名 / 组合 "服务商·模型"
    for _, p in ipairs(text_providers) do
        local pid = tostring(p.ID or p.id or ""):lower()
        local pname = tostring(p.Name or p.name or ""):lower():gsub("%s+", "")
        local pmodel = tostring(p.Model or p.model or ""):lower():gsub("%s+", "")
        local combo = pname .. "·" .. pmodel
        local combo_dot = pname .. "." .. pmodel
        local combo_slash = pname .. "/" .. pmodel

        if s == pid or s == pname or s == pmodel or s == combo or s == combo_dot or s == combo_slash then
            return p
        end
    end

    -- 2. 模糊包含匹配 (例如输入 "volcengine"、"deepseek"、"qianfan")
    for _, p in ipairs(text_providers) do
        local pname = tostring(p.Name or p.name or ""):lower()
        local pmodel = tostring(p.Model or p.model or ""):lower()
        if pname:find(s, 1, true) or pmodel:find(s, 1, true) or s:find(pname, 1, true) or s:find(pmodel, 1, true) then
            return p
        end
    end

    return nil
end

local function do_group_analysis(group_id, send_target_id, is_private_target, force)
    group_id = tonumber(group_id)
    if not group_id then return false, "非法群号" end

    local cur_date = os.date("%Y-%m-%d")
    local cache_key = "last_analyzed:" .. tostring(group_id)

    -- 非强制触发（自动定时器或 CronJob）时，执行防并发与防重复检查
    if not force then
        if state.is_analyzing and state.is_analyzing[group_id] then
            jn.log.warn(string.format("[%s] 群 %d 正在执行分析中，跳过并发调用", PLUGIN_NAME, group_id))
            return false, "正在执行中"
        end

        local last_date = nil
        if jn.cache and jn.cache.get then
            last_date = jn.cache.get(cache_key)
        end
        if not last_date and state.last_analyzed_date then
            last_date = state.last_analyzed_date[group_id]
        end

        if last_date == cur_date then
            jn.log.info(string.format("[%s] 群 %d 今日 (%s) 已完成过群总结报告，跳过重复执行", PLUGIN_NAME, group_id, cur_date))
            return true, "今日已完成"
        end

        -- 立即占位并落库当日标记，确保同一群同一日仅执行一次
        -- （覆盖消息不足、LLM 失败、发送失败等所有分支，彻底杜绝双触发重复推送）
        state.last_analyzed_date = state.last_analyzed_date or {}
        state.last_analyzed_date[group_id] = cur_date
        state.last_daily_date = cur_date
        if jn.cache and jn.cache.set then
            jn.cache.set(cache_key, cur_date, 86400 * 2)
        end
    end

    state.is_analyzing = state.is_analyzing or {}
    state.is_analyzing[group_id] = true

    local function run_task()
    group_id = tonumber(group_id)
    if not group_id then return false, "非法群号" end

    -- 进度提示：默认静默（enable_progress_feedback 打开才发）
    local feedback = jn.config.get("enable_progress_feedback")
    if feedback == true or feedback == "true" then
        local tip = "📊 正在提取分析近24小时群聊记录，大模型正在生成报告，请稍候..."
        if is_private_target then
            jn.onebot11.send_private_msg(send_target_id, tip)
        else
            jn.onebot11.send_group_msg(group_id, tip)
        end
    end
    local start_time = os.time()

    -- 1. 查询 24h 历史消息
    local all_messages = fetch_group_messages(group_id, 24)
    -- 带水印的是插件自动产出的卡片（仓库/文章总结），不参与聊天分析，
    -- 只用于 build_sections 里复用标题与总结
    local messages = {}
    for _, m in ipairs(all_messages) do
        if not is_bot_output(m.raw_message) then messages[#messages + 1] = m end
    end
    if #messages < 3 then
        local msg = string.format("📊 今日群聊发言较少（当前仅 %d 条，不足 3 条），暂无足够数据生成分析报告。", #messages)
        jn.log.warn(string.format("[%s] 群 %d 消息数不足 (%d < 3)，取消生成报告", PLUGIN_NAME, group_id, #messages))
        if is_private_target then
            jn.onebot11.send_private_msg(send_target_id, msg)
        else
            jn.onebot11.send_group_msg(group_id, msg)
        end
        return false, "消息过少"
    end

    -- 2. 统计概况
    local stats = analyze_statistics(messages)

    -- 3. 构建聊天流
    -- 语料展开：转发 / 图片 / 回复 / 语音视频文件变成模型可读文本
    -- （文件和视频只留占位，正文不入库；图片描述限量，转发按条展开）
    da_vision_used = 0
    local expanded = 0
    for _, m in ipairs(messages) do
        local before = m.content or ""
        m.content = expand_cq_content(m.raw_message, before)
        if m.content ~= before then expanded = expanded + 1 end
    end
    jn.log.info(string.format("[%s] 语料展开：%d/%d 条消息含 CQ 码，图片描述 %d 张",
        PLUGIN_NAME, expanded, #messages, da_vision_used))
    local chat_stream = format_chat_stream(messages)
    -- 诊断：把展开后的转发/图片行打一条样例日志，便于核对内容是否进入语料
    for line in chat_stream:gmatch("[^\n]+") do
        if line:find("【合并转发", 1, true) or line:find("【图片：", 1, true) then
            jn.log.info("[" .. PLUGIN_NAME .. "] 展开样例: " .. da_clip(line, 400))
        end
    end
    stats.total_chars = #chat_stream

    -- 4. 组装人设与 Prompt
    local persona_prompt = get_bot_persona_prompt()
    local prompt = build_analysis_prompt(chat_stream, stats, persona_prompt)

    -- 5. 调用 LLM（支持通过服务商名称、模型名或组合指定模型，留空默认使用激活模型）
    local target_provider_str = jn.config.get("text_provider_id") or ""
    local old_provider_id = nil
    local active_model_desc = "默认主模型"

    if jn.agent and jn.agent.get_providers then
        local providers, _ = jn.agent.get_providers()
        if providers and type(providers) == "table" then
            for _, p in ipairs(providers) do
                local p_type = tostring(p.Type or p.type or "")
                local p_active = (p.IsActive == true) or (p.is_active == true) or (p.active == true)
                local p_id = tostring(p.ID or p.id or "")
                local p_name = tostring(p.Name or p.name or "")
                local p_model = tostring(p.Model or p.model or "")

                if p_active and p_type == "text_model" then
                    old_provider_id = p_id
                    active_model_desc = p_model ~= "" and p_model or p_name
                    break
                end
            end

            if target_provider_str ~= "" then
                local chosen_p = match_text_provider(target_provider_str, providers)
                if chosen_p and jn.agent.switch_provider then
                    local chosen_id = tostring(chosen_p.ID or chosen_p.id or "")
                    local chosen_name = tostring(chosen_p.Name or chosen_p.name or "")
                    local chosen_model = tostring(chosen_p.Model or chosen_p.model or "")
                    if old_provider_id ~= chosen_id then
                        jn.agent.switch_provider(chosen_id)
                        active_model_desc = chosen_model ~= "" and chosen_model or chosen_name
                        jn.log.info(string.format("[%s] 临时挂载指定总结模型: %s", PLUGIN_NAME, active_model_desc))
                    else
                        active_model_desc = chosen_model ~= "" and chosen_model or chosen_name
                    end
                elseif not chosen_p then
                    jn.log.warn(string.format("[%s] 未找到匹配的文本模型: %q，回退使用系统激活模型: %s", PLUGIN_NAME, target_provider_str, active_model_desc))
                end
            end
        end
    end

    jn.log.info(string.format("[%s] 开始调用 LLM 分析群 %d 消息 (字符数: %d, 模型: %s)...", PLUGIN_NAME, group_id, #prompt, active_model_desc))
    local resp_text, err = jn.llm.chat({
        { role = "system", content = persona_prompt },
        { role = "user", content = prompt },
    }, { timeout = 300 })

    -- 若之前临时切换了 Provider，切回原 Provider 保持全局环境纯净
    if target_provider_str ~= "" and old_provider_id and jn.agent and jn.agent.switch_provider then
        jn.agent.switch_provider(old_provider_id)
    end
    if err or not resp_text or resp_text == "" then
        jn.log.error("[" .. PLUGIN_NAME .. "] LLM 分析失败: " .. tostring(err))
        return false, "LLM 调用失败: " .. tostring(err)
    end

    -- 6. 解析结构化数据
    local analysis_data = parse_llm_json(resp_text) or {}

    -- 7. 计算耗时与 Token
    local dur_sec = os.difftime(os.time(), start_time)
    if dur_sec < 1 then dur_sec = 1 end
    local est_tokens = math.floor((#prompt + #resp_text) / 2)
    local model_name = active_model_desc
    -- 获取群信息
    local group_name = "本群"
    if jn.onebot11.get_group_info then
        local ginfo = jn.onebot11.get_group_info(group_id)
        if ginfo and ginfo.group_name and ginfo.group_name ~= "" then
            group_name = ginfo.group_name
        end
    end

    -- 8. 组装板块（概况/话题/金句/头衔/质量/项目/新闻/统计，来源见 collect_sources）
    local sections = build_sections(stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, all_messages)

    -- 9. 按 report_mode 发送（forward 默认：一条合并转发；per_section；per_item）
    local target_type = is_private_target and "private" or "group"
    local dest_id = send_target_id or group_id
    local sent, nodes = send_report(sections, target_type, dest_id)
    if not sent or sent == 0 then
        jn.log.error(string.format("[%s] 日报发送失败或内容为空 (target=%s:%d)", PLUGIN_NAME, target_type, dest_id))
        return false, "发送失败"
    end

    local mode = tostring(jn.config.get("report_mode") or "forward")
    jn.log.info(string.format("[%s] 群 %d 日报已发送到 %s:%d（模式=%s，板块 %d 个，发送 %d 次 / 节点 %d）",
        PLUGIN_NAME, group_id, target_type, dest_id, mode, #sections, sent, nodes))

    -- 报告落库（与消息表同库，跨重启可查）
    pcall(persist_report, group_id, dest_id, sections, mode, nodes)

    -- 10. 自动清理过期历史
    prune_expired_messages()

    return true, nil
    end

    local ok, res, err_msg = pcall(run_task)
    state.is_analyzing[group_id] = nil
    if not ok then
        jn.log.error(string.format("[%s] 群 %d 总结执行异常: %s", PLUGIN_NAME, group_id, tostring(res)))
        return false, tostring(res)
    end
    return res, err_msg
end

-- ============================================================================
-- 13. 手动触发与定时检查
-- ============================================================================
function run_manual_trigger()
    if state.manual_running then return end
    state.manual_running = true

    local target_grp_str = jn.config.get("manual_target_group") or ""
    local send_target_str = jn.config.get("manual_send_target") or ""

    local target_groups = {}
    if target_grp_str ~= "" then
        for g in target_grp_str:gmatch("%d+") do
            table.insert(target_groups, tonumber(g))
        end
    end
    if #target_groups == 0 then
        local all_targets = get_target_groups()
        for gid, _ in pairs(all_targets) do
            table.insert(target_groups, gid)
        end
    end

    local send_target = tonumber(send_target_str)
    local is_private = false
    if send_target and send_target > 0 and send_target_str ~= "" then
        -- 目标类型以「机器人实际所在群列表」为准，别再靠长度/是否在 target_groups 猜
        local is_group_target = false
        if jn.onebot11.get_group_list then
            local groups = jn.onebot11.get_group_list()
            if type(groups) == "table" then
                for _, g in ipairs(groups) do
                    if tonumber(g.group_id or g.groupId or 0) == send_target then
                        is_group_target = true
                        break
                    end
                end
            end
        end
        if not is_group_target then
            if send_target_str:len() <= 11 then
                is_private = true
            else
                jn.log.warn(string.format("[%s] 目标 %s 既不是机器人所在群，也不像 QQ 号，放弃发送",
                    PLUGIN_NAME, send_target_str))
                return
            end
        end
    end

    for _, gid in ipairs(target_groups) do
        do_group_analysis(gid, send_target or gid, is_private, true)
    end

    state.manual_running = false
end

function check_manual_trigger()
    local trig = jn.config.get("manual_trigger")
    if (trig == true or trig == "true") and not state.manual_triggered_once then
        state.manual_triggered_once = true
        jn.log.info("[" .. PLUGIN_NAME .. "] 检测到后台手动触发开关已打开，调度群总结任务...")
        if jn.timer and jn.timer.after then
            jn.timer.after(0.5, { action = "manual_trigger" })
        else
            run_manual_trigger()
        end
    end
end
-- ============================================================================
-- 14. 异步定时器回调响应 (引擎级 on_timer_response)
-- ============================================================================
function on_timer_response(req_id, ctx, result, err)
    if err then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 定时器回调发生异常: " .. tostring(err))
        return
    end
    if not ctx or type(ctx) ~= "table" then return end

    if ctx.action == "manual_trigger" then
        jn.log.info("[" .. PLUGIN_NAME .. "] 异步定时器触发手动总结任务执行...")
        run_manual_trigger()
    elseif ctx.action == "daily_check" then
        check_daily_timer()
    end
end

-- ============================================================================
-- 14. CronJob 回调与内部定时器
-- ============================================================================
function on_cronjob(event)
    jn.log.info("[" .. PLUGIN_NAME .. "] 收到 CronJob 调度触发，开始执行每日群总结...")
    local specific_group = nil
    if event then
        if event.target_id and tonumber(event.target_id) and tonumber(event.target_id) > 0 and event.message_type == "group" then
            specific_group = tonumber(event.target_id)
        elseif event.payload and type(event.payload) == "table" and event.payload.group_id then
            specific_group = tonumber(event.payload.group_id)
        end
    end

    if specific_group and specific_group > 0 then
        jn.log.info(string.format("[%s] CronJob 指定目标群 %d，执行总结...", PLUGIN_NAME, specific_group))
        do_group_analysis(specific_group, specific_group, false)
        return
    end

    local targets = get_target_groups()
    for gid, _ in pairs(targets) do
        do_group_analysis(gid, gid, false)
    end
end

function check_daily_timer()
    local now_time = os.date("*t")
    local cur_date = os.date("%Y-%m-%d")
    local cur_hm = string.format("%02d:%02d", now_time.hour, now_time.min)

    local auto_time = tostring(jn.config.get("auto_analysis_time") or "23:00")
    if auto_time:len() == 4 then auto_time = "0" .. auto_time end

    if cur_hm == auto_time and state.last_daily_date ~= cur_date then
        state.last_daily_date = cur_date
        jn.log.info(string.format("[%s] 内部定时器触发每日总结 (时间: %s)...", PLUGIN_NAME, cur_hm))
        local targets = get_target_groups()
        for gid, _ in pairs(targets) do
            do_group_analysis(gid, gid, false)
        end
    end

    check_manual_trigger()

    if jn.timer and jn.timer.after then
        state.timer_id = jn.timer.after(30, { action = "daily_check" })
    end
end

-- ============================================================================
-- 15. 启动自检
-- ============================================================================
init_db()
-- 启动时立即检查手动触发配置（用于后台保存配置后立即生效）
check_manual_trigger()




if jn.timer and jn.timer.after then
    state.timer_id = jn.timer.after(10, { action = "daily_check" })
end
