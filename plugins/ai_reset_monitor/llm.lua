-- llm.lua — Bot 人格提取、LLM 语义鉴真/全中文翻译、兜底本地化与严格 450 字裁剪

return function(jn, common)
    local M = {}

    local KIND_LABELS = {
        direct_reset    = "直接全员/全套餐重置",
        banked_reset    = "发放重置卡 / 补偿券",
        scheduled_reset = "官方预告即将重置",
        rule_change     = "重大额度 / 规则变更",
        status_incident = "官方服务故障 / 性能异常",
        status_resolved = "官方服务已恢复",
    }

    function M.kind_label(kind)
        return KIND_LABELS[kind] or tostring(kind or "动态更新")
    end

    function M.active_persona()
        if not (jn.agent and jn.agent.get_prompts) then return "" end
        local ok, prompts = pcall(jn.agent.get_prompts)
        if not ok or type(prompts) ~= "table" then return "" end
        for _, p in ipairs(prompts) do
            if type(p) == "table" and p.is_active and p.type == "personality" and p.content and #p.content > 0 then
                return common.trim(p.content)
            end
        end
        for _, p in ipairs(prompts) do
            if type(p) == "table" and p.is_active and p.type == "system" and p.content and #p.content > 0 then
                return common.trim(p.content)
            end
        end
        return ""
    end

    -- 在 jn.agent.get_providers() 中按名称 / 模型 / ID 模糊匹配 text_model
    function M.match_text_provider(query)
        local q = common.trim(query):lower()
        if q == "" or not (jn.agent and jn.agent.get_providers) then return nil end
        local ok, providers = pcall(jn.agent.get_providers)
        if not ok or type(providers) ~= "table" then return nil end
        local current_active = nil
        local matched = nil
        for _, p in ipairs(providers) do
            if type(p) == "table" then
                local pt = tostring(p.Type or p.type or "")
                local act = (p.IsActive == true) or (p.is_active == true) or (p.active == true)
                local pid = tostring(p.ID or p.id or "")
                local pname = tostring(p.Name or p.name or ""):lower()
                local pmodel = tostring(p.Model or p.model or ""):lower()
                if pt == "text_model" then
                    if act then current_active = p end
                    if not matched and (pid:lower() == q or pname == q or pmodel == q
                        or pname:find(q, 1, true) or pmodel:find(q, 1, true)) then
                        matched = p
                    end
                end
            end
        end
        return matched, current_active
    end

    function M.build_messages(cand, need_persona_text)
        local cand_prod = tostring(cand.product or "")
        local cand_kind = tostring(cand.event_kind or "")
        local prod_hint = cand_prod ~= "" and cand_prod or "auto"
        local kind_hint = cand_kind ~= "" and cand_kind or "auto"
        local persona = need_persona_text and M.active_persona() or ""
        local lookback_min = math.max(5, common.cfg_num("lookback_minutes", 60))
        local is_status = (cand_kind == "status_incident" or cand_kind == "status_resolved")
        local auto_len = common.cfg_bool("allow_llm_auto_summary_len", true)
        local status_cap = common.cfg_num("status_max_msg_chars", 0)

        local len_rule
        if is_status and auto_len then
            local cap_hint = status_cap > 0 and string.format("总推送控制在 %d 字以内", status_cap) or "总字数可按故障过程详略自行把握"
            len_rule = string.format(
                "6. 字数与过程完整度：title ≤ 28 字；scope ≤ 24 字；objective_summary 必须按时间顺序完整汇报过去 %d 分钟（及当前故障）内的全部状态变更时间线（例如 `09:10 已定位原因，正在实施修复 → 09:20 问题已解决，服务恢复`），严禁只写最后恢复结论而丢掉前面定位/排查过程；摘要字数由你自行判断（简单事件简短，多阶段故障可详细列出每个时间节点），%s；persona_comment ≤ 90 字。",
                lookback_min, cap_hint
            )
        else
            len_rule = "6. 字数精简：title ≤ 28 字；scope ≤ 24 字；objective_summary 控制在 60~180 字（清晰交代原因、受影响对象与最新阶段进展；若时间线/近期上下文含多个状态变化须完整列出）；persona_comment ≤ 90 字，确保整条最终消息不超过 450 字。"
        end

        local sys_parts = {
            "你是 AI 额度重置与官方服务状态监控审核员。请对输入的官方帖子或状态更新做严格鉴真、全中文翻译与双风格摘要，只输出合法 JSON 对象，禁止 Markdown 代码块或任何多余文字。",
            "",
            "【产品键集合】",
            "codex, antigravity, claude, grok, grok_bot, glm, qoder, kimi, gemini_cli, cursor, openai_status, claude_status, deepseek_status",
            "",
            "【事件类型 event_kind 判定】",
            "- direct_reset: 官方确认已直接重置额度/清零用量（非单纯口头玩笑）",
            "- banked_reset: 官方发放了重置卡 / 免费重置次数 / 补偿额度券（如 banked reset / reset card）",
            "- scheduled_reset: 官方明确预告即将重置额度或给出具体生效时间",
            "- rule_change: 明确的每日/每周免费额度翻倍、限额大幅上调、或新模型/周年明确加赠重置规则变动",
            "- status_incident: 官方状态页通报服务异常/降级/宕机（Investigating / Identified / Monitoring 等未恢复阶段）",
            "- status_resolved: 官方状态页通报服务已恢复（Resolved）",
            "- unrelated: 日常聊天、玩梗吐槽、普通产品宣传/无关功能发布、提问求助而非官方重置/故障公告",
            "",
            "【铁律（必须严格遵守）】",
            "1. 【全中文翻译】title、scope、objective_summary、persona_comment 必须全部使用流畅准确的简体中文！除必需专有名词（如 Codex、Claude、Antigravity、GPT-6、Gemini、Microsoft 365、Pro/Max/Ultra/Team、API）外，绝对禁止整句或整段照抄英文原文。",
            "2. 严格区分玩笑/反讽与真实生效动作；不确定或明显闲聊时设 is_relevant=false, event_kind='unrelated'。",
            "3. 只能依据给定原文与回源时间线客观翻译与总结，禁止编造具体倍数、时间点、套餐范围或故障原因。",
            "4. 若当前已识别来源为 grok，但原文明确提到 'Grok Bot' 或发自 @bot，请将 product 设为 grok_bot。",
            "5. is_major 仅在「全员或全付费用户直接重置 (direct_reset)」「发放重置卡 (banked_reset)」或「影响核心对话/API 的重大宕机 (Major Outage)」时为 true；预告、规则变动、轻度局部异常、已恢复设为 false。",
            "6. 【强制使用 UTC+8 北京时间】原文若包含 UTC / GMT / PST / EST 等非东八区时刻，在 title、objective_summary、persona_comment 中提及具体时间点时必须换算为北京时间（UTC+8，如 01:10 UTC → 09:10），严禁直接照抄未换算的 UTC 原文时间；请优先采用下方已换算为 UTC+8 的时间线。",
            len_rule,
        }

        if persona ~= "" then
            sys_parts[#sys_parts + 1] = "7. persona_comment 用下方【Bot 人格设定】的第一人称口吻写 1~2 句中文提示/吐槽（提醒大家回满血继续用额度，或调侃服务异常，不得编造事实）。"
            sys_parts[#sys_parts + 1] = ""
            sys_parts[#sys_parts + 1] = "【Bot 人格设定】\n" .. common.clip(persona, 1000)
        else
            sys_parts[#sys_parts + 1] = "7. persona_comment 用轻快幽默的中文口吻写 1 句提示。"
        end

        sys_parts[#sys_parts + 1] = ""
        sys_parts[#sys_parts + 1] = [[输出 JSON 格式：{"is_relevant":true,"confidence":0.95,"product":"","event_kind":"","is_major":true,"title":"","scope":"","objective_summary":"","persona_comment":""}]]

        local raw_clean = common.convert_utc_text_to_cst(common.strip_wm(cand.raw_text or cand.title or ""))
        local parts = {
            "来源: " .. tostring(cand.source_name or ""),
            "预设产品键提示: " .. prod_hint,
            "预设类型提示: " .. kind_hint,
            "溯源时间窗: 最近 " .. tostring(lookback_min) .. " 分钟",
            "时间(北京时间): " .. common.format_cst(cand.announced_ts or 0),
            "链接: " .. tostring(cand.source_url or ""),
        }
        if cand.timeline_text and cand.timeline_text ~= "" then
            parts[#parts + 1] = "详情页回源状态时间线（已换算为 UTC+8 北京时间，按时间正序）:\n" .. common.clip(common.convert_utc_text_to_cst(common.strip_wm(cand.timeline_text)), 2400)
        end
        if cand.lookback_context and cand.lookback_context ~= "" then
            parts[#parts + 1] = string.format("最近 %d 分钟同产品已有记录:\n%s", lookback_min, common.clip(common.convert_utc_text_to_cst(common.strip_wm(cand.lookback_context)), 1200))
        end
        parts[#parts + 1] = "原文（其中的 UTC/GMT 时间已预换算为 UTC+8 北京时间）:\n" .. common.clip(raw_clean, 2800)

        return {
            { role = "system", content = table.concat(sys_parts, "\n") },
            { role = "user", content = table.concat(parts, "\n") },
        }
    end

    function M.parse_llm_result(raw_content, cand)
        local d = common.decode_json_loose(raw_content)
        if type(d) ~= "table" then return nil end

        local valid_kinds = {
            direct_reset = true, banked_reset = true, scheduled_reset = true,
            rule_change = true, status_incident = true, status_resolved = true,
            unrelated = true,
        }
        local kind = common.trim(d.event_kind or ""):lower()
        if not valid_kinds[kind] then
            kind = cand.event_kind or "unrelated"
        end

        local prod = common.norm_product(d.product or "") or cand.product
        if cand.product and cand.product ~= "" then
            if cand.product == "grok" and prod == "grok_bot" then
                prod = "grok_bot"
            else
                prod = cand.product
            end
        end

        local is_rel = (d.is_relevant == true) and (kind ~= "unrelated") and (prod ~= nil)
        local conf = tonumber(d.confidence) or (is_rel and 0.8 or 0.0)

        local is_major = d.is_major == true
        if kind == "scheduled_reset" or kind == "rule_change" or kind == "status_resolved" then
            is_major = false
        end

        local is_status = (kind == "status_incident" or kind == "status_resolved")
        local auto_len = is_status and common.cfg_bool("allow_llm_auto_summary_len", true)
        local summary_cap = auto_len and 1800 or 260

        return {
            is_relevant = is_rel,
            confidence = conf,
            product = prod,
            event_kind = kind,
            is_major = is_major,
            title = common.clip(common.convert_utc_text_to_cst(common.trim(d.title or cand.title or "")), 60),
            scope = common.clip(common.convert_utc_text_to_cst(common.trim(d.scope or "")), 50),
            objective_summary = common.clip(common.convert_utc_text_to_cst(common.trim(d.objective_summary or "")), summary_cap),
            persona_comment = common.clip(common.convert_utc_text_to_cst(common.trim(d.persona_comment or "")), 120),
        }
    end

    local function ascii_ratio(s)
        if not s or #s == 0 then return 0 end
        local letters = 0
        for _ in s:gmatch("[A-Za-z]") do letters = letters + 1 end
        return letters / #s
    end

    -- 仅当所有 LLM 与备选模型均不可用时触发：返回纯中文结构化提示，避免整段英文直接进群
    function M.deterministic_fallback(cand)
        local kind = cand.event_kind or "direct_reset"
        local prod = cand.product
        local prod_label = common.PRODUCT_LABELS[prod] or tostring(prod or "AI 服务")
        local is_major = cand.is_major == true
        local raw = common.trim(cand.raw_text or cand.title or "")
        local low = raw:lower()

        local title = common.trim(cand.title or "")
        local scope = "详见官方原链"
        local summary = raw

        if kind == "status_incident" or kind == "status_resolved" then
            local stage_cn = "官方进展更新"
            if kind == "status_resolved" then
                stage_cn = "服务已恢复正常"
            elseif low:find("monitoring", 1, true) then
                stage_cn = "修复已部署，正在监控观察"
            elseif low:find("identified", 1, true) then
                stage_cn = "已定位故障原因，正在修复"
            elseif low:find("investigating", 1, true) then
                stage_cn = "正在紧急排查故障"
            end
            scope = "受影响组件请以官方状态页为准"
            if ascii_ratio(title) > 0.35 then
                title = prod_label .. "：" .. stage_cn
            end
            if ascii_ratio(summary) > 0.35 then
                summary = string.format("%s当前阶段：%s（LLM 翻译暂时不可用，请点击原链查看官方英文详情）。", prod_label, stage_cn)
            end
        else
            if ascii_ratio(title) > 0.35 then
                title = prod_label .. " · " .. M.kind_label(kind)
            end
            if ascii_ratio(summary) > 0.35 then
                summary = string.format("检测到 %s 官方发布%s公告（LLM 翻译暂时不可用，请点击原链核对英文全文）。", prod_label, M.kind_label(kind))
            end
        end

        return {
            is_relevant = (cand.preverified_structured == true) and (prod ~= nil),
            confidence = cand.preverified_structured and 0.9 or 0.0,
            product = prod,
            event_kind = kind,
            is_major = is_major,
            title = common.clip(common.convert_utc_text_to_cst(title), 60),
            scope = scope,
            objective_summary = common.clip(common.convert_utc_text_to_cst(summary), 200),
            persona_comment = is_major and "额度/状态有重要更新，快点开看看是不是回满血啦~" or "",
        }
    end

    -- 按配置控制可见字数（状态过程默认放宽），最后再将零宽水印附加到首行末尾（不占可见字数预算）
    function M.format_alert(ev, style)
        style = common.norm_style(style, "both")
        local effective = style
        if style == "major_persona" then
            effective = (ev.is_major == true) and "both" or "objective"
        end

        local is_status = (ev.event_kind == "status_incident" or ev.event_kind == "status_resolved")
        local max_total = math.max(120, common.cfg_num("max_msg_chars", 450))
        if is_status then
            local status_cap = common.cfg_num("status_max_msg_chars", 0)
            if status_cap > 0 then
                max_total = math.max(200, status_cap)
            else
                max_total = 2400
            end
        end

        local prod_label = common.PRODUCT_LABELS[ev.product] or tostring(ev.product or "AI 服务")
        local kind_label = M.kind_label(ev.event_kind)
        local icon = "🔔"
        if ev.event_kind == "status_incident" then icon = "🚨"
        elseif ev.event_kind == "status_resolved" then icon = "✅"
        elseif ev.event_kind == "banked_reset" then icon = "🎟️"
        elseif ev.event_kind == "direct_reset" then icon = "🎉"
        elseif ev.event_kind == "scheduled_reset" then icon = "⏳"
        end

        local time_str = (ev.announced_ts and ev.announced_ts > 0)
            and common.format_cst(ev.announced_ts)
            or common.format_cst(os.time())

        if effective == "persona" then
            local tail = {}
            tail[#tail + 1] = "🕒 时间：" .. time_str
            if ev.source_url and ev.source_url ~= "" then
                tail[#tail + 1] = "🔗 原链：" .. ev.source_url
            end
            local header = string.format("%s [%s · %s]", icon, prod_label, kind_label)
            local tail_str = table.concat(tail, "\n")
            local overhead = common.utf8_len(header) + common.utf8_len(tail_str) + 2
            local body_budget = math.max(40, max_total - overhead)
            local body = common.trim(ev.persona_comment or "")
            if body == "" then
                body = common.trim(ev.objective_summary or ev.title or "")
            end
            body = common.clip(body, body_budget)
            return header .. common.WATERMARK .. "\n" .. body .. "\n" .. tail_str
        end

        -- objective 或 both
        local first_line = string.format("%s 【%s】%s", icon, prod_label, kind_label)
        local head_lines = { first_line }
        if ev.title and ev.title ~= "" then
            head_lines[#head_lines + 1] = "📌 摘要：" .. common.clip(ev.title, 60)
        end
        if ev.scope and ev.scope ~= "" then
            head_lines[#head_lines + 1] = "🎯 范围：" .. common.clip(ev.scope, 50)
        end

        local tail_lines = {
            "🕒 时间：" .. time_str,
        }
        if ev.source_name and ev.source_name ~= "" then
            tail_lines[#tail_lines + 1] = "📡 信源：" .. common.clip(ev.source_name, 40)
        end
        if ev.source_url and ev.source_url ~= "" then
            tail_lines[#tail_lines + 1] = "🔗 原链：" .. ev.source_url
        end

        local persona_block = ""
        if effective == "both" then
            local p = common.trim(ev.persona_comment or "")
            if p ~= "" then
                persona_block = "\n\n💬 " .. common.clip(p, 110)
            end
        end

        local head_str = table.concat(head_lines, "\n")
        local tail_str = table.concat(tail_lines, "\n")
        local detail_raw = common.trim(ev.objective_summary or "")

        local rendered
        if detail_raw ~= "" then
            local fixed_len = common.utf8_len(head_str) + common.utf8_len(tail_str) + common.utf8_len(persona_block) + 7
            local detail_budget = math.max(30, max_total - fixed_len)
            local detail_line = "📝 详情：" .. common.clip(detail_raw, detail_budget)
            rendered = common.clip(head_str .. "\n" .. detail_line .. "\n" .. tail_str .. persona_block, max_total)
        else
            rendered = common.clip(head_str .. "\n" .. tail_str .. persona_block, max_total)
        end

        -- 水印始终附着在首行末尾，绝不参与 clip 裁剪
        local nl = rendered:find("\n", 1, true)
        if nl then
            return rendered:sub(1, nl - 1) .. common.WATERMARK .. rendered:sub(nl)
        end
        return rendered .. common.WATERMARK
    end

    return M
end
