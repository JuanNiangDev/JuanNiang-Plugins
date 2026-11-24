-- ====================================================================
-- ai_reset_monitor  多平台 AI 重置与官方状态监控插件
-- --------------------------------------------------------------------
-- 纯后台控制（config.yaml），不注册聊天指令：
--   1. 直连官方 X 时间线 RSS（fxtwitter）、官方状态页（OpenAI/Claude/DeepSeek+Entireweb降级）、
--      交叉核验聚合源（whenaireset/agyresets/whenreset）与自定义额外 RSS/RSSHub。
--   2. 冷启动自动建立基线不刷旧帖；status 状态按阶段推进实时推送。
--   3. 对涉及 X 原链的事件通过 api.fxtwitter.com/status/<id> 回源官方原文核验。
--   4. 调用 Bot LLM 做客观语义鉴真 + 活跃人格润色，支持四档风格与分群订阅覆写。
-- ====================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

local function load_module(filename, ...)
    local src, err = jn.file.read(filename)
    if not src then
        jn.log.error("[ai_reset_monitor] 读取模块失败 " .. filename .. ": " .. tostring(err))
        return nil
    end
    local chunk, lerr = loadstring(src, filename)
    if not chunk then
        jn.log.error("[ai_reset_monitor] 解析模块语法失败 " .. filename .. ": " .. tostring(lerr))
        return nil
    end
    local ok, factory = pcall(chunk)
    if not ok or type(factory) ~= "function" then
        jn.log.error("[ai_reset_monitor] 模块未返回工厂函数 " .. filename)
        return nil
    end
    local ok2, mod = pcall(factory, ...)
    if not ok2 or type(mod) ~= "table" then
        jn.log.error("[ai_reset_monitor] 模块初始化失败 " .. filename .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local common = load_module("common.lua", jn)
local store = load_module("store.lua", jn, common)
local sources = load_module("sources.lua", jn, common)
local llm_mod = load_module("llm.lua", jn, common)

local state = {
    running = false,
    started_at = 0,
    last_poll_ts = 0,
    manual_done = false,
    was_quiet = false,
    batches = {},
    next_batch_id = 1,
    llm_pending = {},
    llm_queue = {},
    llm_inflight = false,
    llm_last_ts = 0,
    llm_pump_scheduled = false,
    restore_provider_id = nil,
    send_queue = {},
    send_timer_active = false,
}

-- --------------------------------------------------------------------
-- 串行节流发送队列（间隔 1.5s，避免并发突发触发协议端风控）
-- --------------------------------------------------------------------
local function enqueue_send(group_id, text)
    if not group_id or group_id <= 0 or not text or text == "" then return end
    state.send_queue[#state.send_queue + 1] = { group_id = group_id, text = text }
    if not state.send_timer_active and jn.timer and jn.timer.after then
        state.send_timer_active = true
        jn.timer.after(0.2, { action = "send_pump" })
    elseif not (jn.timer and jn.timer.after) then
        if jn.onebot11 and jn.onebot11.send_group_msg then
            jn.onebot11.send_group_msg(group_id, text)
        end
    end
end

local function pump_send_queue()
    if #state.send_queue == 0 then
        state.send_timer_active = false
        return
    end
    local item = table.remove(state.send_queue, 1)
    if item and jn.onebot11 and jn.onebot11.send_group_msg then
        local ok, err = jn.onebot11.send_group_msg(item.group_id, item.text)
        if not ok then
            jn.log.warn(string.format("[%s] 群 %s 发送失败: %s",
                common.PLUGIN_NAME, tostring(item.group_id), tostring(err)))
        end
    end
    if #state.send_queue > 0 and jn.timer and jn.timer.after then
        jn.timer.after(1.5, { action = "send_pump" })
    else
        state.send_timer_active = false
    end
end

-- --------------------------------------------------------------------
-- 事件类型过滤与静默队列冲刷
-- --------------------------------------------------------------------
local function enabled_event_kinds()
    local raw = common.cfg_list("notify_event_kinds")
    if #raw == 0 then
        return {
            direct_reset = true, banked_reset = true,
            scheduled_reset = true, rule_change = true,
            status_incident = true, status_resolved = true,
        }
    end
    local set = { status_incident = true, status_resolved = true }
    for _, v in ipairs(raw) do
        set[v:lower()] = true
    end
    return set
end

local function flush_pending_queues()
    if common.is_in_quiet_hours() then return end
    local gids = store.list_pending_groups()
    for _, gid in ipairs(gids) do
        local rows = store.take_pending_for_group(gid)
        if #rows > 0 then
            local blocks = { "☀️ 夜间静默期间收到的 AI 重置/状态提醒汇总：" }
            local ids = {}
            for _, r in ipairs(rows) do
                ids[#ids + 1] = r.id
                blocks[#blocks + 1] = "────────\n" .. tostring(r.message_text or "")
            end
            -- 单条过大时按每 3 条拆段
            local chunk_size = 3
            if #rows <= chunk_size then
                enqueue_send(gid, table.concat(blocks, "\n"))
            else
                enqueue_send(gid, blocks[1])
                for i = 2, #blocks, chunk_size do
                    local slice = {}
                    for j = i, math.min(#blocks, i + chunk_size - 1) do
                        slice[#slice + 1] = blocks[j]
                    end
                    enqueue_send(gid, table.concat(slice, "\n"))
                end
            end
            store.delete_pending_ids(ids)
            jn.log.info(string.format("[%s] 已向群 %s 补发夜间静默消息 %d 条",
                common.PLUGIN_NAME, tostring(gid), #rows))
        end
    end
end

-- --------------------------------------------------------------------
-- 批处理收尾与分群发送
-- --------------------------------------------------------------------
local function build_diagnostic_summary(batch)
    local lines = {
        "🩺 AI 重置与服务状态监控 — 手动诊断汇总",
        "🕒 检测时间：" .. common.format_cst(os.time()),
        string.format("📡 信源统计：总计 %d 个（成功 %d / 失败 %d）",
            batch.total_sources, batch.ok_sources, batch.fail_sources),
    }
    if #batch.errors > 0 then
        lines[#lines + 1] = "⚠️ 异常信源：" .. common.clip(table.concat(batch.errors, "；"), 300)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "📋 各产品最新记录："

    local by_prod = {}
    -- 先填数据库最近已知记录，再用本次抓到的最新记录覆盖
    for _, row in ipairs(store.latest_per_product()) do
        by_prod[row.product] = {
            product = row.product,
            title = row.title,
            event_kind = row.event_kind,
            ts = tonumber(row.announced_ts) or 0,
            url = row.source_url,
        }
    end
    for _, cand in pairs(batch.latest_by_prod) do
        local cur = by_prod[cand.product]
        if not cur or (cand.announced_ts or 0) >= (cur.ts or 0) then
            by_prod[cand.product] = {
                product = cand.product,
                title = cand.title,
                event_kind = cand.event_kind or "",
                ts = cand.announced_ts or 0,
                url = cand.source_url,
            }
        end
    end

    local all_prods = {}
    for _, k in ipairs(common.RESET_PRODUCTS) do all_prods[#all_prods + 1] = k end
    for _, k in ipairs(common.STATUS_PRODUCTS) do all_prods[#all_prods + 1] = k end

    for _, pk in ipairs(all_prods) do
        local label = common.PRODUCT_LABELS[pk] or pk
        local rec = by_prod[pk]
        if rec then
            local ts_str = rec.ts > 0 and common.format_cst(rec.ts) or "未知时间"
            lines[#lines + 1] = string.format("• %s\n  %s | %s",
                label, ts_str, common.clip(rec.title or "", 64))
        else
            lines[#lines + 1] = string.format("• %s：暂无重置/异常信号", label)
        end
    end

    return table.concat(lines, "\n")
end

local function dispatch_event_to_groups(batch, ev)
    local kinds_ok = enabled_event_kinds()
    if not kinds_ok[ev.event_kind] then
        jn.log.info(string.format("[%s] 事件类型未开启，跳过推送: %s (%s)",
            common.PLUGIN_NAME, tostring(ev.product), tostring(ev.event_kind)))
        if not batch.is_manual then store.mark_seen(ev, false) end
        return
    end

    local default_style = common.norm_style(common.cfg_string("summary_style", "both"), "both")

    -- 手动回放测试：仅发送给 test_group（按该群在 group_subscriptions 中的风格，否则跟随全局默认）
    if batch.is_manual and batch.replay_hours > 0 then
        local gid = batch.manual_target_gid
        if gid and gid > 0 then
            local style = default_style
            for _, sub in ipairs(batch.subs) do
                if sub.group_id == gid then
                    if not sub.products[ev.product] then
                        return
                    end
                    style = sub.style or default_style
                    break
                end
            end
            enqueue_send(gid, llm_mod.format_alert(ev, style))
            batch.replayed_count = (batch.replayed_count or 0) + 1
        end
        return
    end

    local quiet = common.is_in_quiet_hours()
    local rendered_cache = {}
    local delivered_any = false

    for _, sub in ipairs(batch.subs) do
        if sub.products[ev.product] then
            local style = sub.style or default_style
            local eff_key = style
            if style == "major_persona" then
                eff_key = ev.is_major and "both" or "objective"
            end
            if not rendered_cache[eff_key] then
                rendered_cache[eff_key] = llm_mod.format_alert(ev, style)
            end
            local msg = rendered_cache[eff_key]
            if quiet then
                store.enqueue_pending(sub.group_id, ev.event_key, ev.product, msg)
                delivered_any = true
            else
                enqueue_send(sub.group_id, msg)
                delivered_any = true
            end
        end
    end

    store.mark_seen(ev, delivered_any)
end

local function finish_batch_if_ready(batch)
    if not batch or batch.finished then return end
    if batch.pending_http > 0 or batch.pending_llm > 0 then return end

    batch.finished = true
    state.batches[batch.id] = nil
    state.running = false

    if batch.is_manual then
        local gid = batch.manual_target_gid
        if gid and gid > 0 then
            if batch.replay_hours > 0 then
                local summary = string.format(
                    "🧪 手动回放测试完成（最近 %d 小时）：信源 %d/%d，共命中并推送 %d 条提醒。",
                    batch.replay_hours, batch.ok_sources, batch.total_sources, batch.replayed_count or 0
                )
                enqueue_send(gid, summary)
                jn.log.info(string.format("[%s] 手动回放测试完成 target=%d replayed=%d",
                    common.PLUGIN_NAME, gid, batch.replayed_count or 0))
            else
                enqueue_send(gid, build_diagnostic_summary(batch))
                jn.log.info(string.format("[%s] 手动诊断报告已加入发送队列 target=%d", common.PLUGIN_NAME, gid))
            end
        else
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] manual_trigger 完成，但未配置 test_group 或 group_subscriptions")
        end
    else
        for _, cand in ipairs(batch.baseline_marks) do
            store.mark_seen(cand, false)
        end
        for _, src_key in ipairs(batch.seed_marks) do
            store.mark_seen({ event_key = src_key, product = "_meta", event_kind = "seed", title = src_key }, false)
        end
        if not common.is_in_quiet_hours() then
            flush_pending_queues()
        end
    end

    jn.log.info(string.format("[%s] 轮询完成 (manual=%s, 源=%d/%d, 候选=%d, LLM校验=%d)",
        common.PLUGIN_NAME, tostring(batch.is_manual), batch.ok_sources, batch.total_sources,
        batch.candidate_count, batch.llm_count))
end

-- --------------------------------------------------------------------
-- 串行节流 LLM 队列（单并发 + 退避重试 + 自动切备选模型，完成后还原主模型）
-- --------------------------------------------------------------------
local function restore_provider_if_needed()
    if state.restore_provider_id and jn.agent and jn.agent.switch_provider then
        local ok, err = pcall(jn.agent.switch_provider, state.restore_provider_id)
        if not ok then
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 还原主模型失败: " .. tostring(err))
        else
            jn.log.info("[" .. common.PLUGIN_NAME .. "] 已还原主文本模型")
        end
        state.restore_provider_id = nil
    end
end

local function switch_temp_provider(target_query, reason)
    local q = common.trim(target_query)
    if q == "" or not (jn.agent and jn.agent.switch_provider) then return false end
    local target, active = llm_mod.match_text_provider(q)
    if not target then
        jn.log.warn(string.format("[%s] 未找到匹配的文本模型 %q", common.PLUGIN_NAME, q))
        return false
    end
    local tid = tostring(target.ID or target.id or "")
    local aid = active and tostring(active.ID or active.id or "") or ""
    if tid == "" or tid == aid then return false end
    if not state.restore_provider_id and aid ~= "" then
        state.restore_provider_id = aid
    end
    local ok, err = pcall(jn.agent.switch_provider, tid)
    if ok then
        local label = tostring(target.Name or target.name or target.Model or target.model or tid)
        jn.log.info(string.format("[%s] 临时切换文本模型至 %s（%s）", common.PLUGIN_NAME, label, tostring(reason)))
        return true
    end
    jn.log.warn(string.format("[%s] 切换文本模型失败 %s: %s", common.PLUGIN_NAME, tid, tostring(err)))
    return false
end

local function schedule_llm_pump(delay, waited)
    if state.llm_pump_scheduled then return end
    if jn.timer and jn.timer.after then
        state.llm_pump_scheduled = true
        jn.timer.after(math.max(0.1, delay or 0.1), { action = "llm_pump", waited = waited == true })
    end
end

local function is_transient_llm_err(err)
    local s = tostring(err or ""):lower()
    return s:find("503", 1, true) ~= nil
        or s:find("429", 1, true) ~= nil
        or s:find("no_healthy_account", 1, true) ~= nil
        or s:find("unavailable", 1, true) ~= nil
        or s:find("timeout", 1, true) ~= nil
        or s:find("rate", 1, true) ~= nil
end

local function finalize_llm_fallback(batch, cand)
    local fb = llm_mod.deterministic_fallback(cand)
    if fb.is_relevant then
        cand.product = fb.product
        cand.event_kind = fb.event_kind
        cand.is_major = fb.is_major
        cand.title = fb.title
        cand.scope = fb.scope
        cand.objective_summary = fb.objective_summary
        cand.persona_comment = fb.persona_comment
        dispatch_event_to_groups(batch, cand)
    else
        if not batch.is_manual then
            cand.event_kind = "unrelated"
            store.mark_seen(cand, false)
        end
    end
end

local function pump_llm_queue(waited)
    if state.llm_inflight then return end
    while #state.llm_queue > 0 and state.llm_queue[1].batch.finished do
        table.remove(state.llm_queue, 1)
    end
    if #state.llm_queue == 0 then
        restore_provider_if_needed()
        return
    end

    local min_gap = math.max(0.2, common.cfg_num("llm_min_interval", 1.5))
    local now = os.time()
    local elapsed = now - state.llm_last_ts
    if not waited and state.llm_last_ts > 0 and elapsed < min_gap and jn.timer and jn.timer.after then
        schedule_llm_pump(min_gap - elapsed, true)
        return
    end

    -- 如配置了首选模型，在队列启动时切换到首选模型
    local pref = common.cfg_string("text_provider_id", "")
    if pref ~= "" and not state.used_fallback_provider then
        switch_temp_provider(pref, "插件指定模型")
    end

    local task = table.remove(state.llm_queue, 1)
    local batch = task.batch
    local cand = task.cand

    local messages = llm_mod.build_messages(cand, batch.need_persona)
    local timeout = math.max(15, common.cfg_num("llm_timeout", 60))
    state.llm_inflight = true
    state.llm_last_ts = os.time()
    local req_id, err = jn.llm.chat_async(messages, { timeout = timeout })
    if not req_id or req_id == 0 then
        state.llm_inflight = false
        jn.log.warn(string.format("[%s] 提交 LLM 失败: %s", common.PLUGIN_NAME, tostring(err)))
        batch.pending_llm = math.max(0, batch.pending_llm - 1)
        finalize_llm_fallback(batch, cand)
        finish_batch_if_ready(batch)
        schedule_llm_pump(min_gap)
        return
    end
    state.llm_pending[req_id] = task
end

local function submit_candidate_to_llm(batch, cand)
    if batch.is_manual and (batch.replay_hours or 0) <= 0 then return end

    if cand.skip_unless_state_changed then
        if batch.is_manual then return end
        -- Entireweb 状态（normal / outage）：仅在状态发生真实切换时通报，正常时写基线不推送
        local prev_outage = store.has_seen("ds_entireweb_active")
        if cand.entireweb_state == "normal" then
            if prev_outage then
                store.mark_seen({ event_key = "ds_entireweb_active", product = "deepseek_status", event_kind = "cleared" }, false)
                cand.event_key = "ds_entireweb_recovered:" .. tostring(os.time())
            else
                return
            end
        else
            if prev_outage then return end
            store.mark_seen({ event_key = "ds_entireweb_active", product = "deepseek_status", event_kind = "active" }, false)
            cand.event_key = "ds_entireweb_outage:" .. tostring(os.time())
        end
    end

    if not jn.llm or not jn.llm.available or not jn.llm.available() or not jn.llm.chat_async then
        finalize_llm_fallback(batch, cand)
        return
    end

    batch.pending_llm = batch.pending_llm + 1
    batch.llm_count = batch.llm_count + 1
    state.llm_queue[#state.llm_queue + 1] = { batch = batch, cand = cand, attempt = 0 }
    if jn.timer and jn.timer.after then
        schedule_llm_pump(0.1)
    else
        pump_llm_queue()
    end
end

local function process_source_candidates(batch, src, body)
    local seed_key = "seed:" .. src.id
    local is_seeded = store.has_seen(seed_key)
    local skip_cold = common.cfg_bool("cold_start_skip_history", true) and (not is_seeded)

    local replay_mode = batch.is_manual and (batch.replay_hours or 0) > 0
    local needed_for_extract = batch.needed_products
    local include_all = batch.is_manual
    if replay_mode and batch.manual_target_gid then
        for _, sub in ipairs(batch.subs) do
            if sub.group_id == batch.manual_target_gid then
                needed_for_extract = sub.products
                include_all = false
                break
            end
        end
    end

    local candidates = sources.extract_candidates(src, body, needed_for_extract, include_all)
    batch.candidate_count = batch.candidate_count + #candidates

    -- 记录各产品最新快照，供 manual_trigger 汇总展示
    for _, c in ipairs(candidates) do
        if c.product then
            local cur = batch.latest_by_prod[c.product]
            if not cur or (c.announced_ts or 0) >= (cur.announced_ts or 0) then
                batch.latest_by_prod[c.product] = c
            end
        end
    end

    if batch.is_manual and not replay_mode then
        return
    end

    if not batch.is_manual and not is_seeded then
        batch.seed_marks[#batch.seed_marks + 1] = seed_key
    end

    local replay_cutoff = replay_mode and (os.time() - batch.replay_hours * 3600) or 0

    for _, cand in ipairs(candidates) do
        local slot_key = nil
        -- 分钟级产品+时间戳签名，用于跨源去重（fxtwitter vs agyresets vs whenaireset）
        if cand.product and (cand.announced_ts or 0) > 0
            and cand.event_kind ~= "status_incident" and cand.event_kind ~= "status_resolved" then
            slot_key = cand.product .. ":" .. tostring(math.floor(cand.announced_ts / 60))
        end

        local dup_in_batch = batch.seen_in_batch[cand.event_key]
            or (slot_key and batch.seen_slots[slot_key])

        if not dup_in_batch then
            batch.seen_in_batch[cand.event_key] = true
            if slot_key then batch.seen_slots[slot_key] = true end

            if replay_mode then
                if (cand.announced_ts or 0) >= replay_cutoff then
                    local f_proxy = common.cfg_string("foreign_proxy", "")
                    if cand.needs_x_lookup and cand.x_status_id then
                        batch.pending_http = batch.pending_http + 1
                        local api_u = "https://api.fxtwitter.com/status/" .. tostring(cand.x_status_id)
                        jn.http.get_async(api_u, {
                            proxy = f_proxy,
                            headers = { ["User-Agent"] = common.UA },
                            ctx = { batch_id = batch.id, stage = "verify_x", cand = cand },
                        })
                    else
                        submit_candidate_to_llm(batch, cand)
                    end
                end
            elseif skip_cold then
                -- 冷启动首轮：写入基线标记，防止旧帖子全部在群里刷屏
                batch.baseline_marks[#batch.baseline_marks + 1] = cand
            elseif not store.has_seen(cand.event_key) then
                local f_proxy = common.cfg_string("foreign_proxy", "")
                if cand.needs_x_lookup and cand.x_status_id then
                    batch.pending_http = batch.pending_http + 1
                    local api_u = "https://api.fxtwitter.com/status/" .. tostring(cand.x_status_id)
                    jn.http.get_async(api_u, {
                        proxy = f_proxy,
                        headers = { ["User-Agent"] = common.UA },
                        ctx = { batch_id = batch.id, stage = "verify_x", cand = cand },
                    })
                else
                    submit_candidate_to_llm(batch, cand)
                end
            end
        end
    end
end

-- --------------------------------------------------------------------
-- 发起一轮轮询
-- --------------------------------------------------------------------
local function start_poll(is_manual)
    if not common.cfg_bool("enabled", true) then return end
    if state.running then
        if os.time() - state.started_at > 240 then
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 上一轮轮询超时，重置状态锁")
            state.running = false
        else
            return
        end
    end

    local subs = common.parse_subscriptions()
    if not is_manual and #subs == 0 then
        -- 没配任何订阅群时，不浪费网络与 Token
        return
    end

    local replay_hours = is_manual and math.max(0, common.cfg_num("manual_replay_hours", 0)) or 0
    local manual_gid = tonumber(common.cfg_string("test_group", ""))
    if (not manual_gid or manual_gid <= 0) and #subs > 0 then
        manual_gid = subs[1].group_id
    end

    local needed = common.subscribed_products_union(subs)
    local fetch_all = (is_manual and replay_hours == 0)
    if is_manual and replay_hours > 0 then
        local found_sub = false
        for _, s in ipairs(subs) do
            if s.group_id == manual_gid then
                needed = s.products
                found_sub = true
                break
            end
        end
        if not found_sub then fetch_all = true end
    end

    local src_list = sources.build_source_list(needed, fetch_all)
    if #src_list == 0 then
        if is_manual then
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 手动诊断未找到启用的信源")
        end
        return
    end

    store.init()

    local default_style = common.norm_style(common.cfg_string("summary_style", "both"), "both")
    local need_persona = (default_style ~= "objective")
    for _, s in ipairs(subs) do
        if s.style and s.style ~= "objective" then
            need_persona = true
            break
        end
    end

    local bid = state.next_batch_id
    state.next_batch_id = bid + 1
    state.used_fallback_provider = false
    local batch = {
        id = bid,
        is_manual = is_manual == true,
        replay_hours = replay_hours,
        manual_target_gid = manual_gid,
        replayed_count = 0,
        subs = subs,
        needed_products = needed,
        need_persona = need_persona,
        pending_http = 0,
        pending_llm = 0,
        total_sources = #src_list,
        ok_sources = 0,
        fail_sources = 0,
        errors = {},
        candidate_count = 0,
        llm_count = 0,
        seen_in_batch = {},
        seen_slots = {},
        baseline_marks = {},
        seed_marks = {},
        latest_by_prod = {},
        finished = false,
    }
    state.batches[bid] = batch
    state.running = true
    state.started_at = os.time()
    if not is_manual then
        state.last_poll_ts = os.time()
    end

    for _, src in ipairs(src_list) do
        batch.pending_http = batch.pending_http + 1
        jn.http.get_async(src.url, {
            proxy = src.proxy or "",
            headers = {
                ["User-Agent"] = common.UA,
                ["Accept"] = "application/rss+xml, application/atom+xml, application/xml, application/json, text/html;q=0.9, */*;q=0.8",
            },
            ctx = { batch_id = bid, stage = "feed", src = src, fb_idx = 0 },
        })
    end
end

-- --------------------------------------------------------------------
-- 异步 HTTP 回调
-- --------------------------------------------------------------------
function on_http_response(req_id, ctx, result, err)
    if type(ctx) ~= "table" then return end
    local batch = state.batches[ctx.batch_id]
    if not batch or batch.finished then return end

    batch.pending_http = math.max(0, batch.pending_http - 1)
    local status = (type(result) == "table" and tonumber(result.status)) or 0
    local body = (type(result) == "table" and type(result.body) == "string") and result.body or ""
    local ok_resp = (not err) and (status >= 200 and status < 300) and (body ~= "")

    if ctx.stage == "feed" then
        local src = ctx.src
        if ok_resp then
            batch.ok_sources = batch.ok_sources + 1
            local ok_proc, perr = pcall(process_source_candidates, batch, src, body)
            if not ok_proc then
                jn.log.warn(string.format("[%s] 解析源 %s 异常: %s",
                    common.PLUGIN_NAME, src.name, tostring(perr)))
            end
        else
            local fb_idx = (ctx.fb_idx or 0) + 1
            if src.fallback_urls and src.fallback_urls[fb_idx] then
                local fb = src.fallback_urls[fb_idx]
                local next_src = {
                    id = src.id,
                    kind = fb.kind,
                    product = src.product,
                    name = src.name .. " -> Fallback#" .. tostring(fb_idx),
                    url = fb.url,
                    fallback_urls = src.fallback_urls,
                    proxy = fb.proxy or "",
                }
                batch.pending_http = batch.pending_http + 1
                jn.log.info(string.format("[%s] %s 请求失败(%s)，切换备用源: %s",
                    common.PLUGIN_NAME, src.url, tostring(err or ("HTTP " .. status)), fb.url))
                jn.http.get_async(next_src.url, {
                    proxy = next_src.proxy,
                    headers = { ["User-Agent"] = common.UA },
                    ctx = { batch_id = batch.id, stage = "feed", src = next_src, fb_idx = fb_idx },
                })
            else
                batch.fail_sources = batch.fail_sources + 1
                local emsg = string.format("%s(%s)", src.name, tostring(err or ("HTTP " .. status)))
                batch.errors[#batch.errors + 1] = emsg
                jn.log.warn("[" .. common.PLUGIN_NAME .. "] 抓取失败: " .. emsg)
            end
        end
    elseif ctx.stage == "verify_x" then
        local cand = ctx.cand
        if ok_resp then
            local ok, parsed = pcall(jn.json.decode, body)
            if ok and type(parsed) == "table" and type(parsed.tweet) == "table" then
                local tw = parsed.tweet
                local author = type(tw.author) == "table" and tw.author or {}
                local screen = tostring(author.screen_name or "")
                local text = common.trim(tw.text or "")
                if text ~= "" then
                    cand.raw_text = text
                    if screen ~= "" then
                        cand.source_name = "@" .. screen .. " (X 官方原帖)"
                    end
                    if tw.url and tw.url ~= "" then
                        cand.source_url = tw.url
                    end
                    if screen:lower() == "bot" then
                        cand.product = "grok_bot"
                    end
                end
            end
        end
        submit_candidate_to_llm(batch, cand)
    end

    finish_batch_if_ready(batch)
end

-- --------------------------------------------------------------------
-- 异步 LLM 回调
-- --------------------------------------------------------------------
function on_chat_response(req_id, content, err)
    local job = state.llm_pending[req_id]
    state.llm_pending[req_id] = nil
    if not job then return end

    state.llm_inflight = false
    state.llm_last_ts = os.time()

    local batch = job.batch
    local cand = job.cand
    if not batch or batch.finished then
        schedule_llm_pump(0.2)
        return
    end

    if err and is_transient_llm_err(err) and (job.attempt or 0) < 2 then
        jn.log.warn(string.format("[%s] LLM 暂态异常(第%d次): %s",
            common.PLUGIN_NAME, (job.attempt or 0) + 1, tostring(err)))
        local fb_id = common.cfg_string("fallback_provider_id", "")
        if fb_id ~= "" then
            if switch_temp_provider(fb_id, "主模型暂态异常自动切换") then
                state.used_fallback_provider = true
            end
        end
        job.attempt = (job.attempt or 0) + 1
        table.insert(state.llm_queue, 1, job)
        schedule_llm_pump(2.0, true)
        return
    end

    batch.pending_llm = math.max(0, batch.pending_llm - 1)

    local parsed = nil
    if not err and type(content) == "string" and content ~= "" then
        parsed = llm_mod.parse_llm_result(content, cand)
    elseif err then
        jn.log.warn("[" .. common.PLUGIN_NAME .. "] LLM 回调异常: " .. tostring(err))
    end

    if parsed then
        local min_conf = common.cfg_num("llm_confidence_min", 0.6)
        if parsed.is_relevant and parsed.confidence >= min_conf and parsed.product then
            cand.product = parsed.product
            cand.event_kind = parsed.event_kind
            cand.is_major = parsed.is_major
            cand.title = parsed.title
            cand.scope = parsed.scope
            cand.objective_summary = parsed.objective_summary
            cand.persona_comment = parsed.persona_comment
            dispatch_event_to_groups(batch, cand)
        else
            if not batch.is_manual then
                cand.event_kind = "unrelated"
                store.mark_seen(cand, false)
            end
        end
    else
        finalize_llm_fallback(batch, cand)
    end

    finish_batch_if_ready(batch)
    if #state.llm_queue > 0 then
        schedule_llm_pump(common.cfg_num("llm_min_interval", 1.5), true)
    else
        restore_provider_if_needed()
    end
end

-- --------------------------------------------------------------------
-- 定时心跳（30s 检查一次 manual_trigger、静默结束补发、轮询间隔）
-- --------------------------------------------------------------------
local function tick()
    local interval_min = common.cfg_num("poll_interval_minutes", 60)
    local now = os.time()

    -- 1. 手动触发测试开关
    if not common.cfg_bool("manual_trigger", false) then
        state.manual_done = false
    elseif not state.manual_done and common.cfg_bool("enabled", true) then
        state.manual_done = true
        jn.log.info("[" .. common.PLUGIN_NAME .. "] 检测到 manual_trigger 开启，执行诊断抓取...")
        start_poll(true)
    end

    -- 2. 静默时段刚结束时自动冲刷队列
    local quiet_now = common.is_in_quiet_hours()
    if state.was_quiet and not quiet_now then
        flush_pending_queues()
    end
    state.was_quiet = quiet_now

    -- 3. 定时轮询（分钟间隔 >= 1 时生效；0 表示关闭自动轮询）
    if common.cfg_bool("enabled", true) and interval_min >= 1 then
        if state.last_poll_ts == 0 or (now - state.last_poll_ts >= interval_min * 60) then
            start_poll(false)
        end
    end

    if jn.timer and jn.timer.after then
        jn.timer.after(30, { action = "tick" })
    end
end

function on_timer_response(req_id, ctx, result, err)
    if err then
        jn.log.warn("[" .. common.PLUGIN_NAME .. "] 定时器回调异常: " .. tostring(err))
        return
    end
    if type(ctx) ~= "table" then return end
    if ctx.action == "tick" then
        tick()
    elseif ctx.action == "llm_pump" then
        state.llm_pump_scheduled = false
        pump_llm_queue(ctx.waited == true)
    elseif ctx.action == "send_pump" then
        pump_send_queue()
    end
end

-- 可选支持通过 Bot 后台 CronJob 手动/定时触发增量检测
function on_cronjob(event)
    jn.log.info("[" .. common.PLUGIN_NAME .. "] 收到 CronJob 触发，执行一轮 AI 重置与状态检测...")
    start_poll(false)
end

-- --------------------------------------------------------------------
-- 启动入口
-- --------------------------------------------------------------------
jn.log.info("[" .. common.PLUGIN_NAME .. "] AI 重置与服务状态监控插件已加载")
if jn.timer and jn.timer.after then
    jn.timer.after(10, { action = "tick" })
end
