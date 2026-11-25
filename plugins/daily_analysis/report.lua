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
        ai_monitor = "🤖 今日 AI 重置与官方状态监控",
        news = "📰 今日新闻",
        stats = "📈 本次分析统计",
    }

    function M.parse_sections_config()
        local list = jn.config.get("sections")
        if type(list) ~= "table" or #list == 0 then
            list = {
                "overview||1", "top||1", "topics||-1", "quotes||-1", "titles||6",
                "critique||4", "projects||20", "ai_monitor||1", "news||70", "stats||1",
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

    local function llm_json_async(system, user, on_done)
        if not (jn.llm and (jn.llm.chat_async or jn.llm.chat)) then
            on_done(nil, "无 LLM")
            return
        end
        local timeout = math.max(30, common.da_num("llm_timeout", 360))
        common.llm_chat_async({
            { role = "system", content = system },
            { role = "user", content = user },
        }, { timeout = timeout }, function(resp, err)
            if err or not resp or resp == "" then
                on_done(nil, tostring(err or "空响应"))
                return
            end
            local obj, perr = common.decode_llm_json(resp, "新闻合并")
            if not obj then
                on_done(nil, perr or "JSON 解析失败")
                return
            end
            on_done(obj, nil)
        end)
    end

    local function prepare_news_merge(articles, juya_items, max_items)
        local wechat, wx_by_id, dropped = {}, {}, 0
        for i, a in ipairs(articles) do
            if #wechat >= 40 then break end
            local t = common.strip_wm(a.title or "")
            local s = common.strip_wm(a.summary or "")
            if t ~= "" or s ~= "" then
                local wid = #wechat + 1
                local w = {
                    wx_id = wid, title = t, summary = s,
                    url = a.url, count = a.count,
                }
                wechat[wid] = w
                wx_by_id[wid] = w
            else
                dropped = dropped + 1
            end
        end
        if dropped > 0 then
            jn.log.info(string.format("[%s] 新闻过滤：%d 条无标题链接未进正文", common.PLUGIN_NAME, dropped))
        end

        local juya_list, juya_by_id, juya_payload = {}, {}, {}
        for _, it in ipairs(juya_items) do
            if #juya_list >= math.min(max_items * 2, 80) then break end
            local jid = #juya_list + 1
            local links = {}
            for _, l in ipairs(it.links or {}) do
                if l.url and l.url ~= "" then links[#links + 1] = l.url end
            end
            local body_detail = (it.detail and it.detail ~= "") and it.detail or (it.summary or "")
            local entry = {
                juya_id = jid,
                title = it.title or "",
                summary = it.summary or "",
                detail = body_detail,
                category = it.category or "",
                links = links,
            }
            juya_list[jid] = entry
            juya_by_id[jid] = entry
            juya_payload[jid] = {
                juya_id = jid,
                title = entry.title,
                summary = entry.summary,
                category = entry.category,
            }
        end

        if #wechat == 0 and #juya_list == 0 then return nil, {}, {} end

        local function fallback_list()
            local out = {}
            for _, j in ipairs(juya_list) do
                out[#out + 1] = { title = j.title, summary = j.detail, links = j.links }
            end
            for _, w in ipairs(wechat) do
                out[#out + 1] = {
                    title = w.title ~= "" and w.title or "公众号文章",
                    summary = w.summary, links = { w.url },
                }
            end
            return out
        end

        -- 无任何公众号文章或关闭事件合并时，直接原样搬运橘鸦完整内容，零 LLM 消耗
        if #wechat == 0 or not common.da_bool("news_event_merge", true) then
            return nil, fallback_list(), fallback_list
        end

        local payload = jn.json.encode({ wechat = wechat, juya = juya_payload })
        local system = string.format([[
你在整理今日 AI 新闻。输入含两类条目：
- wechat：群里抓取总结或合并转发提取的微信公众号文章（wx_id、title、summary、url、count）
- juya：橘鸦 AI 早报的当日条目（juya_id、title、summary、category）

请对比两者并返回严格 JSON：
{"events":[ ... ]}

规则（非常重要，必须严格遵守）：
1. 【橘鸦独占新闻只返回标记】：如果某条 juya 新闻没有任何重合的 wechat 文章，严禁重写其 title/summary/links，只返回标记对象：{"juya_id": 1}，代码会自动原样搬运橘鸦全文与链接！
2. 【重合事件合并到橘鸦】：如果某些 wechat 文章与某条 juya 描述同一事件，把公众号补充的信息合并进该橘鸦新闻中，返回：{"juya_id": 1, "wx_ids": [2], "title": "精炼标题", "summary": "融合橘鸦与公众号要点后的简体中文摘要(≤180字)"}；
3. 【公众号独占新闻】：不与任何 juya 重合的公众号文章，返回：{"wx_ids": [3], "title": "标题", "summary": "摘要"}（若同一事件有多篇公众号合并则在 wx_ids 列出全部编号）；
4. 最多 %d 条，按重要性排序；不要输出除 JSON 以外的任何内容。]], max_items)
        return { system = system, payload = payload, wx_by_id = wx_by_id, juya_by_id = juya_by_id }, nil, fallback_list
    end

    local function parse_merged_news_obj(obj, err, fallback_list, req)
        if not obj or type(obj.events) ~= "table" then
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 新闻合并失败，降级为顺序罗列: " .. tostring(err))
            return fallback_list()
        end
        local wx_by_id = (req and req.wx_by_id) or {}
        local juya_by_id = (req and req.juya_by_id) or {}
        local out = {}

        local function collect_unique_links(dest, seen, list)
            for _, u in ipairs(list or {}) do
                local s = tostring(u or "")
                if s:find("^https?://") and not seen[s] then
                    seen[s] = true
                    dest[#dest + 1] = s
                end
            end
        end

        for _, e in ipairs(obj.events) do
            if type(e) == "table" then
                local jid = tonumber(e.juya_id)
                local j = jid and juya_by_id[jid] or nil
                local wids = {}
                if type(e.wx_ids) == "table" then
                    for _, wid in ipairs(e.wx_ids) do
                        local wn = tonumber(wid)
                        if wn and wx_by_id[wn] then wids[#wids + 1] = wn end
                    end
                elseif tonumber(e.wx_id) and wx_by_id[tonumber(e.wx_id)] then
                    wids[#wids + 1] = tonumber(e.wx_id)
                end

                local links, lseen = {}, {}
                if j then
                    collect_unique_links(links, lseen, j.links)
                end
                for _, wn in ipairs(wids) do
                    collect_unique_links(links, lseen, { wx_by_id[wn].url })
                end
                if type(e.links) == "table" then
                    collect_unique_links(links, lseen, e.links)
                end

                if j and #wids == 0 and (not e.title or e.title == "") and (not e.summary or e.summary == "") then
                    -- 纯标记原样搬运橘鸦（优先完整 detail，无正文回退 summary）
                    out[#out + 1] = {
                        title = j.title,
                        summary = j.detail,
                        links = links,
                    }
                elseif j then
                    local ttl = common.strip_wm(tostring(e.title or ""))
                    local sum = common.strip_wm(tostring(e.summary or ""))
                    if ttl == "" then ttl = j.title end
                    if sum == "" then sum = j.detail end
                    out[#out + 1] = { title = ttl, summary = sum, links = links }
                elseif #wids > 0 or (e.title and tostring(e.title) ~= "") then
                    local first_w = wids[1] and wx_by_id[wids[1]] or nil
                    local ttl = common.strip_wm(tostring(e.title or ""))
                    local sum = common.strip_wm(tostring(e.summary or ""))
                    if ttl == "" and first_w then ttl = first_w.title ~= "" and first_w.title or "公众号文章" end
                    if sum == "" and first_w then sum = first_w.summary end
                    if ttl ~= "" then
                        out[#out + 1] = { title = ttl, summary = sum, links = links }
                    end
                end
            end
        end
        return out
    end

    local function merge_news_async(articles, juya_items, max_items, on_done)
        local req, immediate, fallback_list = prepare_news_merge(articles, juya_items, max_items)
        if not req then
            on_done(immediate or {})
            return
        end
        llm_json_async(req.system, req.payload, function(obj, err)
            on_done(parse_merged_news_obj(obj, err, fallback_list, req))
        end)
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

    local AI_PRODUCT_LABELS = {
        codex = "Codex",
        antigravity = "Antigravity",
        claude = "Claude / Claude Code",
        grok = "Grok",
        grok_bot = "Grok Bot",
        glm = "GLM Coding Plan",
        qoder = "Qoder",
        kimi = "Kimi / Kimi Code",
        gemini_cli = "Gemini CLI",
        cursor = "Cursor",
        openai_status = "OpenAI 服务状态",
        claude_status = "Claude 服务状态",
        deepseek_status = "DeepSeek 服务状态",
    }

    local AI_KIND_LABELS = {
        direct_reset = "🎉 直接重置",
        banked_reset = "🎟️ 发放重置卡",
        scheduled_reset = "⏳ 官方预告重置",
        rule_change = "📢 额度/规则变更",
        status_incident = "🚨 官方服务异常",
        status_resolved = "✅ 官方服务恢复",
    }

    local function fetch_ai_monitor_digest()
        if not (jn.database and jn.database.query) then
            return { "暂未获取到 AI 监控数据库权限" }
        end
        local cutoff = os.time() - 86400
        local sql = [[
            SELECT product, event_kind, title, source_url, announced_ts, payload_json
            FROM pluggin_ai_reset_monitor_seen
            WHERE announced_ts >= ?
              AND product NOT IN ('_meta', '')
              AND event_kind IN ('direct_reset', 'banked_reset', 'scheduled_reset', 'rule_change', 'status_incident', 'status_resolved')
            ORDER BY announced_ts DESC, created_at DESC
            LIMIT 40
        ]]
        local ok, rows, err = pcall(jn.database.query, sql, { cutoff })
        if not ok or err or type(rows) ~= "table" or #rows == 0 then
            return { "过去 24 小时各监测平台暂无额度重置或官方服务故障记录" }
        end

        local lines = {}
        for _, r in ipairs(rows) do
            local plabel = AI_PRODUCT_LABELS[r.product] or tostring(r.product or "AI服务")
            local klabel = AI_KIND_LABELS[r.event_kind] or tostring(r.event_kind or "动态")
            local ts = tonumber(r.announced_ts) or 0
            local tstr = ts > 0 and os.date("!%m-%d %H:%M", ts + 8 * 3600) or "近期"
            local obj_sum = ""
            if type(r.payload_json) == "string" and r.payload_json ~= "" then
                local okj, pj = pcall(jn.json.decode, r.payload_json)
                if okj and type(pj) == "table" and pj.objective_summary and pj.objective_summary ~= "" then
                    obj_sum = common.strip_wm(tostring(pj.objective_summary))
                end
            end
            local ttl = common.strip_wm(tostring(r.title or ""))
            local block = { string.format("• [%s] %s · %s", tstr, plabel, klabel) }
            if ttl ~= "" then block[#block + 1] = "  " .. common.clip(ttl, 80) end
            if obj_sum ~= "" and obj_sum ~= ttl then
                block[#block + 1] = "  " .. common.clip(obj_sum, 160)
            end
            if r.source_url and r.source_url ~= "" then
                block[#block + 1] = "  " .. tostring(r.source_url)
            end
            lines[#lines + 1] = table.concat(block, "\n")
        end
        return { table.concat(lines, "\n\n") }
    end

    local function assemble_sections(sec_configs, stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, messages, chat_messages, projects, news_items)
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

        local top_n = math.max(1, math.floor(common.da_num("top_users_count", 5)))

        for _, s in ipairs(sec_configs) do
            local items = {}
            if s.key == "overview" then
                items[1] = string.format("🏢 分析群聊: %s (%d)\n📅 统计时间: %s\n💬 消息总量: %d 条\n👥 参与人数: %d 人\n⏰ 最活跃时段: %s",
                    group_name, group_id, os.date("%Y年%m月%d日"), stats.total_count, stats.user_count, stats.peak_period)
            elseif s.key == "top" then
                if stats.top_users and #stats.top_users > 0 then
                    local lines = {}
                    for idx = 1, math.min(top_n, #stats.top_users) do
                        local u = stats.top_users[idx]
                        lines[#lines + 1] = string.format("👑 Top%d: %s (%d条)", idx, common.strip_wm(u.name), u.count)
                    end
                    items[1] = table.concat(lines, "\n")
                end
            elseif s.key == "ai_monitor" then
                items = fetch_ai_monitor_digest()
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
                local n = 0
                for _, e in ipairs(news_items or {}) do
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

    function M.build_sections_async(stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, messages, chat_messages, precollected, on_done)
        on_done = on_done or function() end
        local projects, articles
        if type(precollected) == "table" and precollected.projects and precollected.articles then
            projects, articles = precollected.projects, precollected.articles
        else
            projects, articles = sources.collect_sources(messages or {})
        end

        local function after_repos()
            local sec_configs = M.parse_sections_config()
            local need_news, news_lim = false, 70
            for _, s in ipairs(sec_configs) do
                if s.key == "news" and s.cap ~= 0 then
                    need_news = true
                    news_lim = (s.cap > 0) and s.cap or ((s.cap == -1) and 200 or 70)
                    break
                end
            end
            if not need_news then
                on_done(assemble_sections(sec_configs, stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, messages, chat_messages, projects, {}))
                return
            end
            local juya_items = fetch_juya_items()
            merge_news_async(articles, juya_items, news_lim, function(news_items)
                on_done(assemble_sections(sec_configs, stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, messages, chat_messages, projects, news_items))
            end)
        end

        if common.da_bool("enable_projects", true) and enrich.enrich_repos_async then
            enrich.enrich_repos_async(projects, after_repos)
        else
            if common.da_bool("enable_projects", true) then enrich.enrich_repos(projects) end
            after_repos()
        end
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
        local juya_items, news_items, news_lim = {}, {}, 70
        local need_news = false
        for _, s in ipairs(sec_configs) do
            if s.key == "news" and s.cap ~= 0 then
                need_news = true
                news_lim = (s.cap > 0) and s.cap or ((s.cap == -1) and 200 or 70)
                juya_items = fetch_juya_items()
                break
            end
        end
        if need_news then
            local req, immediate, fallback_list = prepare_news_merge(articles, juya_items, news_lim)
            if not req then
                news_items = immediate or {}
            elseif jn.llm and jn.llm.chat then
                local timeout = math.max(30, common.da_num("llm_timeout", 360))
                local resp, err = jn.llm.chat({
                    { role = "system", content = req.system },
                    { role = "user", content = req.payload },
                }, { timeout = timeout })
                local obj = (not err and resp and resp ~= "") and common.decode_llm_json(resp, "新闻合并") or nil
                news_items = parse_merged_news_obj(obj, err, fallback_list, req)
            else
                news_items = fallback_list()
            end
        end
        return assemble_sections(sec_configs, stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, messages, chat_messages, projects, news_items)
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
