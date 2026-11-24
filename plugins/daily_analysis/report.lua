-- report.lua — daily_analysis 新闻合并、板块组装、合并转发发送与持久化

return function(jn, common, sources, enrich, juya, get_bot_uin)
    local M = {}

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

    function M.parse_sections_config()
        local list = jn.config.get("sections")
        if type(list) ~= "table" or #list == 0 then
            list = {
                "overview||1", "top||1", "topics||-1", "quotes||-1", "titles||6",
                "critique||4", "projects||20", "news||70", "stats||1",
            }
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

    local function llm_json(system, user)
        if not (jn.llm and jn.llm.chat) then return nil, "无 LLM" end
        local timeout = math.max(30, common.da_num("llm_timeout", 300))
        local resp, err = jn.llm.chat({
            { role = "system", content = system },
            { role = "user", content = user },
        }, { timeout = timeout })
        if err or not resp or resp == "" then return nil, tostring(err or "空响应") end
        local obj, perr = common.decode_llm_json(resp, "新闻合并")
        if not obj then return nil, perr or "JSON 解析失败" end
        return obj, nil
    end

    local function merge_news(articles, juya_items, max_items)
        local wechat, juya_list, dropped = {}, {}, 0
        for i, a in ipairs(articles) do
            if i > 40 then break end
            if (a.title or "") ~= "" or (a.summary or "") ~= "" then
                wechat[#wechat + 1] = {
                    i = i, title = a.title or "", summary = a.summary or "",
                    url = a.url, count = a.count,
                }
            else
                dropped = dropped + 1
            end
        end
        if dropped > 0 then
            jn.log.info(string.format("[%s] 新闻过滤：%d 条无标题链接未进正文", common.PLUGIN_NAME, dropped))
        end
        local jidx = 0
        for _, it in ipairs(juya_items) do
            if jidx >= math.min(max_items * 2, 80) then break end
            jidx = jidx + 1
            local links = {}
            for _, l in ipairs(it.links) do links[#links + 1] = l.url end
            juya_list[#juya_list + 1] = {
                i = 100 + jidx, title = it.title, summary = it.summary,
                category = it.category, links = links,
            }
        end
        if #wechat == 0 and #juya_list == 0 then return {} end

        local function fallback_list()
            local out = {}
            for _, j in ipairs(juya_list) do
                out[#out + 1] = { title = j.title, summary = j.summary, links = j.links }
            end
            for _, a in ipairs(wechat) do
                out[#out + 1] = {
                    title = a.title ~= "" and a.title or "公众号文章",
                    summary = a.summary, links = { a.url },
                }
            end
            return out
        end

        if not common.da_bool("news_event_merge", true) then
            return fallback_list()
        end

        local payload = jn.json.encode({ wechat = wechat, juya = juya_list })
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
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 新闻合并失败，降级为顺序罗列: " .. tostring(err))
            return fallback_list()
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

    local function fetch_juya_items()
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
        if not juya then
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 橘鸦早报抓取失败: juya 模块未加载")
            return {}
        end
        local ok, url, html, _, ferr = pcall(function()
            return juya.fetch_issue(feeds, os.date("%Y-%m-%d"))
        end)
        if ok and html then
            local items = juya.flatten(juya.parse_issue(html))
            jn.log.info(string.format("[%s] 橘鸦早报抓取成功: %s（%d 条）", common.PLUGIN_NAME, tostring(url), #items))
            return items
        end
        jn.log.warn("[" .. common.PLUGIN_NAME .. "] 橘鸦早报抓取失败: " .. tostring(ok and ferr or url))
        return {}
    end

    function M.build_sections(stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, messages, chat_messages, precollected)
        local projects, articles
        if type(precollected) == "table" and precollected.projects and precollected.articles then
            projects, articles = precollected.projects, precollected.articles
        else
            projects, articles = sources.collect_sources(messages or {})
        end
        if common.da_bool("enable_projects", true) then enrich.enrich_repos(projects) end

        local sec_configs = M.parse_sections_config()
        local juya_items = {}
        for _, s in ipairs(sec_configs) do
            if s.key == "news" and s.cap ~= 0 then
                juya_items = fetch_juya_items()
                break
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

        for _, s in ipairs(sec_configs) do
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
                    local part = (t.participants and t.participants ~= "") and ("参与者: " .. t.participants .. "\n") or ""
                    items[#items + 1] = string.format("【%d】%s\n%s%s", idx, t.title or "核心话题", part, t.summary or "")
                end
            elseif s.key == "quotes" and type(analysis_data.golden_quotes) == "table" then
                local seen, n = {}, 0
                for _, q in ipairs(analysis_data.golden_quotes) do
                    local content = common.clean_quote_text(q.content)
                    local src = sources.quote_source_text(chat_messages or messages, q.msg_id)
                    if src and #src > #content and #src >= 4 then content = src end
                    local dedup = content:gsub("%s+", "")
                    if #content >= 4 and not seen[dedup] then
                        seen[dedup] = true
                        n = n + 1
                        local reason = (q.reason and q.reason ~= "") and ("\n💡 甄选理由: " .. q.reason) or ""
                        items[#items + 1] = string.format("📜 金句 #%d · %s:\n「\n%s\n」%s", n, q.sender or "群友", content, reason)
                    end
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
                for _, p in ipairs(projects) do
                    if not p.invalid then
                        if p.text and p.text ~= "" then
                            items[#items + 1] = { text = p.text, images = p.images }
                        else
                            local lines = { "📦 " .. p.name }
                            if p.ri then
                                local tline = (p.ri.title and p.ri.title ~= "" and p.ri.title)
                                    or (p.ri.desc_cn and p.ri.desc_cn ~= "" and p.ri.desc_cn) or ""
                                if tline ~= "" then lines[#lines + 1] = "📝 " .. tline end
                                if p.ri.desc_cn and p.ri.desc_cn ~= "" and tline ~= p.ri.desc_cn then
                                    lines[#lines + 1] = p.ri.desc_cn
                                end
                                local body = p.summary
                                if (not body or body == "") and p.ri.summary then body = p.ri.summary end
                                if (not body or body == "") and p.ri.desc_cn then body = p.ri.desc_cn end
                                if body and body ~= "" then lines[#lines + 1] = body end
                            elseif p.summary and p.summary ~= "" then
                                lines[#lines + 1] = p.summary
                            end
                            lines[#lines + 1] = p.url
                            items[#items + 1] = { text = table.concat(lines, "\n"), images = p.images }
                        end
                    end
                end
                if #items == 0 then items[1] = "今日没有检测到开源项目 / 模型仓库链接" end
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

    local function item_text(item)
        if type(item) == "table" then return tostring(item.text or "") end
        return tostring(item or "")
    end

    local function item_images(item)
        if type(item) == "table" and type(item.images) == "table" then return item.images end
        return nil
    end

    local function node_payload(text, images)
        if not images or #images == 0 then return text end
        local segs = { { type = "text", data = { text = text } } }
        for _, u in ipairs(images) do segs[#segs + 1] = { type = "image", data = { file = u } } end
        return segs
    end

    local send_queue, send_pump_scheduled, last_send_at = {}, false, 0

    local function get_send_interval()
        return math.max(0, common.da_num("send_interval", 15))
    end

    local function send_onebot_msg_raw(target_type, target_id, payload)
        if target_type == "group" then
            return jn.onebot11.send_group_msg(target_id, payload)
        end
        return jn.onebot11.send_private_msg(target_id, payload)
    end

    local function schedule_send_pump()
        if send_pump_scheduled or #send_queue == 0 then return end
        local interval = get_send_interval()
        local elapsed = os.time() - last_send_at
        if interval <= 0 or last_send_at == 0 or elapsed >= interval then
            M.pump_send_queue()
            return
        end
        if jn.timer and jn.timer.after then
            send_pump_scheduled = true
            jn.timer.after(math.max(1, interval - elapsed), { action = "report_send_pump" })
        else
            while #send_queue > 0 do
                local task = table.remove(send_queue, 1)
                send_onebot_msg_raw(task.target_type, task.target_id, task.payload)
                last_send_at = os.time()
            end
        end
    end

    function M.pump_send_queue()
        send_pump_scheduled = false
        if #send_queue == 0 then return end
        local interval = get_send_interval()
        local elapsed = os.time() - last_send_at
        if interval > 0 and last_send_at > 0 and elapsed < interval then
            schedule_send_pump()
            return
        end
        local task = table.remove(send_queue, 1)
        send_onebot_msg_raw(task.target_type, task.target_id, task.payload)
        last_send_at = os.time()
        if #send_queue > 0 then
            schedule_send_pump()
        end
    end

    local function send_onebot_msg(target_type, target_id, payload)
        local interval = get_send_interval()
        local elapsed = os.time() - last_send_at
        if #send_queue == 0 and (interval <= 0 or last_send_at == 0 or elapsed >= interval) then
            local res, err = send_onebot_msg_raw(target_type, target_id, payload)
            last_send_at = os.time()
            return res, err
        end
        send_queue[#send_queue + 1] = {
            target_type = target_type,
            target_id = target_id,
            payload = payload,
        }
        schedule_send_pump()
        return true, nil
    end

    local function send_onebot_forward_sync(target_type, target_id, nodes)
        local res, err
        if target_type == "group" then
            if not jn.onebot11.send_group_forward_msg_sync then return nil, "no_forward_api" end
            res, err = jn.onebot11.send_group_forward_msg_sync(target_id, nodes)
        else
            if not jn.onebot11.send_private_forward_msg_sync then return nil, "no_forward_api" end
            res, err = jn.onebot11.send_private_forward_msg_sync(target_id, nodes)
        end
        if err == nil then last_send_at = os.time() end
        return res, err
    end

    local function nodes_text_only(nodes, uin, name)
        local out = {}
        for _, n in ipairs(nodes) do
            local c = n.content
            if type(c) == "table" then
                local parts = {}
                for _, seg in ipairs(c) do
                    if type(seg) == "table" and seg.type == "text"
                        and type(seg.data) == "table" and seg.data.text and seg.data.text ~= "" then
                        parts[#parts + 1] = tostring(seg.data.text)
                    end
                end
                out[#out + 1] = { user_id = uin, nickname = name, content = table.concat(parts, "\n") }
            else
                out[#out + 1] = n
            end
        end
        return out
    end

    local function send_nodes_as_text(target_type, target_id, nodes)
        local parts = {}
        for _, n in ipairs(nodes) do
            local c = n.content
            if type(c) == "string" and c ~= "" then
                parts[#parts + 1] = c
            elseif type(c) == "table" then
                for _, seg in ipairs(c) do
                    if type(seg) == "table" and seg.type == "text"
                        and type(seg.data) == "table" and seg.data.text and seg.data.text ~= "" then
                        parts[#parts + 1] = tostring(seg.data.text)
                    end
                end
            end
        end
        local chunks = chunk_text(table.concat(parts, "\n\n"), 1500)
        for _, c in ipairs(chunks) do send_onebot_msg(target_type, target_id, c) end
        return #chunks
    end

    function M.send_report(sections, target_type, target_id)
        if #sections == 0 then return 0, 0 end
        local mode = tostring(jn.config.get("report_mode") or "forward")

        if mode == "forward" then
            local name = jn.config.get("custom_sender_name")
            if not name or name == "" then
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
            for _, s in ipairs(sections) do
                if #s.items == 1 then
                    local it = s.items[1]
                    push(node_payload(s.title .. "\n" .. item_text(it), item_images(it)))
                else
                    push(s.title)
                    for _, item in ipairs(s.items) do
                        push(node_payload(item_text(item), item_images(item)))
                    end
                end
            end
            local _, ferr = send_onebot_forward_sync(target_type, target_id, nodes)
            if ferr == nil then return 1, #nodes end

            local text_nodes = nodes_text_only(nodes, uin, name)
            local _, ferr2 = send_onebot_forward_sync(target_type, target_id, text_nodes)
            if ferr2 == nil then
                jn.log.warn("[" .. common.PLUGIN_NAME .. "] 合并转发带图失败，已改纯文本转发并单独补图: " .. tostring(ferr))
                local imgs = {}
                for _, s in ipairs(sections) do
                    for _, item in ipairs(s.items) do
                        for _, u in ipairs(item_images(item) or {}) do imgs[#imgs + 1] = u end
                    end
                end
                for i = 1, #imgs, 4 do
                    local segs = {}
                    for k = i, math.min(i + 3, #imgs) do
                        segs[#segs + 1] = { type = "image", data = { file = imgs[k] } }
                    end
                    send_onebot_msg(target_type, target_id, segs)
                end
                return 1, #text_nodes
            end
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 合并转发失败，改用合并文本: " .. tostring(ferr))
            return send_nodes_as_text(target_type, target_id, nodes), #nodes
        end

        local count = 0
        for _, s in ipairs(sections) do
            local n = #s.items
            if mode == "per_section" then
                local lines, images = {}, {}
                for _, item in ipairs(s.items) do
                    lines[#lines + 1] = item_text(item)
                    for _, u in ipairs(item_images(item) or {}) do images[#images + 1] = u end
                end
                local chunks = chunk_text(s.title .. "\n" .. table.concat(lines, "\n\n"), 1500)
                for i, chunk in ipairs(chunks) do
                    send_onebot_msg(target_type, target_id,
                        i == #chunks and node_payload(chunk, images) or chunk)
                    count = count + 1
                end
            else
                for i, item in ipairs(s.items) do
                    local head = (n > 1) and string.format("%s (%d/%d)\n", s.title, i, n) or (s.title .. "\n")
                    send_onebot_msg(target_type, target_id, node_payload(head .. item_text(item), item_images(item)))
                    count = count + 1
                end
            end
        end
        return count, count
    end

    function M.persist_report(group_id, target_id, sections, mode, node_count)
        local flat = {}
        for _, sec in ipairs(sections or {}) do
            flat[#flat + 1] = "## " .. tostring(sec.title or sec.key or "")
            for _, item in ipairs(sec.items or {}) do
                flat[#flat + 1] = item_text(item)
            end
        end
        local content = table.concat(flat, "\n")
        local ok_enc, encoded = pcall(jn.json.encode, sections)
        if not ok_enc then encoded = "" end
        local _, err = jn.database.exec([[INSERT INTO ]] .. common.TABLE_REPORTS .. [[
            (group_id, target_id, report_date, mode, section_count, node_count, sections, content)
            VALUES (?, ?, CURRENT_DATE, ?, ?, ?, ?, ?)
        ]], { group_id, target_id, tostring(mode), #sections, node_count or 0,
              tostring(encoded or ""), content })
        if err then
            jn.log.error("[" .. common.PLUGIN_NAME .. "] 日报持久化失败: " .. tostring(err))
        else
            jn.log.info(string.format("[%s] 日报已落库 group=%d 板块=%d 字符=%d",
                common.PLUGIN_NAME, group_id, #sections, #content))
        end
    end

    return M
end
