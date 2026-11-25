-- ============================================================================
-- daily_analysis: 群聊日常分析与总结插件
-- 作者: Churnie HXCN
-- 复刻自: astrbot_plugin_qq_group_daily_analysis (专为 JuanNiang-Neo 架构深度定制)
-- ============================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

-- 新引擎用 jn.file.read；旧引擎没有 jn.file，退回 package.path 从插件目录 require。
local function load_module(name, ...)
    local fname = name .. ".lua"
    local factory
    if type(jn.file) == "table" and type(jn.file.read) == "function" then
        local src, err = jn.file.read(fname)
        if not src then error(fname .. " 读取失败: " .. tostring(err)) end
        local chunk, lerr = loadstring(src, fname)
        if not chunk then error(fname .. " 语法错误: " .. tostring(lerr)) end
        local ok, f = pcall(chunk)
        if not ok or type(f) ~= "function" then error(fname .. " 初始化失败") end
        factory = f
    else
        local old_path = package and package.path
        if package then package.path = "data/pluggins/daily_analysis/?.lua;" .. tostring(old_path or "") end
        local ok, f = pcall(require, name)
        if package then package.path = old_path or "" end
        if not ok or type(f) ~= "function" then error(fname .. " 读取失败: " .. tostring(f)) end
        factory = f
    end
    local ok2, mod = pcall(factory, jn, ...)
    if not ok2 or type(mod) ~= "table" then error(fname .. " 执行失败: " .. tostring(mod)) end
    return mod
end

local juya_ok, juya = pcall(load_module, "juya")
if not juya_ok then
    jn.log.error("juya 模块加载失败: " .. tostring(juya))
    juya = nil
end

local common = load_module("common")
local sources = load_module("sources", common)
local enrich = load_module("enrich", common, sources)

local PLUGIN_NAME = common.PLUGIN_NAME
local TABLE_MESSAGES = common.TABLE_MESSAGES
local TABLE_REPORTS = common.TABLE_REPORTS

-- 内部运行状态
local state = {
    bot_uin = 0,
    timer_id = 0,
    last_daily_date = "",
    manual_running = false,
    manual_triggered_once = false,
    wx_jobs = {},
    wx_seq = 0,
    group_queue = {},
    queued_gids = {},
    active_group = nil,
    active_started = 0,
    provider_hold = nil,
}

local function get_bot_uin()
    if state.bot_uin and state.bot_uin > 0 then
        return state.bot_uin
    end
    if jn.onebot11 and jn.onebot11.get_login_info then
        local info = jn.onebot11.get_login_info()
        if info and info.user_id then
            state.bot_uin = tonumber(info.user_id) or 0
            return state.bot_uin
        end
    end
    return 0
end

local report = load_module("report", common, sources, enrich, juya, get_bot_uin)

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
local function get_target_groups()
    local raw = jn.config.get("target_groups")
    local list = {}
    if type(raw) == "table" then
        for _, v in pairs(raw) do
            local gid = tonumber(v)
            if gid and gid > 0 then list[gid] = true end
        end
    elseif type(raw) == "string" then
        for item in raw:gmatch("[^,，%s]+") do
            local gid = tonumber(item)
            if gid and gid > 0 then list[gid] = true end
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
    -- 刻意保留图片与合并转发的 CQ 码，由语料展开阶段（expand_cq_content）补齐正文
    local cleaned = raw:gsub("%[CQ:reply,id=%-?%d+%]", "")
    if cleaned:match("^%s*[/#%!]%S+") then return "" end
    return cleaned:gsub("^%s+", ""):gsub("%s+$", "")
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
    local raw_msg = event.raw_message or ""

    -- 过滤机器人自身发言；但带本机水印的输出（repo-intro / 公众号总结）要入库，
    -- 以便日报直接复用已有总结而不重复调用 LLM。
    local filter_bot = common.da_bool("filter_bot_messages", true)
    local bot_forward_text = nil
    if filter_bot then
        local bot_uin = get_bot_uin()
        if bot_uin > 0 and sender_id == bot_uin then
            local kept = common.is_bot_output(raw_msg)
            if not kept then
                local fid = raw_msg:match("%[CQ:forward,id=([^,%]]+)%]")
                if fid then
                    bot_forward_text = sources.da_forward_text(fid, true)
                    kept = common.is_bot_output(bot_forward_text)
                end
            end
            if not kept then
                if raw_msg:find("📦", 1, true) or raw_msg:find("📰", 1, true) then
                    jn.log.warn(string.format("[%s] 疑似本机卡片输出但水印校验失败，未入库: %s",
                        PLUGIN_NAME, raw_msg:sub(1, 80)))
                end
                return false, nil
            end
        end
    end

    local nickname = ""
    if event.sender then
        nickname = event.sender.card or ""
        if nickname == "" then nickname = event.sender.nickname or "" end
    end
    if nickname == "" then
        nickname = "群友" .. tostring(sender_id)
    end

    local clean_text = clean_message_text(raw_msg)
    if clean_text == "" then
        return false, nil
    end
    if bot_forward_text and bot_forward_text ~= "" then
        clean_text = bot_forward_text
    end

    local msg_id = tonumber(event.message_id) or 0
    local sql = [[
        INSERT INTO ]] .. TABLE_MESSAGES .. [[
        (group_id, user_id, nickname, content, raw_message, message_id)
        VALUES (?, ?, ?, ?, ?, ?)
    ]]
    jn.database.exec(sql, { group_id, sender_id, nickname, clean_text, raw_msg, msg_id })

    check_manual_trigger()
    return false, nil
end

-- ============================================================================
-- 4. 历史记录查询与统计分析
-- ============================================================================
local function fetch_group_messages(group_id, hours)
    hours = hours or 24
    local limit = common.da_num("fetch_limit", 1500)
    if limit < 100 then limit = 100 end
    local sql = [[
        SELECT id, user_id, nickname, content, raw_message, created_at FROM (
            SELECT id, user_id, nickname, content, raw_message, created_at
            FROM ]] .. TABLE_MESSAGES .. [[
            WHERE group_id = ?
              AND created_at >= NOW() - (INTERVAL '1 hour' * ?)
            ORDER BY created_at DESC, id DESC
            LIMIT ?
        ) sub
        ORDER BY created_at ASC, id ASC
    ]]
    local rows, err = jn.database.query(sql, { group_id, hours, limit })
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

    local user_counts, user_names, hour_counts = {}, {}, {}
    for h = 0, 23 do hour_counts[h] = 0 end

    for _, msg in ipairs(messages) do
        local uid = msg.user_id
        user_counts[uid] = (user_counts[uid] or 0) + 1
        user_names[uid] = msg.nickname or ("群友" .. tostring(uid))

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

    local max_period_count, peak_start = -1, 0
    for h = 0, 22 do
        local window_sum = hour_counts[h] + hour_counts[h + 1]
        if window_sum > max_period_count then
            max_period_count = window_sum
            peak_start = h
        end
    end

    return {
        total_count = total_count,
        user_count = unique_users,
        peak_period = string.format("%02d:00 - %02d:00", peak_start, peak_start + 2),
        top_users = sorted_users,
    }
end

-- ============================================================================
-- 5. 语料归并（同人连发 / 多人复读 / 单条限长）与聊天流格式化
-- ============================================================================
local function norm_repeat_key(s)
    s = tostring(s or "")
    s = s:gsub("\r", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function is_low_signal_content(content)
    local s = tostring(content or "")
    if s == "" then return true end
    -- 含链接、合并转发、分享卡片、图像识别描述一律保留
    if s:find("https?://") or s:find("github%.com", 1, true)
        or s:find("huggingface%.co", 1, true) or s:find("modelscope%.", 1, true)
        or s:find("【合并转发", 1, true) or s:find("【分享卡片", 1, true)
        or s:find("【图片：", 1, true) then
        return false
    end
    local core = s:gsub("【回复.-」】", "")
    core = core:gsub("（连发 %d+ 次）$", "")
    core = core:gsub("（.-复读 %d+ 次）$", "")
    core = core:gsub("%[CQ:[^%]]*%]", "")
    for _, ph in ipairs({ "%[图片%]", "%[图%]", "%[表情%]", "%[语音%]", "%[视频%]", "%[文件%]", "%[卡片%]", "%[转发消息%]" }) do
        core = core:gsub(ph, "")
    end
    core = core:gsub("[%s%p]+", "")
    if core == "" then return true end
    local raw_trim = s:gsub("【回复.-」】", ""):gsub("^%s+", "")
    if raw_trim:find("^/%S+") then return true end
    return common.utf8_len(core) <= 2
end

local function build_stream_messages(messages)
    local max_chars = math.max(100, common.da_num("max_msg_chars", 1000))
    local merge_on = common.da_bool("merge_repeats", true)
    local filter_low = common.da_bool("filter_low_signal", true)
    local runs = {}

    if not merge_on then
        for _, m in ipairs(messages) do
            runs[#runs + 1] = { first = m, count = 1, user_names = { tostring(m.nickname or "") } }
        end
    else
        for _, m in ipairs(messages) do
            local key = norm_repeat_key(m.content or "")
            local last = runs[#runs]
            if key ~= "" and last and last.key == key then
                last.count = last.count + 1
                local uid = tostring(m.user_id or "")
                if not last.user_seen[uid] then
                    last.user_seen[uid] = true
                    last.user_names[#last.user_names + 1] = tostring(m.nickname or ("群友" .. uid))
                end
            else
                local uid = tostring(m.user_id or "")
                local nick = tostring(m.nickname or ("群友" .. uid))
                runs[#runs + 1] = {
                    key = key,
                    first = m,
                    count = 1,
                    user_seen = { [uid] = true },
                    user_names = { nick },
                }
            end
        end
    end

    local all_items, kept = {}, {}
    for _, r in ipairs(runs) do
        local m = r.first
        local msg_limit = max_chars
        if tostring(m.raw_message or ""):find("[CQ:forward,", 1, true) then
            msg_limit = math.max(max_chars, 2000)
        end
        local content = common.clip_head_tail(m.content or "", msg_limit)
        if r.count > 1 then
            if #r.user_names <= 1 then
                content = content .. string.format("（连发 %d 次）", r.count)
            else
                local preview = {}
                for i = 1, math.min(3, #r.user_names) do
                    preview[#preview + 1] = r.user_names[i]
                end
                local suffix = #r.user_names > 3 and " 等" or ""
                content = content .. string.format("（%s%s 共 %d 人复读 %d 次）",
                    table.concat(preview, "、"), suffix, #r.user_names, r.count)
            end
        end
        local item = {
            id = m.id,
            user_id = m.user_id,
            nickname = m.nickname,
            content = content,
            raw_message = m.raw_message,
            created_at = m.created_at,
            _source_msg = m,
        }
        all_items[#all_items + 1] = item
        if not filter_low or not is_low_signal_content(content) then
            kept[#kept + 1] = item
        end
    end
    -- 若几乎全为短消息导致过滤后不足 3 条，回退保留归并结果
    if #kept < 3 and #all_items >= 3 then
        return all_items, #runs, 0
    end
    return kept, #runs, (#all_items - #kept)
end

local function format_chat_stream(messages, start_idx)
    start_idx = start_idx or 1
    local formatted = {}
    for idx, msg in ipairs(messages) do
        local created = tostring(msg.created_at or "")
        local time_str = created:match("(%d%d:%d%d)") or "未知时间"
        -- 只给昵称、绝不给 QQ 号：避免模型在话题与金句中泄露号码
        local name = tostring(msg.nickname or ("群友" .. tostring(msg.user_id)))
        name = name:gsub('[<>\r\n"]', " ")
        local body = tostring(msg.content or ""):gsub("\r", ""):gsub("%s*\n+%s*", " / ")

        formatted[#formatted + 1] = string.format(
            '[#%d %s] %s: %s',
            start_idx + idx - 1, time_str, name, body
        )
    end
    return common.safe_concat(formatted, "\n")
end

-- ============================================================================
-- 6. LLM 人设与分析提示词
-- ============================================================================
local function get_bot_persona_prompt()
    local persona_style = jn.config.get("use_bot_persona") or "deep"
    if persona_style == "none" or persona_style == false or persona_style == "false" then
        return "你是一个客观、严谨、幽默的群聊内容分析专家。"
    end

    local persona_text = ""
    if jn.agent and jn.agent.get_persona then
        local p = jn.agent.get_persona()
        if type(p) == "table" and p.content and p.content ~= "" then
            persona_text = p.content
        elseif type(p) == "string" and p ~= "" then
            persona_text = p
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

local function build_analysis_prompt(chat_stream, stats, persona_prompt)
    local caps = {}
    for _, sec in ipairs(report.parse_sections_config()) do caps[sec.key] = sec.cap end
    local max_topics = caps.topics or 0
    local max_quotes = caps.quotes or 0
    local max_titles = caps.titles or 0
    local max_critiques = caps.critique or 0
    local use_persona = jn.config.get("use_bot_persona") or "deep"

    local topics_rule
    if max_topics > 0 then
        topics_rule = string.format("提取不多于 %d 个今日核心热门话题", max_topics)
    elseif max_topics == -1 then
        topics_rule = "提取今日出现的所有核心热门话题，不限数量上限"
    else
        topics_rule = "无需提取话题（本项已关闭）"
    end

    local quotes_rule
    if max_quotes > 0 then
        quotes_rule = string.format("甄选不多于 %d 句最具冲击力、反差感、神反转的「群圣经/高光金句」；引用必须逐字完整，禁止省略或概括", max_quotes)
    elseif max_quotes == -1 then
        quotes_rule = "甄选今日所有的逆天、反差、高光「群圣经/金句」，不限数量上限；引用必须逐字完整，禁止省略或概括"
    else
        quotes_rule = "无需提取金句（本项已关闭）"
    end

    local titles_rule
    if max_titles > 0 then
        titles_rule = string.format("为不多于 %d 位发言活跃群友评选极具特色的荣誉头衔与行为特征画像", max_titles)
    elseif max_titles == -1 then
        titles_rule = "为今日所有活跃群友评选极具特色的头衔与行为特征画像，不限数量上限"
    else
        titles_rule = "无需评选头衔（本项已关闭）"
    end

    local critique_rule
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

    return string.format([[
%s

你现在正在为群聊生成一份智能的「今日群聊日常分析报告」。
请根据下方给出的【群聊记录数据流】，按规则完成分析，并以严格的纯 JSON 格式返回。

## 核心任务要求：
1. 话题分析：%s。
   - summary 必须写成 150-300 字的叙事段落：交代起因、谁抛出了什么、群里怎么交锋、最后的结论或笑点；点名具体发言人（真实昵称），可以引用短句。
   - 禁止把「某人分享了一个链接/单篇短评/一个仓库」单独列为话题——除非群里围绕它展开了讨论。零散分享并入最相关的话题；若群里有成批合并转发的多篇公众号/资讯合集且未展开讨论，可合并成一条「资讯搬运」概述。
   - 提及发言人必须使用真实【QQ昵称】（nickname 属性），严禁只写参与者编号或纯 QQ 号。
   - 标题不超过 20 字，禁止「讨论 XX」「关于 XX」这种空壳标题。
2. 群圣经甄选：%s。
   ⚠️【入选门槛】只收让人拍案叫绝的内容：逆天逻辑、神反转、离谱反差、精准吐槽、或者真的牛逼。纯报错、纯复读、无信息短句一律不收，宁缺毋滥。
   ⚠️【只取本人正文】只收发言人自己打出的字。严禁把「【回复 某人：「…」】」这类被引用的原文写进 content；清掉 [CQ:...] 与 [图片] 等占位符。
   ⚠️【合并同人连发】同一个人连续 2-3 条消息如果合起来才成立（铺垫 + 抖包袱），合并成一条，content 用 \n 保留原貌。
   ⚠️【防拆分】每行 `[#编号 HH:MM]` 是一条完整发言，不得按空行拆成多条；msg_id 填对应的数字编号，sender 必须是真实昵称。
3. 群友头衔：%s。user 必须填群友真实昵称。
4. 质量锐评与人设点评：%s。

## 返回 JSON 数据结构规范（严禁包含 markdown 代码块包裹之外的杂质，必须是合法 JSON）：
```json
{
  "topics": [
    {
      "title": "话题标题（不超过 20 字）",
      "summary": "150-300 字叙事：起因、谁怎么说、交锋焦点、结论或笑点，点名发言人昵称",
      "participants": "主要讨论者（使用真实昵称，逗号分隔）"
    }
  ],
  "golden_quotes": [
    {
      "msg_id": 1,
      "sender": "发言人真实昵称",
      "content": "金句原文：逐字完整引用本人正文，保留原有换行；严禁省略、缩写、只留开头结尾或用省略号代替中间内容。不含被引用内容与 CQ 码；同人连发用换行串联",
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
end

-- ============================================================================
-- 7. 自动清理与模型匹配
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

    local report_days = tonumber(jn.config.get("report_retention_days") or "90") or 90
    if report_days <= 0 then report_days = 90 end
    local _, rerr = jn.database.exec("DELETE FROM " .. TABLE_REPORTS ..
        " WHERE created_at < NOW() - (INTERVAL '1 day' * ?)", { report_days })
    if rerr then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 清理过期报告失败: " .. tostring(rerr))
    end
end

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

    for _, p in ipairs(text_providers) do
        local pid = tostring(p.ID or p.id or ""):lower()
        local pname = tostring(p.Name or p.name or ""):lower():gsub("%s+", "")
        local pmodel = tostring(p.Model or p.model or ""):lower():gsub("%s+", "")
        if s == pid or s == pname or s == pmodel
            or s == (pname .. "·" .. pmodel)
            or s == (pname .. "." .. pmodel)
            or s == (pname .. "/" .. pmodel) then
            return p
        end
    end

    for _, p in ipairs(text_providers) do
        local pname = tostring(p.Name or p.name or ""):lower()
        local pmodel = tostring(p.Model or p.model or ""):lower()
        if pname:find(s, 1, true) or pmodel:find(s, 1, true)
            or s:find(pname, 1, true) or s:find(pmodel, 1, true) then
            return p
        end
    end

    return nil
end

-- ============================================================================
-- 8. 模型槽位管理、Map-Reduce 与全异步群分析流水线
-- ============================================================================
local function is_group_done_today(group_id, cur_date)
    local cache_key = "last_analyzed:" .. tostring(group_id)
    local last_date = nil
    if jn.cache and jn.cache.get then
        local v = jn.cache.get(cache_key)
        if type(v) == "table" and type(v.date) == "string" then
            last_date = v.date
        elseif type(v) == "string" then
            last_date = v
        end
    end
    if not last_date and state.last_analyzed_date then
        last_date = state.last_analyzed_date[group_id]
    end
    return last_date == cur_date
end

local function mark_group_done(group_id, cur_date)
    state.last_analyzed_date = state.last_analyzed_date or {}
    -- 清理跨日残留键，避免长期运行内存增长
    for gid, d in pairs(state.last_analyzed_date) do
        if d ~= cur_date then state.last_analyzed_date[gid] = nil end
    end
    state.last_analyzed_date[group_id] = cur_date
    if jn.cache and jn.cache.set then
        jn.cache.set("last_analyzed:" .. tostring(group_id), { date = cur_date }, 86400 * 2)
    end
end

local function acquire_provider_slot(target_provider_str)
    target_provider_str = tostring(target_provider_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local active_desc = state.provider_hold and state.provider_hold.desc or "默认主模型"
    if not (jn.agent and jn.agent.get_providers) then
        return active_desc, state.provider_hold and state.provider_hold.cur_id or ""
    end
    local providers = jn.agent.get_providers()
    if type(providers) ~= "table" then
        return active_desc, state.provider_hold and state.provider_hold.cur_id or ""
    end

    local cur_id, cur_desc = "", "默认主模型"
    for _, p in ipairs(providers) do
        local p_type = tostring(p.Type or p.type or "")
        local p_active = (p.IsActive == true) or (p.is_active == true) or (p.active == true)
        if p_active and p_type == "text_model" then
            cur_id = tostring(p.ID or p.id or "")
            local p_name = tostring(p.Name or p.name or "")
            local p_model = tostring(p.Model or p.model or "")
            cur_desc = p_model ~= "" and p_model or p_name
            break
        end
    end

    if not state.provider_hold then
        state.provider_hold = { old_id = cur_id, cur_id = cur_id, desc = cur_desc }
    end

    if target_provider_str ~= "" then
        local chosen_p = match_text_provider(target_provider_str, providers)
        if chosen_p and jn.agent.switch_provider then
            local chosen_id = tostring(chosen_p.ID or chosen_p.id or "")
            local chosen_name = tostring(chosen_p.Name or chosen_p.name or "")
            local chosen_model = tostring(chosen_p.Model or chosen_p.model or "")
            local chosen_desc = chosen_model ~= "" and chosen_model or chosen_name
            if chosen_id ~= "" and cur_id ~= chosen_id then
                pcall(jn.agent.switch_provider, chosen_id)
                jn.log.info(string.format("[%s] 临时挂载文本模型: %s", PLUGIN_NAME, chosen_desc))
            end
            state.provider_hold.cur_id = chosen_id
            state.provider_hold.desc = chosen_desc
            return chosen_desc, chosen_id
        elseif not chosen_p then
            jn.log.warn(string.format("[%s] 未找到匹配的文本模型: %q，继续使用: %s",
                PLUGIN_NAME, target_provider_str, state.provider_hold.desc))
        end
    end
    return state.provider_hold.desc, state.provider_hold.cur_id
end

local function release_provider_slot()
    local hold = state.provider_hold
    state.provider_hold = nil
    if hold and hold.old_id and hold.old_id ~= "" and hold.cur_id ~= hold.old_id
        and jn.agent and jn.agent.switch_provider then
        pcall(jn.agent.switch_provider, hold.old_id)
    end
end

local function partition_stream_chunks(stream_messages, chunk_chars, max_chunks)
    max_chunks = max_chunks or 8
    local total = 0
    for idx, msg in ipairs(stream_messages) do
        local line = format_chat_stream({ msg }, idx)
        total = total + #line + 1
    end
    local budget = math.max(8000, chunk_chars)
    if total > budget * max_chunks then
        budget = math.ceil(total / max_chunks)
    end
    local chunks, cur_msgs, cur_start, cur_size = {}, {}, 1, 0
    for idx, msg in ipairs(stream_messages) do
        local line_len = #format_chat_stream({ msg }, idx) + 1
        if cur_size + line_len > budget and #cur_msgs > 0 then
            chunks[#chunks + 1] = { start_idx = cur_start, msgs = cur_msgs }
            cur_msgs, cur_start, cur_size = {}, idx, 0
        end
        cur_msgs[#cur_msgs + 1] = msg
        cur_size = cur_size + line_len
    end
    if #cur_msgs > 0 then
        chunks[#chunks + 1] = { start_idx = cur_start, msgs = cur_msgs }
    end
    return chunks
end

local function build_map_prompt(chunk_stream, part_idx, total_parts, persona_prompt)
    return string.format([[%s

你正在执行大群日报的【第 %d/%d 时段切片提炼】任务。请从以下聊天片段中提取关键话题、高光金句和该时段人物/氛围亮点，严格返回纯 JSON：
```json
{
  "topics": [
    { "title": "话题标题(≤20字)", "summary": "80-160字分段叙事（点名真实昵称、交代起因结论）", "participants": "主要讨论者昵称，逗号分隔" }
  ],
  "golden_quotes": [
    { "msg_id": 1, "sender": "真实昵称", "content": "逐字原话(不含回复引用和CQ码)", "reason": "简短入选理由" }
  ],
  "highlights": ["1-2条时段氛围或活跃人物特点简述"]
}
```
注意：每行 `[#编号 HH:MM] 昵称: 内容` 中的编号即 `msg_id`；零散分享可忽略或合并，不要输出多余说明。

## 群聊切片记录：
%s]], persona_prompt, part_idx, total_parts, chunk_stream)
end

local function build_reduce_prompt(map_items, stats, persona_prompt, full_prompt_header_fn)
    local parts = {}
    local idx_ok = 0
    for k, m in ipairs(map_items) do
        if m.data then
            idx_ok = idx_ok + 1
            parts[#parts + 1] = string.format("【切片 %d 结果】\n%s", k, jn.json.encode(m.data))
        end
    end
    local top_lines = {}
    for i = 1, math.min(10, #(stats.top_users or {})) do
        local u = stats.top_users[i]
        top_lines[#top_lines + 1] = string.format("- %s: %d 条发言", u.name, u.count)
    end
    local digest_stream = string.format(
        "以下为全天 %d 个时段切片的结构化提炼结果（共原始发言 %d 条，请去重合并跨切片同话题、精炼为最终完整 JSON 报告）：\n\n### 活跃发言榜 Top10：\n%s\n\n### 分段提炼汇总：\n%s",
        idx_ok, stats.total_count,
        #top_lines > 0 and table.concat(top_lines, "\n") or "无",
        table.concat(parts, "\n\n")
    )
    return full_prompt_header_fn(digest_stream)
end

local MODERATION_HINTS = {
    "敏感内容", "敏感信息", "敏感词", "安全审核", "内容安全", "违规内容",
    "无法响应您的请求", "content_filter", "data_inspection_failed", "sensitive",
    "inappropriate", "high_risk", "safety policy",
}

local function is_moderation_rejection(resp, err)
    local combined = (tostring(resp or "") .. " " .. tostring(err or "")):lower()
    for _, pat in ipairs(MODERATION_HINTS) do
        if combined:find(pat, 1, true) then return true end
    end
    return false
end

local function merge_map_subresults(a, b)
    if not a then return b end
    if not b then return a end
    local out = { topics = {}, golden_quotes = {}, highlights = {} }
    for _, src in ipairs({ a, b }) do
        for _, t in ipairs(src.topics or {}) do out.topics[#out.topics + 1] = t end
        for _, q in ipairs(src.golden_quotes or {}) do out.golden_quotes[#out.golden_quotes + 1] = q end
        for _, h in ipairs(src.highlights or {}) do out.highlights[#out.highlights + 1] = h end
    end
    return out
end

local function slice_messages(msgs, s_idx, e_idx)
    local out = {}
    for i = s_idx, math.min(e_idx, #msgs) do out[#out + 1] = msgs[i] end
    return out
end

local function split_messages_evenly(msgs, start_idx, parts_count)
    local n = #msgs
    local max_slices = math.max(1, math.floor(n / 2))
    local actual_parts = math.max(1, math.min(parts_count, max_slices))
    local sub_slices = {}
    local base_len = math.floor(n / actual_parts)
    local rem = n % actual_parts
    local offset = 1
    for p = 1, actual_parts do
        local len = base_len + (p <= rem and 1 or 0)
        if len > 0 then
            sub_slices[#sub_slices + 1] = {
                start_idx = start_idx + offset - 1,
                msgs = slice_messages(msgs, offset, offset + len - 1),
            }
            offset = offset + len
        end
    end
    return sub_slices
end

local function run_with_concurrency(items, concurrency, worker_fn, on_all_done)
    local n = #items
    if n == 0 then
        on_all_done({})
        return
    end
    local results, next_i, in_flight, finished, done_called = {}, 1, 0, 0, false
    local function dispatch_next()
        while in_flight < concurrency and next_i <= n and not done_called do
            local idx = next_i
            next_i = next_i + 1
            in_flight = in_flight + 1
            worker_fn(idx, items[idx], function(res)
                in_flight = in_flight - 1
                finished = finished + 1
                results[idx] = res
                if finished >= n and not done_called then
                    done_called = true
                    on_all_done(results)
                else
                    dispatch_next()
                end
            end)
        end
    end
    dispatch_next()
end

local function run_map_slice_resplit(group_id, msgs, start_idx, label, total_parts, persona_prompt, llm_timeout, depth, budget, resplit_parts, on_slice_done)
    local c_stream = format_chat_stream(msgs, start_idx)
    local mprompt = build_map_prompt(c_stream, label, total_parts, persona_prompt)
    local io_chars = #mprompt

    common.llm_chat_async({
        { role = "system", content = persona_prompt },
        { role = "user", content = mprompt },
    }, { timeout = llm_timeout }, function(resp, err)
        if not err and resp and resp ~= "" then
            io_chars = io_chars + #resp
            local obj, perr = common.decode_llm_json(resp, tostring(label))
            if obj then
                on_slice_done(obj, nil, io_chars)
                return
            end
            err = perr or "JSON 解析失败"
        end

        local split_n = math.min(32, math.floor(resplit_parts or 8))
        if is_moderation_rejection(resp, err) and depth < 1 and split_n >= 2 and #msgs >= 8 and budget.remaining > 0 then
            budget.remaining = budget.remaining - 1
            local sub_slices = split_messages_evenly(msgs, start_idx, split_n)
            jn.log.warn(string.format("[%s] 群 %d Map-%s 命中敏感审查 (%d 条)，二次拆分为 %d 片挽救...",
                PLUGIN_NAME, group_id, tostring(label), #msgs, #sub_slices))
            run_with_concurrency(sub_slices, 2, function(k, sub, cb)
                local sub_label = string.format("%s.%d", tostring(label), k)
                run_map_slice_resplit(group_id, sub.msgs, sub.start_idx, sub_label, total_parts, persona_prompt, llm_timeout, depth + 1, budget, resplit_parts, function(s_obj, s_err, s_chars)
                    cb({ data = s_obj, err = s_err, chars = s_chars or 0 })
                end)
            end, function(sub_results)
                local merged, last_err, sub_chars = nil, nil, io_chars
                for _, sr in ipairs(sub_results) do
                    sub_chars = sub_chars + (sr.chars or 0)
                    if sr.data then
                        merged = merge_map_subresults(merged, sr.data)
                    elseif sr.err then
                        last_err = sr.err
                    end
                end
                local final_err = merged and nil or tostring(last_err or "二次拆片均未成功")
                on_slice_done(merged, final_err, sub_chars)
            end)
            return
        end

        jn.log.warn(string.format("[%s] 群 %d Map-%s 失败: %s",
            PLUGIN_NAME, group_id, tostring(label), tostring(err or "空响应")))
        on_slice_done(nil, tostring(err or "空响应"), io_chars)
    end)
end

local function run_map_reduce_async(group_id, stream_messages, stats, persona_prompt, llm_timeout, chunk_chars, model_desc, on_done, forced_chunks, initial_depth)
    local chunks = forced_chunks or partition_stream_chunks(stream_messages, chunk_chars, 8)
    if #chunks <= 1 then
        local stream_txt = format_chat_stream(stream_messages)
        local prompt = build_analysis_prompt(stream_txt, stats, persona_prompt)
        jn.log.info(string.format("[%s] 开始调用 LLM 分析群 %d 消息 (字符数: %d, 超时: %ds, 模型: %s)...",
            PLUGIN_NAME, group_id, #prompt, llm_timeout, model_desc))
        common.llm_chat_async({
            { role = "system", content = persona_prompt },
            { role = "user", content = prompt },
        }, { timeout = llm_timeout }, function(resp, err)
            if err or not resp or resp == "" then
                on_done(nil, tostring(err or "空响应"), #prompt)
                return
            end
            local obj, perr = common.decode_llm_json(resp, "LLM")
            if not obj then
                local tag_err = is_moderation_rejection(resp, nil) and ("moderation_rejected: " .. common.clip(resp, 80)) or (perr or "JSON 解析失败")
                on_done(nil, tag_err, #prompt + #resp)
                return
            end
            on_done(obj, nil, math.floor((#prompt + #resp) / 2))
        end)
        return
    end

    local resplit_parts = math.min(32, math.floor(common.da_num("map_resplit_count", 8)))
    jn.log.info(string.format("[%s] 群 %d %s，启动 Map-Reduce 分段分析（%d 段，并发 2，模型: %s）...",
        PLUGIN_NAME, group_id, forced_chunks and "二次拆片挽救" or "语料超阈值", #chunks, model_desc))
    local resplit_budget = { remaining = math.max(2, #chunks) }
    local start_depth = initial_depth or 0

    run_with_concurrency(chunks, 2, function(idx, c, cb)
        run_map_slice_resplit(group_id, c.msgs, c.start_idx, idx, #chunks, persona_prompt, llm_timeout, start_depth, resplit_budget, resplit_parts, function(obj, err, io_c)
            cb({ data = obj, err = err, io_chars = io_c or 0 })
        end)
    end, function(results)
        local ok_count, total_io_chars = 0, 0
        for _, r in ipairs(results) do
            total_io_chars = total_io_chars + (r.io_chars or 0)
            if r.data then ok_count = ok_count + 1 end
        end
        if ok_count == 0 then
            on_done(nil, results[1] and results[1].err or "全部分片分析失败", total_io_chars)
            return
        end
        local reduce_prompt = build_reduce_prompt(results, stats, persona_prompt, function(digest)
            return build_analysis_prompt(digest, stats, persona_prompt)
        end)
        total_io_chars = total_io_chars + #reduce_prompt
        jn.log.info(string.format("[%s] 群 %d Map 完成 (%d/%d 成功)，执行 Reduce 终稿汇总 (字符数: %d)...",
            PLUGIN_NAME, group_id, ok_count, #chunks, #reduce_prompt))
        common.llm_chat_async({
            { role = "system", content = persona_prompt },
            { role = "user", content = reduce_prompt },
        }, { timeout = llm_timeout }, function(resp, err)
            if err or not resp or resp == "" then
                on_done(nil, tostring(err or "Reduce 空响应"), math.floor(total_io_chars / 2))
                return
            end
            total_io_chars = total_io_chars + #resp
            local obj, perr = common.decode_llm_json(resp, "Reduce")
            if not obj then
                on_done(nil, perr or "Reduce JSON 解析失败", math.floor(total_io_chars / 2))
                return
            end
            on_done(obj, nil, math.floor(total_io_chars / 2))
        end)
    end)
end

local function run_main_llm_with_fallback(group_id, stream_messages, stats, persona_prompt, on_done)
    local llm_timeout = math.max(30, common.da_num("llm_timeout", 360))
    local map_thresh = math.max(10000, common.da_num("map_reduce_threshold", 50000))
    local chunk_chars = math.max(8000, common.da_num("map_chunk_chars", 35000))
    local target_str = common.da_string("text_provider_id", "")
    local fallback_str = common.da_string("fallback_text_provider", "")

    local model_desc, primary_id = acquire_provider_slot(target_str)

    local function run_with_msgs(msgs, cur_desc, allow_map, cb)
        local txt = format_chat_stream(msgs)
        if allow_map and #txt > map_thresh then
            run_map_reduce_async(group_id, msgs, stats, persona_prompt, llm_timeout, chunk_chars, cur_desc, cb)
            return
        end
        local prompt = build_analysis_prompt(txt, stats, persona_prompt)
        jn.log.info(string.format("[%s] 开始调用 LLM 分析群 %d 消息 (字符数: %d, 超时: %ds, 模型: %s)...",
            PLUGIN_NAME, group_id, #prompt, llm_timeout, cur_desc))
        common.llm_chat_async({
            { role = "system", content = persona_prompt },
            { role = "user", content = prompt },
        }, { timeout = llm_timeout }, function(resp, err)
            if err or not resp or resp == "" then
                cb(nil, tostring(err or "空响应"), math.floor(#prompt / 2))
                return
            end
            local obj, perr = common.decode_llm_json(resp, "LLM")
            if not obj then
                local tag_err = is_moderation_rejection(resp, nil) and ("moderation_rejected: " .. common.clip(resp, 80)) or (perr or "JSON 解析失败")
                cb(nil, tag_err, math.floor((#prompt + #resp) / 2))
                return
            end
            cb(obj, nil, math.floor((#prompt + #resp) / 2))
        end)
    end

    local function shrink_recent_half(msgs)
        if #msgs <= 20 then return msgs end
        local start_i = math.max(1, math.floor(#msgs / 2) + 1)
        local out = {}
        for i = start_i, #msgs do out[#out + 1] = msgs[i] end
        return out
    end

    run_with_msgs(stream_messages, model_desc, true, function(data, err, est_tokens)
        if data then
            on_done(data, nil, est_tokens, model_desc)
            return
        end
        local split_n = math.min(32, math.floor(common.da_num("map_resplit_count", 8)))
        if is_moderation_rejection(nil, err) and split_n >= 2 and #stream_messages >= 8 then
            local forced_chunks = split_messages_evenly(stream_messages, 1, split_n)
            jn.log.warn(string.format("[%s] 群 %d 单次请求命中敏感审查 (%d 条)，二次拆分为 %d 片挽救...",
                PLUGIN_NAME, group_id, #stream_messages, #forced_chunks))
            run_map_reduce_async(group_id, stream_messages, stats, persona_prompt, llm_timeout, chunk_chars, model_desc, function(mdata, merr, mtokens)
                if mdata then
                    on_done(mdata, nil, mtokens, model_desc)
                else
                    on_done(nil, tostring(merr or err), mtokens, model_desc)
                end
            end, forced_chunks, 1)
            return
        end
        jn.log.warn(string.format("[%s] 群 %d 主分析失败 (%s)，启动自动降级重试...",
            PLUGIN_NAME, group_id, tostring(err)))

        -- 降级 1：若配置了备用模型且不同于主模型，切换备用模型重跑（缩半窗口加速兜底）
        if fallback_str ~= "" then
            local fb_desc, fb_id = acquire_provider_slot(fallback_str)
            if fb_id ~= "" and fb_id ~= primary_id then
                local half_msgs = shrink_recent_half(stream_messages)
                run_with_msgs(half_msgs, fb_desc, true, function(fb_data, fb_err, fb_tokens)
                    if fb_data then
                        on_done(fb_data, nil, fb_tokens, fb_desc)
                    else
                        on_done(nil, "主与备用模型均失败: " .. tostring(fb_err), fb_tokens, fb_desc)
                    end
                end)
                return
            end
        end

        -- 降级 2：无可用备用模型时，收缩至最近 50% 语料（单次轻量）兜底重试
        local half_msgs = shrink_recent_half(stream_messages)
        if #half_msgs < #stream_messages then
            run_with_msgs(half_msgs, model_desc, false, function(d2, e2, t2)
                if d2 then
                    on_done(d2, nil, t2, model_desc)
                else
                    on_done(nil, "降级重试失败: " .. tostring(e2), t2, model_desc)
                end
            end)
        else
            on_done(nil, tostring(err), est_tokens, model_desc)
        end
    end)
end

local pump_group_queue

local function force_release_active_group(reason)
    local gid = state.active_group
    if gid then
        jn.log.warn(string.format("[%s] 强制释放群 %s 占用状态 (%s)", PLUGIN_NAME, tostring(gid), tostring(reason)))
        state.is_analyzing = state.is_analyzing or {}
        state.is_analyzing[gid] = nil
    end
    state.active_group = nil
    state.active_started = 0
    release_provider_slot()
    common.clear_pending_chats()
end

local function start_group_pipeline(spec, on_pipeline_done)
    local group_id = tonumber(spec.group_id)
    local send_target_id = spec.send_target_id or group_id
    local is_private_target = spec.is_private_target
    local force = spec.force
    local cur_date = os.date("%Y-%m-%d")

    if not group_id then on_pipeline_done(false, "非法群号"); return end
    if not force and is_group_done_today(group_id, cur_date) then
        jn.log.info(string.format("[%s] 群 %d 今日 (%s) 已完成过群总结报告，跳过重复执行", PLUGIN_NAME, group_id, cur_date))
        on_pipeline_done(true, "今日已完成")
        return
    end

    state.is_analyzing = state.is_analyzing or {}
    state.is_analyzing[group_id] = true
    state.active_group = group_id
    state.active_started = os.time()

    local function complete(ok, err_msg)
        state.is_analyzing[group_id] = nil
        state.active_group = nil
        state.active_started = 0
        release_provider_slot()
        on_pipeline_done(ok, err_msg)
    end

    if common.da_bool("enable_progress_feedback", false) then
        local tip = "📊 正在提取分析近24小时群聊记录，大模型正在生成报告，请稍候..."
        if is_private_target then
            jn.onebot11.send_private_msg(send_target_id, tip)
        else
            jn.onebot11.send_group_msg(group_id, tip)
        end
    end
    local start_time = os.time()

    -- 1. 查询 24h 历史消息；过滤机器人自身消息与水印卡片
    local all_messages = fetch_group_messages(group_id, 24)
    local messages = {}
    local bot_uin = get_bot_uin()
    for _, m in ipairs(all_messages) do
        if tonumber(m.user_id) ~= bot_uin and not common.is_bot_output(m.raw_message) then
            messages[#messages + 1] = m
        end
    end
    if #messages < 3 then
        local msg = string.format("📊 今日群聊发言较少（当前仅 %d 条，不足 3 条），暂无足够数据生成分析报告。", #messages)
        jn.log.warn(string.format("[%s] 群 %d 消息数不足 (%d < 3)，取消生成报告", PLUGIN_NAME, group_id, #messages))
        if is_private_target then
            jn.onebot11.send_private_msg(send_target_id, msg)
        else
            jn.onebot11.send_group_msg(group_id, msg)
        end
        complete(false, "消息过少")
        return
    end

    -- 2. 全量统计概况（不受低质过滤影响）+ CQ 展开 + 归并过滤 + 紧凑流
    local stats = analyze_statistics(messages)
    sources.reset_vision_counter()
    local expanded = 0
    for _, m in ipairs(messages) do
        local before = m.content or ""
        m.content = sources.expand_cq_content(m.raw_message, before)
        if m.content ~= before then expanded = expanded + 1 end
    end
    local stream_messages, merged_count, filtered_count = build_stream_messages(messages)
    jn.log.info(string.format("[%s] 语料展开：%d/%d 条消息含 CQ 码，图片描述 %d 张；复读归并：%d → %d 条；过滤低质水贴：%d 条",
        PLUGIN_NAME, expanded, #messages, sources.vision_used(), #messages, merged_count, filtered_count))
    local chat_stream = format_chat_stream(stream_messages)
    for line in chat_stream:gmatch("[^\n]+") do
        if line:find("【合并转发", 1, true) or line:find("【图片：", 1, true) then
            jn.log.info("[" .. PLUGIN_NAME .. "] 展开样例: " .. common.clip(line, 400))
        end
    end
    stats.total_chars = #chat_stream

    -- 2.5 预提取开源项目/公众号
    local precollected, pending_wx, news_cap = nil, {}, 0
    for _, sc in ipairs(report.parse_sections_config()) do
        if sc.key == "news" then news_cap = sc.cap; break end
    end
    if news_cap ~= 0 then
        local projs, arts = sources.collect_sources(all_messages)
        precollected = { projects = projs, articles = arts }
        if common.da_bool("enable_news", true) then
            pending_wx = enrich.prepare_article_fetch(arts, 12)
        end
    end

    local function after_wx_fetched()
        local persona_prompt = get_bot_persona_prompt()
        local function proceed_main_llm()
            run_main_llm_with_fallback(group_id, stream_messages, stats, persona_prompt, function(analysis_data, err, est_tokens, active_model_desc)
                if err or not analysis_data then
                    jn.log.error("[" .. PLUGIN_NAME .. "] LLM 分析失败: " .. tostring(err))
                    complete(false, "LLM 调用失败: " .. tostring(err))
                    return
                end
                local dur_sec = math.max(1, os.difftime(os.time(), start_time))
                local group_name = "本群"
                if jn.onebot11.get_group_info then
                    local ginfo = jn.onebot11.get_group_info(group_id)
                    if ginfo and ginfo.group_name and ginfo.group_name ~= "" then
                        group_name = ginfo.group_name
                    end
                end
                report.build_sections_async(
                    stats, analysis_data, group_name, group_id, dur_sec, est_tokens,
                    active_model_desc, all_messages, stream_messages, precollected,
                    function(sections)
                        local dest_id = send_target_id or group_id
                        local resolved_private = is_private_target
                        if resolved_private == nil then
                            resolved_private = false
                            if send_target_id and send_target_id ~= group_id then
                                local in_group = false
                                if jn.onebot11.get_group_list then
                                    local groups = jn.onebot11.get_group_list()
                                    if type(groups) == "table" then
                                        for _, g in ipairs(groups) do
                                            if tonumber(g.group_id or g.groupId or 0) == dest_id then
                                                in_group = true
                                                break
                                            end
                                        end
                                    end
                                end
                                if not in_group and jn.onebot11.get_group_info then
                                    local gi = jn.onebot11.get_group_info(dest_id)
                                    if type(gi) == "table" and tonumber(gi.group_id or 0) == dest_id then
                                        in_group = true
                                    end
                                end
                                if not in_group then resolved_private = true end
                            end
                        end
                        local target_type = resolved_private and "private" or "group"
                        local sent, nodes = report.send_report(sections, target_type, dest_id)
                        if not sent or sent == 0 then
                            jn.log.error(string.format("[%s] 日报发送失败或内容为空 (target=%s:%d)", PLUGIN_NAME, target_type, dest_id))
                            complete(false, "发送失败")
                            return
                        end

                        -- 仅在发回本群的正式日报成功发送后才写入今日已完成（手动私聊/发往测试群不阻断当晚定时发报；失败更不写入）
                        if (not force) or (dest_id == group_id and not resolved_private) then
                            mark_group_done(group_id, cur_date)
                        end
                        local mode = common.da_string("report_mode", "forward")
                        if mode == "" then mode = "forward" end
                        jn.log.info(string.format("[%s] 群 %d 日报已发送到 %s:%d（模式=%s，板块 %d 个，发送 %d 次 / 节点 %d）",
                            PLUGIN_NAME, group_id, target_type, dest_id, mode, #sections, sent, nodes))

                        pcall(report.persist_report, group_id, dest_id, sections, mode, nodes)
                        prune_expired_messages()
                        complete(true, nil)
                    end
                )
            end)
        end

        if #pending_wx > 0 and enrich.summarize_fetched_articles_async then
            acquire_provider_slot(common.da_string("text_provider_id", ""))
            enrich.summarize_fetched_articles_async(pending_wx, proceed_main_llm)
        else
            if #pending_wx > 0 then pcall(enrich.summarize_fetched_articles, pending_wx) end
            proceed_main_llm()
        end
    end

    if #pending_wx > 0 and jn.http and jn.http.get_async then
        state.wx_seq = (state.wx_seq or 0) + 1
        local job_id = string.format("%d_%d_%d", group_id, state.wx_seq, os.time())
        local job = {
            id = job_id,
            group_id = group_id,
            pending = pending_wx,
            remaining = #pending_wx,
            done = false,
            run_finish = after_wx_fetched,
        }
        state.wx_jobs = state.wx_jobs or {}
        state.wx_jobs[job_id] = job
        jn.log.info(string.format("[%s] 群 %d 检测到 %d 篇待补全公众号文章，启动异步抓取...",
            PLUGIN_NAME, group_id, #pending_wx))
        for idx, item in ipairs(pending_wx) do
            local ok_req = pcall(jn.http.get_async, item.url, {
                action = "da_wx_fetch",
                job_id = job_id,
                idx = idx,
            }, enrich.WX_HEADERS)
            if not ok_req then
                item.finished = true
                item.status = 0
                job.remaining = job.remaining - 1
            end
        end
        if job.remaining <= 0 then
            job.done = true
            state.wx_jobs[job_id] = nil
            after_wx_fetched()
            return
        end
        if jn.timer and jn.timer.after then
            jn.timer.after(35, { action = "da_wx_timeout", job_id = job_id })
        end
        return
    end

    after_wx_fetched()
end

pump_group_queue = function()
    if state.active_group then
        local timeout_sec = math.max(30, common.da_num("llm_timeout", 360))
        if (os.time() - (state.active_started or 0)) > (timeout_sec + 240) then
            force_release_active_group("超时看门狗解锁")
        else
            return
        end
    end
    if not state.group_queue or #state.group_queue == 0 then return end
    local spec = table.remove(state.group_queue, 1)
    if spec and spec.group_id then
        state.queued_gids[spec.group_id] = nil
    end
    local ok, perr = pcall(start_group_pipeline, spec, function()
        if jn.timer and jn.timer.after then
            jn.timer.after(0.1, { action = "da_group_pump" })
        else
            pump_group_queue()
        end
    end)
    if not ok then
        jn.log.error(string.format("[%s] 群 %s 启动异步分析异常: %s",
            PLUGIN_NAME, tostring(spec and spec.group_id), tostring(perr)))
        force_release_active_group("启动异常清理")
        pump_group_queue()
    end
end

local function query_group_counts_24h(gids)
    local counts = {}
    if #gids <= 1 or not (jn.database and jn.database.query) then return counts end
    local placeholders, args = {}, {}
    for _, gid in ipairs(gids) do
        placeholders[#placeholders + 1] = "?"
        args[#args + 1] = gid
    end
    local sql = string.format([[
        SELECT group_id, COUNT(*) AS cnt FROM %s
        WHERE group_id IN (%s) AND created_at >= NOW() - INTERVAL '24 hours'
        GROUP BY group_id
    ]], TABLE_MESSAGES, table.concat(placeholders, ","))
    local rows, err = jn.database.query(sql, args)
    if not err and type(rows) == "table" then
        for _, r in ipairs(rows) do
            local gid = tonumber(r.group_id)
            if gid then counts[gid] = tonumber(r.cnt) or 0 end
        end
    end
    return counts
end

local function enqueue_groups(specs)
    if type(specs) ~= "table" or #specs == 0 then return end
    state.group_queue = state.group_queue or {}
    state.queued_gids = state.queued_gids or {}
    state.is_analyzing = state.is_analyzing or {}

    local gids, valid_specs = {}, {}
    for _, sp in ipairs(specs) do
        local gid = tonumber(sp.group_id)
        if gid and not state.is_analyzing[gid] and not state.queued_gids[gid] then
            sp.group_id = gid
            gids[#gids + 1] = gid
            valid_specs[#valid_specs + 1] = sp
        elseif gid then
            jn.log.warn(string.format("[%s] 群 %d 已在队列或执行中，跳过重复入队", PLUGIN_NAME, gid))
        end
    end
    if #valid_specs == 0 then return end

    -- 小群优先：消息少的群先分析先发，不被超活跃大群拖死
    local counts = query_group_counts_24h(gids)
    table.sort(valid_specs, function(a, b)
        local ca = counts[a.group_id] or 0
        local cb = counts[b.group_id] or 0
        if ca ~= cb then return ca < cb end
        return a.group_id < b.group_id
    end)

    for _, sp in ipairs(valid_specs) do
        state.queued_gids[sp.group_id] = true
        state.group_queue[#state.group_queue + 1] = sp
    end
    if #valid_specs > 1 then
        local order = {}
        for _, sp in ipairs(valid_specs) do
            order[#order + 1] = string.format("%d(%d条)", sp.group_id, counts[sp.group_id] or 0)
        end
        jn.log.info(string.format("[%s] 多群任务已入队（小群优先）: %s", PLUGIN_NAME, table.concat(order, " → ")))
    end
    pump_group_queue()
end

-- ============================================================================
-- 9. 手动触发、定时检查与 CronJob
-- ============================================================================
function run_manual_trigger()
    if state.manual_running then return end
    state.manual_running = true

    local target_grp_str = common.da_string("manual_target_group", "")
    local send_target_str = common.da_string("manual_send_target", "")

    local target_groups = {}
    if target_grp_str ~= "" then
        for g in target_grp_str:gmatch("%d+") do
            table.insert(target_groups, tonumber(g))
        end
    end
    if #target_groups == 0 then
        for gid, _ in pairs(get_target_groups()) do
            table.insert(target_groups, gid)
        end
    end

    local send_target, is_private = nil, nil
    if send_target_str ~= "" then
        local explicit_type, explicit_id = send_target_str:match("^(%a+):(%d+)$")
        if explicit_type and explicit_id then
            send_target = tonumber(explicit_id)
            local et = explicit_type:lower()
            if et == "private" or et == "user" then
                is_private = true
            elseif et == "group" then
                is_private = false
            end
        else
            send_target = tonumber(send_target_str)
            if not send_target or send_target <= 0 then
                jn.log.warn(string.format("[%s] 无效发送目标 %q，放弃发送", PLUGIN_NAME, send_target_str))
                state.manual_running = false
                return
            end
            if #send_target_str > 11 then
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
                    jn.log.warn(string.format("[%s] 目标 %s 既不是机器人所在群，也不像 QQ 号，放弃发送",
                        PLUGIN_NAME, send_target_str))
                    state.manual_running = false
                    return
                end
                is_private = false
            end
        end
    end

    local specs = {}
    for _, gid in ipairs(target_groups) do
        specs[#specs + 1] = {
            group_id = gid,
            send_target_id = send_target or gid,
            is_private_target = is_private,
            force = true,
        }
    end
    enqueue_groups(specs)

    state.manual_running = false
end

function check_manual_trigger(delay_sec)
    if not common.da_bool("manual_trigger", false) then
        state.manual_triggered_once = false
        return
    end
    if not state.manual_triggered_once then
        state.manual_triggered_once = true
        jn.log.info("[" .. PLUGIN_NAME .. "] 检测到后台手动触发开关已打开，调度群总结任务...")
        if jn.timer and jn.timer.after then
            jn.timer.after(delay_sec or 0.5, { action = "manual_trigger" })
        else
            run_manual_trigger()
        end
    end
end

function on_chat_response(req_id, content, err)
    common.dispatch_chat_response(req_id, content, err)
end

local function schedule_daily_check(delay_sec)
    if jn.timer and jn.timer.after then
        pcall(function()
            state.timer_id = jn.timer.after(delay_sec or 30, { action = "daily_check" })
        end)
    end
end

local function parse_hhmm_minutes(hhmm)
    local h, m = tostring(hhmm or "23:00"):match("^(%d%d?):(%d%d)$")
    h, m = tonumber(h), tonumber(m)
    if not h or not m or h < 0 or h > 23 or m < 0 or m > 59 then return 23 * 60 end
    return h * 60 + m
end

common.on_async_panic = function(perr)
    force_release_active_group("异步回调异常恢复: " .. tostring(perr))
    pcall(pump_group_queue)
end

function on_timer_response(req_id, ctx, result, err)
    if err then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 定时器回调发生异常: " .. tostring(err))
        -- 即使 daily_check 回调报异常，也必须立刻续期，防止心跳死链导致第二天不再触发
        if type(ctx) == "table" and ctx.action == "daily_check" then
            schedule_daily_check(30)
        end
        return
    end
    if not ctx or type(ctx) ~= "table" then return end
    if common.handle_llm_timer(ctx) then return end

    if ctx.action == "manual_trigger" then
        jn.log.info("[" .. PLUGIN_NAME .. "] 异步定时器触发手动总结任务执行...")
        local ok, merr = pcall(run_manual_trigger)
        if not ok then
            jn.log.error("[" .. PLUGIN_NAME .. "] 手动总结任务异常: " .. tostring(merr))
            state.manual_running = false
        end
    elseif ctx.action == "daily_check" then
        check_daily_timer()
    elseif ctx.action == "da_group_pump" then
        pcall(pump_group_queue)
    elseif ctx.action == "report_send_pump" then
        pcall(report.pump_send_queue)
    elseif ctx.action == "da_wx_timeout" then
        local job = state.wx_jobs and state.wx_jobs[ctx.job_id]
        if job and not job.done then
            jn.log.warn(string.format("[%s] 群 %d 公众号文章抓取等待超时，使用已就绪结果继续生成报告",
                PLUGIN_NAME, job.group_id))
            job.done = true
            state.wx_jobs[job.id] = nil
            local ok, ferr = pcall(job.run_finish)
            if not ok then
                force_release_active_group("公众号超时后续异常: " .. tostring(ferr))
                pcall(pump_group_queue)
            end
        end
    end
end

function on_http_response(req_id, ctx, result, err)
    if not ctx or type(ctx) ~= "table" or ctx.action ~= "da_wx_fetch" then return end
    local job = state.wx_jobs and state.wx_jobs[ctx.job_id]
    if not job or job.done then return end
    local item = job.pending[ctx.idx]
    if item and not item.finished then
        item.finished = true
        if not err and type(result) == "table" then
            item.status = tonumber(result.status_code or result.status or 0) or 0
            item.body = tostring(result.body or "")
        else
            item.status = 0
            item.err = tostring(err or "http error")
        end
        job.remaining = job.remaining - 1
    end
    if job.remaining <= 0 then
        job.done = true
        state.wx_jobs[job.id] = nil
        local ok, ferr = pcall(job.run_finish)
        if not ok then
            force_release_active_group("公众号回调后续异常: " .. tostring(ferr))
            pcall(pump_group_queue)
        end
    end
end

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
        enqueue_groups({ { group_id = specific_group, send_target_id = specific_group, is_private_target = false, force = false } })
        return
    end

    local specs = {}
    for gid, _ in pairs(get_target_groups()) do
        specs[#specs + 1] = { group_id = gid, send_target_id = gid, is_private_target = false, force = false }
    end
    enqueue_groups(specs)
end

function check_daily_timer()
    -- 第一步先续期下一次 30s 巡检，确保任何内部异常都不会让第二天定时心跳死链
    schedule_daily_check(30)

    -- 看门狗巡检：防止个别群异步回调异常丢失后长期锁死队列
    if state.active_group then
        local timeout_sec = math.max(30, common.da_num("llm_timeout", 360))
        if (os.time() - (state.active_started or 0)) > (timeout_sec + 240) then
            force_release_active_group("巡检看门狗超时解锁")
            pcall(pump_group_queue)
        end
    end

    local now_time = os.date("*t")
    local cur_date = os.date("%Y-%m-%d")
    local now_min = (tonumber(now_time.hour) or 0) * 60 + (tonumber(now_time.min) or 0)

    local auto_time = common.da_string("auto_analysis_time", "23:00")
    if auto_time == "" then auto_time = "23:00" end
    local target_min = parse_hhmm_minutes(auto_time)

    -- 允许 15 分钟补发窗口（含跨零点差值），避免定时偏移几十秒跳过整天
    local delta = now_min - target_min
    if delta < 0 then delta = delta + 1440 end
    local in_window = (delta >= 0 and delta <= 15)
    local trigger_date = (now_min < target_min) and os.date("%Y-%m-%d", os.time() - 86400) or cur_date

    if in_window and state.last_daily_date ~= trigger_date then
        state.last_daily_date = trigger_date
        jn.log.info(string.format("[%s] 内部定时器触发每日总结 (当前 %02d:%02d, 设定 %s)...",
            PLUGIN_NAME, now_time.hour, now_time.min, auto_time))
        local specs = {}
        for gid, _ in pairs(get_target_groups()) do
            specs[#specs + 1] = { group_id = gid, send_target_id = gid, is_private_target = false, force = false }
        end
        local ok, qerr = pcall(enqueue_groups, specs)
        if not ok then
            jn.log.error("[" .. PLUGIN_NAME .. "] 定时入队异常: " .. tostring(qerr))
        end
    end

    pcall(check_manual_trigger)
end

-- ============================================================================
-- 10. 启动自检
-- ============================================================================
init_db()
check_manual_trigger(5)
schedule_daily_check(10)
