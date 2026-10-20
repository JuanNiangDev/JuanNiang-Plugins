-- ============================================================================
-- daily_analysis: 群聊日常分析与总结插件
-- 作者: Churnie HXCN
-- 复刻自: astrbot_plugin_qq_group_daily_analysis (专为 JuanNiang-Neo 架构深度定制)
-- ============================================================================

local jn = require("jn")

-- 全局常量
local PLUGIN_NAME = "daily_analysis"
local TABLE_MESSAGES = "pluggin_daily_analysis_messages"

-- 内部运行状态
local state = {
    bot_uin = 0,
    timer_id = 0,
    last_daily_date = "",
    manual_running = false,
    manual_triggered_once = false,
    is_analyzing = {},
    last_analyzed_date = {},
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

local function is_command_or_noise(raw)
    if not raw or raw == "" then return true end
    -- 1. 移除回复引用 CQ 码
    local s = raw:gsub("%[CQ:reply,id=%-?%d+%]", "")
    -- 2. 移除合并转发 CQ 码
    s = s:gsub("%[CQ:forward,id=[^%]]+%]", "")
    -- 3. 移除所有 @ 提及 (包括 CQ:at 与文本 @)
    s = s:gsub("%[CQ:at,qq=[^%]]+%]", "")
    s = s:gsub("@%S+", "")
    -- 4. 移除多余空白
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return true end

    -- 5. 过滤以常规指令前缀开头的消息 (/ 或 # 或 ! 或 ！ 或 ／)
    if s:match("^[/#!#！／]%S*") then
        return true
    end

    -- 6. 过滤常见机器人与插件触发词（如今日老婆系列、签到等）
    local lower_s = s:lower()
    local command_prefixes = {
        "今日老婆", "查老婆", "我的老婆", "随机老婆", "娶老婆", "抽老婆",
        "强娶", "离婚", "休妻", "所有人都是我老婆", "全都要",
        "强娶全体成员", "全员老婆", "全部离婚", "净身出户",
        "老婆关系网", "绿帽图", "本群关系", "固定老婆",
        "同意固定老婆", "拒绝固定老婆", "解除固定老婆", "同意解除固定老婆",
        "签到", "打卡", "qd", "帮助", "菜单", "help", "ping", "美化", "运势", "重置"
    }

    for _, prefix in ipairs(command_prefixes) do
        local p_lower = prefix:lower()
        if lower_s == p_lower or lower_s:find("^" .. p_lower .. "%s") or lower_s:find("^" .. p_lower .. "$") then
            return true
        end
    end

    return false
end

local function clean_message_text(raw)
    if not raw or raw == "" then return "" end
    if is_command_or_noise(raw) then
        return ""
    end
    -- 移除回复引用 CQ 码
    local cleaned = raw:gsub("%[CQ:reply,id=%-?%d+%]", "")
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
        SELECT id, user_id, nickname, content, created_at
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
    local valid_messages = {}
    for _, msg in ipairs(messages) do
        local content = msg.content or ""
        local raw = msg.raw_message or ""
        if not is_command_or_noise(content) and not is_command_or_noise(raw) then
            table.insert(valid_messages, msg)
        end
    end

    local total_count = #valid_messages
    if total_count == 0 then
        return {
            total_count = 0,
            user_count = 0,
            peak_period = "无活跃记录",
            top_users = {},
            valid_messages = {},
        }
    end

    local user_counts = {}
    local user_names = {}
    local hour_counts = {}
    for h = 0, 23 do hour_counts[h] = 0 end

    for _, msg in ipairs(valid_messages) do
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
        valid_messages = valid_messages,
    }
end

-- ============================================================================
-- 5. 构建聊天流 (修复 2741226099 多行空行被拆为 3 条消息的 Bug)
-- ============================================================================
local function format_chat_stream(messages)
    local formatted = {}
    local participant_map = {}
    local participant_counter = 0

    local valid_idx = 0
    for _, msg in ipairs(messages) do
        local content = msg.content or ""
        local raw = msg.raw_message or ""
        if not is_command_or_noise(content) and not is_command_or_noise(raw) then
            valid_idx = valid_idx + 1
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
                valid_idx,
                time_str,
                p_info.label,
                p_info.name,
                content
            )
            table.insert(formatted, item_text)
        end
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
        topics_rule = string.format("提取 1 到不多于 %d 个今日核心热门话题。对零散讨论进行合理聚类归纳，严禁碎片化流水账！", max_topics)
    elseif max_topics == -1 then
        topics_rule = "全面覆盖今日群聊，但严禁碎片化琐碎堆砌！必须对讨论内容进行【合理归类与合并整合】，将同类问题、相似探讨归纳整合为精炼的主题板块，做到【全面覆盖、高度凝练、结构清晰】，提炼出 5~10 个最具代表性的综合核心话题板块！"
    else
        topics_rule = "无需提取话题（本项已关闭）"
    end

    local quotes_rule = ""
    if max_quotes > 0 then
        quotes_rule = string.format("甄选不多于 %d 句最具神人冲击力的高光金句", max_quotes)
    elseif max_quotes == -1 then
        quotes_rule = "全面甄选今日最具代表性、反差感、槽点拉满的精华高光金句，严禁平庸废话流水账，做到宁缺毋滥、全面且凝练（精选 3~8 句最具神人气质的精彩发言）！"
    else
        quotes_rule = "无需提取金句（本项已关闭）"
    end

    local titles_rule = ""
    if max_titles > 0 then
        titles_rule = string.format("为不多于 %d 位发言活跃群友评选极具特色的荣誉头衔与行为特征画像", max_titles)
    elseif max_titles == -1 then
        titles_rule = "为今日主要活跃群友评选极具特色的专属荣誉头衔与行为特征画像，画像精辟凝练、幽默切中要害，覆盖核心活跃群友（5~10 位），避免泛滥流水账！"
    else
        titles_rule = "无需评选头衔（本项已关闭）"
    end

    local critique_rule = ""
    if max_critiques ~= 0 then
        local count_text = (max_critiques > 0) and string.format("不多于 %d 个", max_critiques) or "3~6 个"
        if use_persona == "none" then
            critique_rule = string.format("将今日聊天合理抽象归纳为 %s 【高层级、泛化】的宏观维度（如技术探讨、职业规划、日常摸鱼、抽象整活等），严禁在维度名称中包含具体人名或琐碎小事，计算大致占比百分比（总和小于等于 100%%），并给出客观严谨的分析点评与全天综合表现总结！", count_text)
        else
            critique_rule = string.format("将今日聊天合理抽象归纳为 %s 【高层级、泛化】的宏观维度（如技术探讨、职业规划、日常摸鱼、抽象整活等），严禁在维度名称中包含具体人名或琐碎小事，计算大致占比百分比（总和小于等于 100%%），并【结合你的人格设定】给出贴合你性格与口吻的精彩、犀利或幽默点评，最后附一句全天综合表现终极金句总结！", count_text)
        end
    else
        critique_rule = "无需进行聊天质量点评（本项已关闭）"
    end

    local prompt = string.format([[
%s

你现在正在为群聊生成一份智能的「今日群聊日常分析报告」。
请根据下方给出的【群聊记录数据流】，按规则完成分析，并以严格的纯 JSON 格式返回。

## 核心任务要求：
1. 话题分析：%s。具体总结中，提及发言人时必须使用其真实的【QQ昵称】（nickname属性），严禁只写参与者编号或纯QQ号。话题描述请简述讨论背景、核心观点、关键分歧或结论（50~100字），做到凝练精辟，突出讨论深度。
2. 群圣经甄选：%s。
   【金句核心标准】：逆天的神人发言，具备颠覆常识的脑洞、逻辑跳脱的表达或强烈反差感的原创发言；包含夸张类比、反常规结论、一本正经的「胡说八道」或突破语境的清奇思路。严禁选择日常平庸碎语或无厘头水群文字！
   ⚠️【核心防拆分规则·重中之重】：
   在聊天记录中，每一个 `<msg id="...">` 标签内的内容代表单条完整发言。
   无论该发言内部包含多少个空行、换行或段落，必须作为一个完整的金句段落提取，绝对严禁按空行截断拆分成多条！
   content 字段必须完整保留原作者的换行与空行原貌（在 JSON 字符串中使用 \n 转义表示），sender 必须为发言人真实昵称。
3. 群友头衔：%s。user 必须填群友真实昵称，画像描述简练幽默、切中人物特征。
4. 质量锐评与人设点评：%s。

## ⚠️【绝对禁止事项·重中之重】：
1. 严禁总结任何机器人指令或插件触发命令（例如：/今日老婆、今日老婆、/qd、签到、/help、@机器人 等一切指令交互）！所有机器人调用与回复均为系统噪音，直接彻底忽略，严禁作为话题、金句、头衔或点评内容！
2. 严禁碎片化流水账堆砌！-1 选项代表全面覆盖群聊各方面，但必须【合理归类、聚类整合与高度凝练】，严禁无上限罗列散碎信息。

## 返回 JSON 数据结构规范（严禁包含 markdown 代码块包裹之外的杂质，必须是合法 JSON）：
```json
{
  "topics": [
    {
      "title": "话题标题（2-10字）",
      "summary": "核心脉络与要点概述（50-100字，凝练精辟）",
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
        "name": "抽象维度名称（如职业焦虑/技术交锋/深夜摸鱼）",
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
-- 9. 组装 6 大板块合并转发卡片 (Forward Nodes)
-- ============================================================================
local function build_forward_nodes(stats, analysis_data, group_id, group_name, dur_sec, est_tokens, model_name)
    local nodes = {}
    local custom_name = jn.config.get("custom_sender_name") or "奶蛙·群聊日报"
    local bot_uin = get_bot_uin()
    if bot_uin <= 0 then bot_uin = 1772023368 end

    local function add_node(content)
        if content and content ~= "" then
            table.insert(nodes, {
                user_id = bot_uin,
                nickname = custom_name,
                content = content,
            })
        end
    end

    -- 板块 1: 【群聊概况与活跃时段】
    local top_users_text = ""
    if stats.top_users and #stats.top_users > 0 then
        local user_lines = {}
        for idx = 1, math.min(3, #stats.top_users) do
            local u = stats.top_users[idx]
            table.insert(user_lines, string.format("  👑 Top%d: %s (%d条)", idx, u.name, u.count))
        end
        top_users_text = "\n🔥 发言主力军:\n" .. table.concat(user_lines, "\n")
    end

    local n1 = string.format([[
📊 【今日群聊日常分析报告】
━━━━━━━━━━━━━━━━━━━━
🏢 分析群聊: %s (%d)
📅 统计周期: 前 24 小时
💬 消息总量: %d 条
👥 参与人数: %d 人
⏰ 最活跃时段: %s%s
]], group_name, group_id, stats.total_count, stats.user_count, stats.peak_period, top_users_text)
    add_node(n1)

    -- 板块 2: 【今日核心话题】
    if analysis_data.topics and #analysis_data.topics > 0 then
        local topic_lines = {}
        for idx, t in ipairs(analysis_data.topics) do
            local part = (t.participants and t.participants ~= "") and (" (参聊: " .. t.participants .. ")") or ""
            table.insert(topic_lines, string.format("【%d】%s%s\n%s", idx, t.title or "核心话题", part, t.summary or ""))
        end
        local n2 = "🔥 【今日核心话题】\n━━━━━━━━━━━━━━━━━━━━\n" .. table.concat(topic_lines, "\n\n")
        add_node(n2)
    end

    -- 板块 3: 【群圣经 / 高光发言】（空行与换行 100% 还原原貌）
    if analysis_data.golden_quotes and #analysis_data.golden_quotes > 0 then
        local quote_lines = {}
        for idx, q in ipairs(analysis_data.golden_quotes) do
            local reason_text = (q.reason and q.reason ~= "") and ("\n💡 甄选理由: " .. q.reason) or ""
            table.insert(quote_lines, string.format("📜 金句 #%d · %s:\n「\n%s\n」%s", idx, q.sender or "群友", q.content or "", reason_text))
        end
        local n3 = "📖 【群圣经 / 高光发言】\n━━━━━━━━━━━━━━━━━━━━\n" .. table.concat(quote_lines, "\n\n")
        add_node(n3)
    end

    -- 板块 4: 【群友特色头衔 / 活跃画像】
    if analysis_data.user_titles and #analysis_data.user_titles > 0 then
        local title_lines = {}
        for idx, u in ipairs(analysis_data.user_titles) do
            table.insert(title_lines, string.format("🎖️ %s —— 获封「%s」\n  点评: %s", u.user or "群友", u.title or "活跃群友", u.description or "表现优异"))
        end
        local n4 = "👑 【群友特色头衔 / 画像】\n━━━━━━━━━━━━━━━━━━━━\n" .. table.concat(title_lines, "\n\n")
        add_node(n4)
    end

    -- 板块 5: 【聊天质量锐评与毒舌点评】
    if analysis_data.critique then
        local crit = analysis_data.critique
        local dim_lines = {}
        if crit.dimensions and #crit.dimensions > 0 then
            for _, d in ipairs(crit.dimensions) do
                local pct = d.percentage and (tostring(d.percentage) .. "%") or ""
                table.insert(dim_lines, string.format("▪ %s [%s]\n  %s", d.name or "维度", pct, d.comment or ""))
            end
        end
        local summary_text = (crit.overall_summary and crit.overall_summary ~= "") and ("\n\n🎯 终极表现总评:\n" .. crit.overall_summary) or ""
        local n5 = "🎭 【聊天质量分析与人设点评】\n━━━━━━━━━━━━━━━━━━━━\n" .. table.concat(dim_lines, "\n\n") .. summary_text
        add_node(n5)
    end

    -- 板块 6: 【本次分析统计与耗时】
    local n6 = string.format([[
📈 【本次分析统计】
━━━━━━━━━━━━━━━━━━━━
🤖 总结模型: %s
⏱️ 分析耗时: %.1f 秒
📝 输入字符: ~%d 字
⚡ 消耗 Token: ~%d tokens
✨ 报告完成，明日继续冲浪！
]], model_name, dur_sec, stats.total_chars or 0, est_tokens)
    add_node(n6)

    return nodes
end

-- ============================================================================
-- 10. 发送消息卡片 (群聊与私聊)
-- ============================================================================
local function send_summary_nodes(target_type, target_id, nodes)
    if #nodes == 0 then return false, "节点为空" end

    if target_type == "group" then
        if jn.onebot11.send_group_forward_msg_sync then
            return jn.onebot11.send_group_forward_msg_sync(target_id, nodes)
        elseif jn.onebot11.send_group_forward_msg then
            return jn.onebot11.send_group_forward_msg(target_id, nodes)
        end
    else
        -- 私聊目标
        if jn.onebot11.send_private_forward_msg_sync then
            return jn.onebot11.send_private_forward_msg_sync(target_id, nodes)
        elseif jn.onebot11.send_private_forward_msg then
            return jn.onebot11.send_private_forward_msg(target_id, nodes)
        else
            -- 引擎未提供私聊合并转发时的平滑降级：按节点逐条发送纯文本
            for _, n in ipairs(nodes) do
                jn.onebot11.send_private_msg(target_id, n.content)
            end
            return true, nil
        end
    end
    return false, "不支持的目标类型"
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
    end

    state.is_analyzing = state.is_analyzing or {}
    state.is_analyzing[group_id] = true

    local function run_task()
        -- 发送即时进度反馈提示（仅在后台开启 enable_progress_feedback 时发送）
        local show_progress = jn.config.get("enable_progress_feedback")
        if show_progress == true or show_progress == "true" then
            local tip = "📊 正在提取分析近24小时群聊记录，大模型正在生成报告，请稍候..."
            if is_private_target then
                jn.onebot11.send_private_msg(send_target_id, tip)
            else
                jn.onebot11.send_group_msg(group_id, tip)
            end
        end

        local start_time = os.time()

        -- 1. 查询 24h 历史消息
        local messages = fetch_group_messages(group_id, 24)
        -- 2. 统计概况并过滤消息
        local stats = analyze_statistics(messages)

        if stats.total_count < 3 then
            local msg = string.format("📊 今日有效发言较少（当前仅 %d 条有效消息，不足 3 条），暂无足够数据生成分析报告。", stats.total_count)
            jn.log.warn(string.format("[%s] 群 %d 有效消息数不足 (%d < 3)，取消生成报告", PLUGIN_NAME, group_id, stats.total_count))
            if is_private_target then
                jn.onebot11.send_private_msg(send_target_id, msg)
            else
                jn.onebot11.send_group_msg(group_id, msg)
            end
            return false, "消息过少"
        end

        -- 3. 构建聊天流
        local chat_stream = format_chat_stream(stats.valid_messages)
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
        })

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

        -- 8. 组装 6 大板块合并转发节点
        local nodes = build_forward_nodes(stats, analysis_data, group_id, group_name, dur_sec, est_tokens, model_name)

        -- 9. 发送结果
        local target_type = is_private_target and "private" or "group"
        local dest_id = send_target_id or group_id
        local ok, send_err = send_summary_nodes(target_type, dest_id, nodes)
        if not ok then
            jn.log.error(string.format("[%s] 发送分析报告失败 (target=%s:%d): %s", PLUGIN_NAME, target_type, dest_id, tostring(send_err)))
            return false, send_err
        end

        jn.log.info(string.format("[%s] 成功发送群 %d 日常分析报告到 %s:%d (节点数: %d)", PLUGIN_NAME, group_id, target_type, dest_id, #nodes))

        -- 记录成功执行日期，防止当日重复执行
        state.last_analyzed_date = state.last_analyzed_date or {}
        state.last_analyzed_date[group_id] = cur_date
        state.last_daily_date = cur_date
        if jn.cache and jn.cache.set then
            jn.cache.set(cache_key, cur_date, 86400 * 2)
        end

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

    local target_grp_str = tostring(jn.config.get("manual_target_group") or "")
    local send_target_str = tostring(jn.config.get("manual_send_target") or "")

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
    if send_target and send_target > 0 and send_target_str:len() <= 11 and not is_target_group(send_target) then
        is_private = true
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
        do_group_analysis(specific_group, specific_group, false, false)
        return
    end

    local targets = get_target_groups()
    for gid, _ in pairs(targets) do
        do_group_analysis(gid, gid, false, false)
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
            do_group_analysis(gid, gid, false, false)
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

