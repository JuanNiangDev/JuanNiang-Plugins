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
local prompts = load_module("prompts", common)
local mapreduce = load_module("mapreduce", common, prompts)

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
                    bot_forward_text = sources.da_forward_text(fid, true, 0, false)
                    kept = common.is_bot_output(bot_forward_text)
                end
            end
            if not kept then
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
        SELECT id, user_id, nickname, content, raw_message, message_id, created_at FROM (
            SELECT id, user_id, nickname, content, raw_message, message_id, created_at
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
        or s:find("【合并转发", 1, true) or s:find("[转发#", 1, true)
        or s:find("【分享卡片", 1, true)
        or s:find("【图片：", 1, true) or s:find("[图#", 1, true) then
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
            msg_limit = math.max(max_chars, 3000)
        end
        local content = common.clip_head_tail(common.strip_wm(m.content or ""), msg_limit)
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

local format_chat_stream = common.format_chat_stream

-- ============================================================================
-- 6. LLM 提示词封装（由 prompts.lua 实现）
-- ============================================================================
local function build_section_caps()
    local caps = {}
    for _, sec in ipairs(report.parse_sections_config()) do
        caps[sec.key] = sec.cap
    end
    return caps
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

    -- 2. 全量统计概况（不受低质过滤影响）+ CQ 展开（含转发图片与编号索引）+ 归并过滤 + 紧凑流
    local stats = analyze_statistics(messages)
    sources.reset_vision_counter()
    local expanded = 0
    local expanded_by_msg_id = {}
    for _, m in ipairs(messages) do
        local before = m.content or ""
        m.content = sources.expand_cq_content(m.raw_message, before, expanded_by_msg_id)
        local mid = tonumber(m.message_id)
        if mid and mid > 0 then
            expanded_by_msg_id[mid] = m
        end
        if m.content ~= before then expanded = expanded + 1 end
    end
    local stream_messages, merged_count, filtered_count = build_stream_messages(messages)
    jn.log.info(string.format("[%s] 语料展开：%d/%d 条消息含 CQ 码，图片描述 %d 张；复读归并：%d → %d 条；过滤低质水贴：%d 条",
        PLUGIN_NAME, expanded, #messages, sources.vision_used(), #messages, merged_count, filtered_count))
    local chat_stream = format_chat_stream(stream_messages)
    for line in chat_stream:gmatch("[^\n]+") do
        if line:find("[转发#", 1, true) or line:find("[图#", 1, true)
            or line:find("【合并转发", 1, true) or line:find("【图片：", 1, true) then
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
            pending_wx = enrich.prepare_article_fetch(arts, 20)
        end
    end

    local function after_wx_fetched()
        local persona_prompt = prompts.get_bot_persona_prompt()
        local section_caps = build_section_caps()
        local function proceed_main_llm()
            mapreduce.run_main_llm_with_fallback(group_id, stream_messages, stats, persona_prompt, section_caps, {
                acquire_provider_slot = acquire_provider_slot,
            }, function(analysis_data, err, est_tokens, active_model_desc)
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
