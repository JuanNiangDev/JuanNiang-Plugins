-- card.lua — repo-intro 仓库卡片渲染（T2I）、正文组装与发送

return function(jn, common, modeldb, deps)
    local M = {}

    local card_ctx_batch_tbl = {}

    local function load_template(prefer)
        local n = prefer or common.cfg_string("card_template", "5")
        local tpl, err
        if not prefer and n == "random" then
            n = tostring(math.random(1, 5))
            tpl = jn.file.read("templates/card-" .. n .. ".html")
            if tpl then return tpl end
            n = "5"
        end
        tpl, err = jn.file.read("templates/card-" .. n .. ".html")
        if not tpl then
            jn.log.warn("[repo-intro] 卡片模板读取失败 templates/card-" .. n .. ".html err=" .. tostring(err))
            return nil
        end
        return tpl
    end

    local function fmt_count(n)
        n = tonumber(n)
        if not n or n < 0 then return "0" end
        if n >= 1000 then
            local k = n / 1000
            if k >= 10 then return string.format("%.0fk", k) end
            return string.format("%.1fk", k)
        end
        return tostring(n)
    end

    local function fill_template(tpl, e)
        if e.kind ~= "github" then
            return modeldb.fill_model_template(tpl, e)
        end
        local m = e.meta or {}
        local llm = e.llm or {}
        local desc = (llm.desc_cn ~= nil and llm.desc_cn ~= "") and llm.desc_cn
            or (llm.desc ~= nil and llm.desc ~= "") and llm.desc
            or (m.desc or "")
        local data = {
            OWNER = e.owner,
            REPO = e.repo,
            DESC = desc,
            URL = e.url or "",
            STARS = fmt_count(m.stars),
            FORKS = fmt_count(m.forks),
            ISSUES = fmt_count(m.issues),
            LANG_NAME = (m.lang and m.lang ~= "") and m.lang or "Other",
            AVATAR = (m.avatar ~= nil and m.avatar ~= "") and m.avatar
                or "data:image/svg+xml;charset=utf-8,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='140'%20height='140'%3E%3Ccircle%20cx='70'%20cy='70'%20r='70'%20fill='%23d0d7de'/%3E%3C/svg%3E",
        }
        local out = tpl
        for k, v in pairs(data) do
            out = out:gsub("{{" .. k .. "}}", function() return tostring(v) end)
        end
        return out
    end

    local function compose_section(e)
        local lines = {}
        local name = (e.meta and e.meta.name) or (e.owner .. "/" .. e.repo)
        -- 仅在拿到有效 LLM 总结时附带零宽水印；失败降级成原始简介时不加水印，
        -- 避免既被自身误判阻断重试、又被日报当成正常卡片搬运。
        local wm = common.has_valid_llm(e) and common.WATERMARK or ""
        lines[#lines + 1] = "📦 " .. name .. wm

        local llm = e.llm
        local desc_line = nil
        if e.kind == "github" then
            local desc = (llm and llm.desc_cn) or (llm and llm.desc) or (e.meta and e.meta.desc)
            if desc and desc ~= "" then
                desc_line = e.repo .. "：" .. desc
            elseif llm and llm.title and llm.title ~= "" then
                desc_line = llm.title
            end
        elseif llm and llm.title and llm.title ~= "" then
            desc_line = llm.title
        end
        if e.sub == "datasets" and desc_line and desc_line ~= "" and not desc_line:find("数据集", 1, true) then
            desc_line = desc_line .. " 数据集"
        end
        if not desc_line and llm and llm.type and llm.type ~= "" then
            desc_line = llm.type
        end
        if not desc_line and e.sub == "datasets" then
            desc_line = e.repo .. " 数据集"
        end
        if desc_line then
            lines[#lines + 1] = "📝 " .. desc_line
        end
        local summary = llm and llm.summary or (e.meta and e.meta.desc) or ""
        if summary ~= "" then
            lines[#lines + 1] = summary
        end
        local url = e.url or ""
        if url ~= "" and not (summary ~= "" and summary:find(url, 1, true)) then
            lines[#lines + 1] = url
        end
        return table.concat(lines, "\n")
    end

    local function compose_segments(batch)
        local segs = {}
        local persisted = {}
        local send_card = common.cfg_bool("card_enabled", true)
        local first = true
        for _, e in ipairs(batch.entries) do
            if not e.skipped and (e.llm or not e.err) then
                local view = e._group_view or e
                local text = compose_section(view)
                if not first then
                    text = "\n\n" .. text
                end
                first = false
                segs[#segs + 1] = { type = "text", data = { text = text } }
                local imgs = e.key_images
                if not imgs and deps.collect_readme_images then
                    imgs = deps.collect_readme_images(e)
                end
                local entry_imgs = {}
                for _, img in ipairs(imgs or {}) do
                    segs[#segs + 1] = { type = "image", data = { file = img } }
                    entry_imgs[#entry_imgs + 1] = img
                end
                if send_card and e.card_url and e.card_url ~= "" then
                    segs[#segs + 1] = { type = "image", data = { file = e.card_url } }
                    entry_imgs[#entry_imgs + 1] = e.card_url
                end
                if common.has_valid_llm(view) then
                    persisted[#persisted + 1] = {
                        entry = view,
                        text = compose_section(view),
                        images = entry_imgs,
                    }
                end
            end
        end
        if #segs == 0 then return nil, nil end
        return segs, persisted
    end

    local function send_intro(batch, segments)
        if not segments or #segments == 0 then return end
        local t = batch.target
        if t.reply_quote and t.message_id ~= nil and tostring(t.message_id) ~= "" then
            table.insert(segments, 1, { type = "reply", data = { id = tostring(t.message_id) } })
        end
        if t.message_type == "group" then
            jn.onebot11.send_group_msg(t.target_id, segments)
        else
            jn.onebot11.send_private_msg(t.target_id, segments)
        end
    end

    function M.compose_and_send(batch)
        for _, e in ipairs(batch.entries) do
            if e.owned_dedup then
                jn.cache.del("dedup:" .. e.key)
            end
        end
        local segments, persisted = compose_segments(batch)
        if segments then
            send_intro(batch, segments)
            if persisted and deps.persist_repo_history then
                local t = batch.target or {}
                local gid = (t.message_type == "group") and (tonumber(t.target_id) or 0) or 0
                for _, item in ipairs(persisted) do
                    pcall(deps.persist_repo_history, gid, item.entry, item.text, item.images)
                end
            end
        end
    end

    local function finish_cards(batch)
        for idx, ct in pairs(batch.pending_content or {}) do
            local e = batch.llm_usable and batch.llm_usable[idx]
            if e and common.has_valid_llm(e) then
                ct.card_url = e.card_url or ""
                if not e._group_sanitized and deps.repo_cache_set then
                    deps.repo_cache_set(e, ct)
                end
            end
        end
        M.compose_and_send(batch)
    end

    function M.start_cards(batch)
        local usable = batch.llm_usable or {}
        local is_group = batch.target and batch.target.message_type == "group"
        if is_group then
            for _, e in ipairs(usable) do
                local view, changed = common.sanitize_entry_for_group(e)
                if changed then
                    e._group_view = view
                    e._group_sanitized = true
                    e.card_url = ""
                end
            end
        end
        local all_model = #usable > 0
        for _, e in ipairs(usable) do
            if e.kind == "github" then all_model = false break end
        end
        local tpl = all_model and load_template("6") or load_template()
        local enabled = common.cfg_bool("card_enabled", true)
            and tpl ~= nil and jn.t2i ~= nil and jn.t2i.is_active() and jn.t2i.generate_url_async ~= nil
        if not enabled then
            finish_cards(batch)
            return
        end
        local pending = 0
        for idx, e in ipairs(usable) do
            if e.kind ~= "github" and e.sub ~= "models" then
                e.card_url = ""
            elseif e._group_sanitized or not e.card_url or e.card_url == "" then
                local etpl = (e.kind ~= "github") and (load_template("6") or tpl) or tpl
                local html = fill_template(etpl, e._group_view or e)
                pending = pending + 1
                local rid = jn.t2i.generate_url_async(html, {
                    viewport_width = common.cfg_num("card_width", 900),
                    viewport_height = common.cfg_num("card_height", 450),
                }, { idx = idx })
                if not rid or rid == 0 then
                    pending = pending - 1
                    e.card_url = nil
                else
                    card_ctx_batch_tbl[rid] = batch
                end
            end
        end
        batch.card_pending = pending
        if pending == 0 then
            finish_cards(batch)
        end
    end

    function M.on_t2i_response(req_id, ctx, result, err)
        local batch = card_ctx_batch_tbl[req_id]
        card_ctx_batch_tbl[req_id] = nil
        if not batch then return end
        local idx = ctx and ctx.idx
        local e = batch.llm_usable and idx and batch.llm_usable[idx]
        if err or not result or result == "" then
            jn.log.warn("[repo-intro] 卡片渲染失败 idx=" .. tostring(idx) .. " err=" .. tostring(err))
            if e then e.card_url = nil end
        elseif e then
            e.card_url = result
        end
        if batch.card_pending then
            batch.card_pending = batch.card_pending - 1
            if batch.card_pending <= 0 then
                finish_cards(batch)
            end
        end
    end

    return M
end
