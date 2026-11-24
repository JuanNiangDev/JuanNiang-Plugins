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
local enrich = load_module("enrich", common)

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
    local limit = common.da_num("fetch_limit", 5000)
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

local function build_stream_messages(messages)
    local max_chars = math.max(100, common.da_num("max_msg_chars", 1000))
    local merge_on = common.da_bool("merge_repeats", true)
    if not merge_on then
        local out = {}
        for _, m in ipairs(messages) do
            out[#out + 1] = {
                id = m.id,
                user_id = m.user_id,
                nickname = m.nickname,
                content = common.clip_head_tail(m.content or "", max_chars),
                raw_message = m.raw_message,
                created_at = m.created_at,
                _source_msg = m,
            }
        end
        return out
    end

    local runs = {}
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

    local out = {}
    for _, r in ipairs(runs) do
        local m = r.first
        local content = common.clip_head_tail(m.content or "", max_chars)
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
        out[#out + 1] = {
            id = m.id,
            user_id = m.user_id,
            nickname = m.nickname,
            content = content,
            raw_message = m.raw_message,
            created_at = m.created_at,
            _source_msg = m,
        }
    end
    return out
end

local function format_chat_stream(messages)
    local formatted = {}
    for idx, msg in ipairs(messages) do
        local created = tostring(msg.created_at or "")
        local time_str = created:match("(%d%d:%d%d)") or "未知时间"
        -- 只给昵称、绝不给 QQ 号：避免模型在话题与金句中泄露号码
        local name = tostring(msg.nickname or ("群友" .. tostring(msg.user_id)))
        name = name:gsub('[<>\n"]', " ")

        formatted[#formatted + 1] = string.format(
            '<msg id="%d" time="%s" user="%s">\n%s\n</msg>',
            idx, time_str, name, msg.content or ""
        )
    end
    return common.safe_concat(formatted, "\n\n")
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
   - 禁止把「某人分享了一个链接/一篇公众号文章/一个仓库」单独列为话题——除非群里围绕它展开了讨论。零散分享并入最相关的话题，或合并成一条「资讯搬运」概述。
   - 提及发言人必须使用真实【QQ昵称】（nickname 属性），严禁只写参与者编号或纯 QQ 号。
   - 标题不超过 20 字，禁止「讨论 XX」「关于 XX」这种空壳标题。
2. 群圣经甄选：%s。
   ⚠️【入选门槛】只收让人拍案叫绝的内容：逆天逻辑、神反转、离谱反差、精准吐槽、或者真的牛逼。纯报错、纯复读、无信息短句一律不收，宁缺毋滥。
   ⚠️【只取本人正文】只收发言人自己打出的字。严禁把「【回复 某人：「…」】」这类被引用的原文写进 content；清掉 [CQ:...] 与 [图片] 等占位符。
   ⚠️【合并同人连发】同一个人连续 2-3 条消息如果合起来才成立（铺垫 + 抖包袱），合并成一条，content 用 \n 保留原貌。
   ⚠️【防拆分】每个 `<msg id="...">` 是一条完整发言，不得按空行拆成多条；sender 必须是真实昵称。
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
-- 8. 执行分析主流程 (do_group_analysis)
-- ============================================================================
local function do_group_analysis(group_id, send_target_id, is_private_target, force)
    group_id = tonumber(group_id)
    if not group_id then return false, "非法群号" end

    local cur_date = os.date("%Y-%m-%d")
    local cache_key = "last_analyzed:" .. tostring(group_id)

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
        if common.da_bool("enable_progress_feedback", false) then
            local tip = "📊 正在提取分析近24小时群聊记录，大模型正在生成报告，请稍候..."
            if is_private_target then
                jn.onebot11.send_private_msg(send_target_id, tip)
            else
                jn.onebot11.send_group_msg(group_id, tip)
            end
        end
        local start_time = os.time()

        -- 1. 查询 24h 历史消息；过滤掉机器人自身消息与水印卡片
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
            return false, "消息过少"
        end

        -- 2. 统计概况 & 语料展开与归并
        local stats = analyze_statistics(messages)
        sources.reset_vision_counter()
        local expanded = 0
        for _, m in ipairs(messages) do
            local before = m.content or ""
            m.content = sources.expand_cq_content(m.raw_message, before)
            if m.content ~= before then expanded = expanded + 1 end
        end
        local stream_messages = build_stream_messages(messages)
        jn.log.info(string.format("[%s] 语料展开：%d/%d 条消息含 CQ 码，图片描述 %d 张；复读归并：%d → %d 条",
            PLUGIN_NAME, expanded, #messages, sources.vision_used(), #messages, #stream_messages))
        local chat_stream = format_chat_stream(stream_messages)
        for line in chat_stream:gmatch("[^\n]+") do
            if line:find("【合并转发", 1, true) or line:find("【图片：", 1, true) then
                jn.log.info("[" .. PLUGIN_NAME .. "] 展开样例: " .. common.clip(line, 400))
            end
        end
        stats.total_chars = #chat_stream

        -- 3. 组装人设与 Prompt
        local persona_prompt = get_bot_persona_prompt()
        local prompt = build_analysis_prompt(chat_stream, stats, persona_prompt)

        -- 4. 选择模型并调用 LLM
        local target_provider_str = common.da_string("text_provider_id", "")
        local old_provider_id = nil
        local active_model_desc = "默认主模型"

        if jn.agent and jn.agent.get_providers then
            local providers = jn.agent.get_providers()
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
                            jn.log.info(string.format("[%s] 临时挂载指定总结模型: %s",
                                PLUGIN_NAME, chosen_model ~= "" and chosen_model or chosen_name))
                        end
                        active_model_desc = chosen_model ~= "" and chosen_model or chosen_name
                    elseif not chosen_p then
                        jn.log.warn(string.format("[%s] 未找到匹配的文本模型: %q，回退使用系统激活模型: %s",
                            PLUGIN_NAME, target_provider_str, active_model_desc))
                    end
                end
            end
        end

        local llm_timeout = math.max(30, common.da_num("llm_timeout", 300))
        jn.log.info(string.format("[%s] 开始调用 LLM 分析群 %d 消息 (字符数: %d, 超时: %ds, 模型: %s)...",
            PLUGIN_NAME, group_id, #prompt, llm_timeout, active_model_desc))
        local resp_text, err = jn.llm.chat({
            { role = "system", content = persona_prompt },
            { role = "user", content = prompt },
        }, { timeout = llm_timeout })

        if target_provider_str ~= "" and old_provider_id and jn.agent and jn.agent.switch_provider then
            jn.agent.switch_provider(old_provider_id)
        end
        if err or not resp_text or resp_text == "" then
            jn.log.error("[" .. PLUGIN_NAME .. "] LLM 分析失败: " .. tostring(err))
            return false, "LLM 调用失败: " .. tostring(err)
        end

        -- 5. 解析、组装板块、发送与落库
        local analysis_data = (common.decode_llm_json(resp_text, "LLM")) or {}
        local dur_sec = math.max(1, os.difftime(os.time(), start_time))
        local est_tokens = math.floor((#prompt + #resp_text) / 2)
        local group_name = "本群"
        if jn.onebot11.get_group_info then
            local ginfo = jn.onebot11.get_group_info(group_id)
            if ginfo and ginfo.group_name and ginfo.group_name ~= "" then
                group_name = ginfo.group_name
            end
        end

        local sections = report.build_sections(
            stats, analysis_data, group_name, group_id, dur_sec, est_tokens,
            active_model_desc, all_messages, stream_messages
        )
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
            return false, "发送失败"
        end

        local mode = common.da_string("report_mode", "forward")
        if mode == "" then mode = "forward" end
        jn.log.info(string.format("[%s] 群 %d 日报已发送到 %s:%d（模式=%s，板块 %d 个，发送 %d 次 / 节点 %d）",
            PLUGIN_NAME, group_id, target_type, dest_id, mode, #sections, sent, nodes))

        pcall(report.persist_report, group_id, dest_id, sections, mode, nodes)
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

    for _, gid in ipairs(target_groups) do
        do_group_analysis(gid, send_target or gid, is_private, true)
    end

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
    elseif ctx.action == "report_send_pump" then
        report.pump_send_queue()
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
        do_group_analysis(specific_group, specific_group, false)
        return
    end

    for gid, _ in pairs(get_target_groups()) do
        do_group_analysis(gid, gid, false)
    end
end

function check_daily_timer()
    local now_time = os.date("*t")
    local cur_date = os.date("%Y-%m-%d")
    local cur_hm = string.format("%02d:%02d", now_time.hour, now_time.min)

    local auto_time = common.da_string("auto_analysis_time", "23:00")
    if auto_time == "" then auto_time = "23:00" end
    if #auto_time == 4 then auto_time = "0" .. auto_time end

    if cur_hm == auto_time and state.last_daily_date ~= cur_date then
        state.last_daily_date = cur_date
        jn.log.info(string.format("[%s] 内部定时器触发每日总结 (时间: %s)...", PLUGIN_NAME, cur_hm))
        for gid, _ in pairs(get_target_groups()) do
            do_group_analysis(gid, gid, false)
        end
    end

    check_manual_trigger()

    if jn.timer and jn.timer.after then
        state.timer_id = jn.timer.after(30, { action = "daily_check" })
    end
end

-- ============================================================================
-- 10. 启动自检
-- ============================================================================
init_db()
check_manual_trigger(5)

if jn.timer and jn.timer.after then
    state.timer_id = jn.timer.after(10, { action = "daily_check" })
end
