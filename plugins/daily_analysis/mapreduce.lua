-- mapreduce.lua — Map-Reduce 分段提炼与多级递归敏感审查拆片挽救

return function(jn, common, prompts)
    local M = {}

    local PLUGIN_NAME = common.PLUGIN_NAME

    local MODERATION_HINTS = {
        "敏感内容", "敏感信息", "敏感词", "安全审核", "内容安全", "违规内容",
        "无法响应您的请求", "content_filter", "data_inspection_failed", "sensitive",
        "inappropriate", "high_risk", "safety policy",
    }

    function M.is_moderation_rejection(resp, err)
        local combined = (tostring(resp or "") .. " " .. tostring(err or "")):lower()
        for _, pat in ipairs(MODERATION_HINTS) do
            if combined:find(pat, 1, true) then return true end
        end
        return false
    end

    local function partition_stream_chunks(stream_messages, chunk_chars, max_chunks)
        max_chunks = max_chunks or 8
        local total = 0
        for idx, msg in ipairs(stream_messages) do
            local line = common.format_chat_stream({ msg }, idx)
            total = total + #line + 1
        end
        local budget = math.max(8000, chunk_chars)
        if total > budget * max_chunks then
            budget = math.ceil(total / max_chunks)
        end
        local chunks, cur_msgs, cur_start, cur_size = {}, {}, 1, 0
        for idx, msg in ipairs(stream_messages) do
            local line_len = #common.format_chat_stream({ msg }, idx) + 1
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

    local function merge_map_subresults(a, b)
        if not a then return b end
        if not b then return a end
        local out = { media_summaries = {}, topics = {}, golden_quotes = {}, highlights = {} }
        for _, src in ipairs({ a, b }) do
            for _, m in ipairs(src.media_summaries or {}) do out.media_summaries[#out.media_summaries + 1] = m end
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
        local actual_parts = math.max(1, math.min(parts_count, n))
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

    local function read_resplit_config()
        local max_depth = math.max(0, math.min(3, math.floor(common.da_num("map_resplit_max_depth", 2))))
        local l1 = math.max(0, math.min(32, math.floor(common.da_num("map_resplit_count", 8))))
        local l2 = math.max(2, math.min(16, math.floor(common.da_num("map_resplit_l2_count", 4))))
        local l3 = math.max(2, math.min(8, math.floor(common.da_num("map_resplit_l3_count", 2))))
        return {
            max_depth = max_depth,
            counts = { [0] = l1, [1] = l2, [2] = l3 },
        }
    end

    local function split_factor_for_depth(resplit_cfg, depth)
        return resplit_cfg.counts[depth] or 2
    end

    local function run_map_slice_resplit(group_id, msgs, start_idx, label, total_parts, persona_prompt, llm_timeout, depth, budget, resplit_cfg, section_caps, on_slice_done)
        local c_stream = common.format_chat_stream(msgs, start_idx)
        local mprompt = prompts.build_map_prompt(c_stream, label, total_parts, persona_prompt, section_caps)
        local io_chars = #mprompt

        common.llm_chat_async({
            { role = "system", content = persona_prompt },
            { role = "user", content = mprompt },
        }, { timeout = llm_timeout }, function(resp, err)
            if not err and resp and resp ~= "" then
                io_chars = io_chars + #resp
                local obj, perr = common.decode_llm_json(resp, tostring(label))
                if obj then
                    on_slice_done(obj, nil, io_chars, 0)
                    return
                end
                err = perr or "JSON 解析失败"
            end

            local split_n = split_factor_for_depth(resplit_cfg, depth)
            local can_resplit = M.is_moderation_rejection(resp, err)
                and resplit_cfg.counts[0] >= 2
                and depth < resplit_cfg.max_depth
                and split_n >= 2
                and #msgs >= 2
                and budget.remaining > 0

            if can_resplit then
                budget.remaining = budget.remaining - 1
                local sub_slices = split_messages_evenly(msgs, start_idx, split_n)
                if #sub_slices >= 2 then
                    jn.log.warn(string.format("[%s] 群 %d Map-%s (级=%d, %d 条) 命中敏感审查，拆分为 %d 片挽救...",
                        PLUGIN_NAME, group_id, tostring(label), depth + 1, #msgs, #sub_slices))
                    run_with_concurrency(sub_slices, 2, function(k, sub, cb)
                        local sub_label = string.format("%s.%d", tostring(label), k)
                        run_map_slice_resplit(group_id, sub.msgs, sub.start_idx, sub_label, total_parts, persona_prompt, llm_timeout, depth + 1, budget, resplit_cfg, section_caps, function(s_obj, s_err, s_chars, s_dropped)
                            cb({ data = s_obj, err = s_err, chars = s_chars or 0, dropped = s_dropped or 0 })
                        end)
                    end, function(sub_results)
                        local merged, last_err, sub_chars, dropped_msgs = nil, nil, io_chars, 0
                        for _, sr in ipairs(sub_results) do
                            sub_chars = sub_chars + (sr.chars or 0)
                            dropped_msgs = dropped_msgs + (sr.dropped or 0)
                            if sr.data then
                                merged = merge_map_subresults(merged, sr.data)
                            elseif sr.err then
                                last_err = sr.err
                            end
                        end
                        local final_err = merged and nil or tostring(last_err or "各级拆片均未成功")
                        on_slice_done(merged, final_err, sub_chars, dropped_msgs)
                    end)
                    return
                end
            end

            local dropped_here = M.is_moderation_rejection(resp, err) and #msgs or 0
            if dropped_here > 0 then
                jn.log.warn(string.format("[%s] 群 %d Map-%s (级=%d) 到达最小粒度仍命中敏感审查，精准丢弃 %d 条消息 (#%d~#%d)",
                    PLUGIN_NAME, group_id, tostring(label), depth, dropped_here, start_idx, start_idx + #msgs - 1))
            else
                jn.log.warn(string.format("[%s] 群 %d Map-%s 失败: %s",
                    PLUGIN_NAME, group_id, tostring(label), tostring(err or "空响应")))
            end
            on_slice_done(nil, tostring(err or "空响应"), io_chars, dropped_here)
        end)
    end

    local function run_map_reduce_async(group_id, stream_messages, stats, persona_prompt, section_caps, llm_timeout, chunk_chars, model_desc, touch_watchdog, on_done, forced_chunks, initial_depth)
        local function touch(extra_sec)
            if type(touch_watchdog) == "function" then
                pcall(touch_watchdog, extra_sec)
            end
        end
        local chunks = forced_chunks or partition_stream_chunks(stream_messages, chunk_chars, 8)
        if #chunks <= 1 then
            touch(llm_timeout + 240)
            local stream_txt = common.format_chat_stream(stream_messages)
            local prompt = prompts.build_analysis_prompt(stream_txt, stats, persona_prompt, section_caps)
            jn.log.info(string.format("[%s] 开始调用 LLM 分析群 %d 消息 (字符数: %d, 超时: %ds, 模型: %s)...",
                PLUGIN_NAME, group_id, #prompt, llm_timeout, model_desc))
            common.llm_chat_async({
                { role = "system", content = persona_prompt },
                { role = "user", content = prompt },
            }, { timeout = llm_timeout }, function(resp, err)
                if err or not resp or resp == "" then
                    on_done(nil, tostring(err or "空响应"), math.floor(#prompt / 2))
                    return
                end
                local obj, perr = common.decode_llm_json(resp, "LLM")
                if not obj then
                    local tag_err = M.is_moderation_rejection(resp, nil)
                        and ("moderation_rejected: " .. common.clip(resp, 80))
                        or (perr or "JSON 解析失败")
                    on_done(nil, tag_err, math.floor((#prompt + #resp) / 2))
                    return
                end
                on_done(obj, nil, math.floor((#prompt + #resp) / 2))
            end)
            return
        end

        local resplit_cfg = read_resplit_config()
        local waves = math.ceil(#chunks / 2)
        -- 按并发轮数 + Reduce + 串行金句终筛动态核定初始看门狗预算，并在分片完成与阶段切换时继续顺延
        local mr_budget = waves * llm_timeout + llm_timeout * 2 + 240
        touch(mr_budget)
        jn.log.info(string.format("[%s] 群 %d %s，启动 Map-Reduce 分段分析（%d 段，并发 2，最大拆片级=%d，模型: %s）...",
            PLUGIN_NAME, group_id, forced_chunks and "二次拆片挽救" or "语料超阈值", #chunks, resplit_cfg.max_depth, model_desc))
        local resplit_budget = { remaining = math.max(24, #chunks * 12) }
        local start_depth = initial_depth or 0

        local function collect_quote_candidates(results)
            local list, seen = {}, {}
            for k, r in ipairs(results) do
                if r.data and type(r.data.golden_quotes) == "table" then
                    for _, q in ipairs(r.data.golden_quotes) do
                        if type(q) == "table" then
                            local content = common.clean_quote_text(q.content)
                            local dedup = content:gsub("%s+", "")
                            if #content >= 4 and not seen[dedup] then
                                seen[dedup] = true
                                list[#list + 1] = {
                                    part = k,
                                    msg_id = q.msg_id,
                                    msg_ids = (type(q.msg_ids) == "table" and #q.msg_ids > 0) and q.msg_ids or nil,
                                    sender = tostring(q.sender or "群友"),
                                    content = content,
                                    reason = tostring(q.reason or ""),
                                }
                            end
                        end
                    end
                end
            end
            return list
        end

        local function curate_quotes_serial(obj, candidates, ok_parts, io_chars)
            local quote_cap = section_caps and tonumber(section_caps.quotes)
            if quote_cap == 0 then
                obj.golden_quotes = {}
                on_done(obj, nil, math.floor(io_chars / 2))
                return
            end
            if #candidates == 0 or not prompts.build_quote_curation_prompt then
                on_done(obj, nil, math.floor(io_chars / 2))
                return
            end
            touch(llm_timeout + 240)
            local qprompt = prompts.build_quote_curation_prompt(candidates, ok_parts, persona_prompt, quote_cap or -1)
            io_chars = io_chars + #qprompt
            jn.log.info(string.format("[%s] 群 %d Reduce 完成，串行执行金句二次终筛（候选 %d 条，上限=%s）...",
                PLUGIN_NAME, group_id, #candidates, tostring(quote_cap or -1)))
            common.llm_chat_async({
                { role = "system", content = persona_prompt },
                { role = "user", content = qprompt },
            }, { timeout = llm_timeout }, function(qresp, qerr)
                if qerr or not qresp or qresp == "" then
                    jn.log.warn(string.format("[%s] 群 %d 金句二次终筛失败，回退 Reduce 结果: %s",
                        PLUGIN_NAME, group_id, tostring(qerr or "空响应")))
                    on_done(obj, nil, math.floor(io_chars / 2))
                    return
                end
                io_chars = io_chars + #qresp
                local qobj, qperr = common.decode_llm_json(qresp, "金句终筛")
                if not qobj or type(qobj.golden_quotes) ~= "table" then
                    jn.log.warn(string.format("[%s] 群 %d 金句二次终筛解析失败，回退 Reduce 结果: %s",
                        PLUGIN_NAME, group_id, tostring(qperr or "缺少 golden_quotes")))
                    on_done(obj, nil, math.floor(io_chars / 2))
                    return
                end
                local curated = {}
                for _, item in ipairs(qobj.golden_quotes) do
                    if type(item) == "table" then
                        local cid = tonumber(item.id)
                        local src_cand = cid and candidates[cid] or nil
                        local content = src_cand and src_cand.content or common.clean_quote_text(item.content)
                        if content ~= "" then
                            local rtxt = tostring(item.reason or (src_cand and src_cand.reason) or "")
                            curated[#curated + 1] = {
                                msg_id = (src_cand and src_cand.msg_id) or item.msg_id,
                                msg_ids = (src_cand and src_cand.msg_ids)
                                    or ((type(item.msg_ids) == "table" and #item.msg_ids > 0) and item.msg_ids or nil),
                                sender = (src_cand and src_cand.sender) or tostring(item.sender or "群友"),
                                content = content,
                                reason = rtxt,
                            }
                        end
                        if quote_cap and quote_cap > 0 and #curated >= quote_cap then
                            break
                        end
                    end
                end
                obj.golden_quotes = curated
                on_done(obj, nil, math.floor(io_chars / 2))
            end)
        end

        run_with_concurrency(chunks, 2, function(idx, c, cb)
            touch(llm_timeout + 240)
            run_map_slice_resplit(group_id, c.msgs, c.start_idx, idx, #chunks, persona_prompt, llm_timeout, start_depth, resplit_budget, resplit_cfg, section_caps, function(obj, err, io_c, dropped)
                touch(llm_timeout + 240)
                cb({ data = obj, err = err, io_chars = io_c or 0, dropped = dropped or 0 })
            end)
        end, function(results)
            local ok_count, total_io_chars, total_dropped = 0, 0, 0
            for _, r in ipairs(results) do
                total_io_chars = total_io_chars + (r.io_chars or 0)
                total_dropped = total_dropped + (r.dropped or 0)
                if r.data then ok_count = ok_count + 1 end
            end
            if ok_count == 0 then
                on_done(nil, results[1] and results[1].err or "全部分片分析失败", math.floor(total_io_chars / 2))
                return
            end
            touch(llm_timeout + 240)
            local reduce_prompt = prompts.build_reduce_prompt(results, stats, persona_prompt, section_caps)
            total_io_chars = total_io_chars + #reduce_prompt
            jn.log.info(string.format("[%s] 群 %d Map 完成 (%d/%d 成功，隔离丢弃敏感消息 %d 条)，执行 Reduce 终稿汇总 (字符数: %d)...",
                PLUGIN_NAME, group_id, ok_count, #chunks, total_dropped, #reduce_prompt))
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
                local candidates = collect_quote_candidates(results)
                curate_quotes_serial(obj, candidates, ok_count, total_io_chars)
            end)
        end)
    end

    function M.run_main_llm_with_fallback(group_id, stream_messages, stats, persona_prompt, section_caps, hooks, on_done)
        local llm_timeout = math.max(30, common.da_num("llm_timeout", 360))
        local map_thresh = math.max(10000, common.da_num("map_reduce_threshold", 50000))
        local chunk_chars = math.max(8000, common.da_num("map_chunk_chars", 35000))
        local target_str = common.da_string("text_provider_id", "")
        local fallback_str = common.da_string("fallback_text_provider", "")
        local touch_watchdog = hooks and hooks.touch_watchdog

        local model_desc, primary_id = hooks.acquire_provider_slot(target_str)

        local function run_with_msgs(msgs, cur_desc, allow_map, cb)
            local txt = common.format_chat_stream(msgs)
            if allow_map and #txt > map_thresh then
                run_map_reduce_async(group_id, msgs, stats, persona_prompt, section_caps, llm_timeout, chunk_chars, cur_desc, touch_watchdog, cb)
                return
            end
            if type(touch_watchdog) == "function" then
                pcall(touch_watchdog, llm_timeout + 240)
            end
            local prompt = prompts.build_analysis_prompt(txt, stats, persona_prompt, section_caps)
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
                    local tag_err = M.is_moderation_rejection(resp, nil)
                        and ("moderation_rejected: " .. common.clip(resp, 80))
                        or (perr or "JSON 解析失败")
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
            local resplit_cfg = read_resplit_config()
            local l1 = resplit_cfg.counts[0]
            if M.is_moderation_rejection(nil, err) and resplit_cfg.max_depth >= 1 and l1 >= 2 and #stream_messages >= 4 then
                local forced_chunks = split_messages_evenly(stream_messages, 1, l1)
                if #forced_chunks >= 2 then
                    jn.log.warn(string.format("[%s] 群 %d 单次请求命中敏感审查 (%d 条)，拆分为 %d 片（最多支持 %d 级隔离）...",
                        PLUGIN_NAME, group_id, #stream_messages, #forced_chunks, resplit_cfg.max_depth))
                    run_map_reduce_async(group_id, stream_messages, stats, persona_prompt, section_caps, llm_timeout, chunk_chars, model_desc, touch_watchdog, function(mdata, merr, mtokens)
                        if mdata then
                            on_done(mdata, nil, mtokens, model_desc)
                        else
                            on_done(nil, tostring(merr or err), mtokens, model_desc)
                        end
                    end, forced_chunks, 1)
                    return
                end
            end

            jn.log.warn(string.format("[%s] 群 %d 主分析失败 (%s)，启动自动降级重试...",
                PLUGIN_NAME, group_id, tostring(err)))

            if fallback_str ~= "" then
                local fb_desc, fb_id = hooks.acquire_provider_slot(fallback_str)
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

    return M
end
