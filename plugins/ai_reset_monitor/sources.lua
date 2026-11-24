-- sources.lua — 官方信源注册、RSS/Atom/JSON 解析、X 原帖回源核验与 DeepSeek 降级

return function(jn, common)
    local M = {}

    -- 内置官方 X 时间线（fxtwitter.com/<handle>/feed.xml，均已实测 HTTP 200）
    local FXTWITTER_HANDLES = {
        { handle = "thsottiaux",    product = "codex",       name = "Tibo (@thsottiaux)" },
        { handle = "OpenAIDevs",    product = "codex",       name = "OpenAI Devs (@OpenAIDevs)" },
        { handle = "_mohansolo",    product = "antigravity", name = "Varun Mohan (@_mohansolo)" },
        { handle = "ClaudeDevs",    product = "claude",      name = "Claude Devs (@ClaudeDevs)" },
        { handle = "bcherny",       product = "claude",      name = "Boris Cherny (@bcherny)" },
        { handle = "claudeai",      product = "claude",      name = "Claude (@claudeai)" },
        { handle = "AnthropicAI",   product = "claude",      name = "Anthropic (@AnthropicAI)" },
        { handle = "bot",           product = "grok_bot",    name = "Grok Bot (@bot)" },
        { handle = "grok",          product = "grok",        name = "Grok (@grok)" },
        { handle = "elonmusk",      product = "grok",        name = "Elon Musk (@elonmusk)" },
        { handle = "qoder_ai_ide",  product = "qoder",       name = "Qoder (@qoder_ai_ide)" },
    }

    M.X_BEARER = "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"

    local X_USER_FEATURES = {
        hidden_profile_subscriptions_enabled = true,
        profile_label_improvements_pcf_label_in_post_enabled = true,
        responsive_web_profile_redirect_enabled = false,
        rweb_tipjar_consumption_enabled = true,
        verified_phone_label_enabled = false,
        subscriptions_verification_info_is_identity_verified_enabled = true,
        subscriptions_verification_info_verified_default_enabled = true,
        highlights_tweets_tab_ui_enabled = true,
        responsive_web_twitter_article_notes_tab_enabled = true,
        subscriptions_feature_can_gift_premium = true,
        creator_subscriptions_tweet_preview_api_enabled = true,
        responsive_web_graphql_skip_user_profile_image_extensions_enabled = false,
        responsive_web_graphql_timeline_navigation_enabled = true,
    }

    local X_TWEET_FEATURES = {
        rweb_video_screen_enabled = false,
        profile_label_improvements_pcf_label_in_post_enabled = true,
        responsive_web_profile_redirect_enabled = false,
        rweb_tipjar_consumption_enabled = true,
        verified_phone_label_enabled = false,
        creator_subscriptions_tweet_preview_api_enabled = true,
        responsive_web_graphql_timeline_navigation_enabled = true,
        responsive_web_graphql_skip_user_profile_image_extensions_enabled = false,
        premium_content_api_read_enabled = false,
        communities_web_enable_tweet_community_results_fetch = true,
        c9s_tweet_anatomy_moderator_badge_enabled = true,
        responsive_web_grok_analyze_button_fetch_trends_enabled = false,
        responsive_web_grok_analyze_post_followups_enabled = true,
        responsive_web_jetfuel_frame = true,
        responsive_web_grok_share_attachment_enabled = true,
        articles_preview_enabled = true,
        responsive_web_edit_tweet_api_enabled = true,
        graphql_is_translatable_rweb_tweet_is_translatable_enabled = true,
        view_counts_everywhere_api_enabled = true,
        longform_notetweets_consumption_enabled = true,
        responsive_web_twitter_article_tweet_consumption_enabled = true,
        tweet_awards_web_tipping_enabled = false,
        responsive_web_grok_show_grok_translated_post = false,
        responsive_web_grok_analysis_button_from_backend = true,
        creator_subscriptions_quote_tweet_preview_api_enabled = false,
        freedom_of_speech_not_reach_fetch_enabled = true,
        standardized_nudges_misinfo = true,
        tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled = true,
        longform_notetweets_rich_text_read_enabled = true,
        longform_notetweets_inline_media_enabled = true,
        responsive_web_grok_image_annotation_enabled = true,
        responsive_web_grok_imagine_annotation_enabled = true,
        responsive_web_grok_community_note_auto_translation_enabled = false,
        responsive_web_enhance_cards_enabled = false,
    }

    function M.x_api_headers(x_auth)
        return {
            ["User-Agent"] = common.UA,
            ["Accept"] = "*/*",
            ["Accept-Language"] = "en-US,en;q=0.9",
            ["Cookie"] = x_auth.cookie_header,
            ["X-Csrf-Token"] = x_auth.ct0,
            ["Authorization"] = M.X_BEARER,
            ["X-Twitter-Auth-Type"] = "OAuth2Session",
            ["X-Twitter-Active-User"] = "yes",
            ["Referer"] = "https://x.com/",
            ["Origin"] = "https://x.com",
        }
    end

    function M.build_x_targets(needed_products, fetch_all)
        local targets = {}
        if not common.cfg_bool("enable_x_cookie_sources", true) then
            return targets
        end
        local function need(prod)
            if fetch_all then return true end
            if not needed_products then return false end
            return needed_products[prod] == true
        end
        for _, item in ipairs(FXTWITTER_HANDLES) do
            local want = need(item.product)
            if not want and item.product == "grok" and need("grok_bot") then
                want = true
            end
            if want then
                targets[#targets + 1] = {
                    id = "xapi_" .. item.handle,
                    kind = "x_gql_tweets",
                    product = item.product,
                    name = item.name .. " (X Cookie 直连)",
                    handle = item.handle,
                    proxy = common.cfg_string("foreign_proxy", ""),
                }
            end
        end
        return targets
    end

    function M.extract_main_js_url(html)
        if type(html) ~= "string" then return nil end
        return html:match("https://abs%.twimg%.com/responsive%-web/client%-web/main%.[%w_%-]+%.js")
    end

    function M.extract_gql_query_ids(js_body)
        if type(js_body) ~= "string" then return {} end
        local qids = {}
        local wanted = {
            UserByScreenName = true,
            UserTweets = true,
            TweetResultByRestId = true,
        }
        for qid, op in js_body:gmatch('queryId%s*:%s*"([%w_%-]+)"%s*,%s*operationName%s*:%s*"([%w_]+)"') do
            if wanted[op] then qids[op] = qid end
        end
        if not qids.UserTweets or not qids.UserByScreenName then
            for op, qid in js_body:gmatch('operationName%s*:%s*"([%w_]+)"%s*,%s*queryId%s*:%s*"([%w_%-]+)"') do
                if wanted[op] and not qids[op] then qids[op] = qid end
            end
        end
        return qids
    end

    function M.build_user_by_screen_name_url(qid, handle)
        local vars = jn.json.encode({ screen_name = handle, withGrokTranslatedBio = false })
        local feats = jn.json.encode(X_USER_FEATURES)
        return "https://x.com/i/api/graphql/" .. qid .. "/UserByScreenName?variables="
            .. common.url_encode(vars) .. "&features=" .. common.url_encode(feats)
    end

    function M.build_user_tweets_url(qid, user_id, count)
        local vars = jn.json.encode({
            userId = tostring(user_id),
            count = count or 15,
            includePromotedContent = false,
            withQuickPromoteEligibilityTweetFields = false,
            withVoice = true,
        })
        local feats = jn.json.encode(X_TWEET_FEATURES)
        return "https://x.com/i/api/graphql/" .. qid .. "/UserTweets?variables="
            .. common.url_encode(vars) .. "&features=" .. common.url_encode(feats)
    end

    function M.build_tweet_detail_url(qid, tweet_id)
        local vars = jn.json.encode({
            tweetId = tostring(tweet_id),
            withCommunity = false,
            includePromotedContent = false,
            withVoice = false,
        })
        local feats = jn.json.encode(X_TWEET_FEATURES)
        return "https://x.com/i/api/graphql/" .. qid .. "/TweetResultByRestId?variables="
            .. common.url_encode(vars) .. "&features=" .. common.url_encode(feats)
    end

    function M.extract_x_user_rest_id(body)
        local ok, data = pcall(jn.json.decode, body)
        if not ok or type(data) ~= "table" then return nil end
        local res = data.data and data.data.user and data.data.user.result
        if type(res) == "table" and res.rest_id and res.rest_id ~= "" then
            return tostring(res.rest_id)
        end
        return nil
    end

    function M.extract_x_tweet_from_result(node)
        if type(node) ~= "table" then return nil end
        if node.__typename == "TweetWithVisibilityResults" and type(node.tweet) == "table" then
            node = node.tweet
        end
        local rid = node.rest_id
        local leg = node.legacy
        if not rid or type(leg) ~= "table" or type(leg.full_text) ~= "string" then
            return nil
        end
        -- 跳过纯转推，仅保留本人原创/引用/长文帖
        if leg.retweeted_status_result ~= nil then
            return nil
        end
        local text = leg.full_text
        local note = node.note_tweet and node.note_tweet.note_tweet_results and node.note_tweet.note_tweet_results.result
        if type(note) == "table" and type(note.text) == "string" and note.text ~= "" then
            text = note.text
        end
        local screen = ""
        local ur = node.core and node.core.user_results and node.core.user_results.result
        if type(ur) == "table" then
            screen = (ur.core and ur.core.screen_name) or (ur.legacy and ur.legacy.screen_name) or ""
        end
        return {
            id = tostring(rid),
            text = common.trim(text),
            created_at = tostring(leg.created_at or ""),
            ts = common.parse_timestamp(leg.created_at or "") or 0,
            screen_name = tostring(screen or ""),
        }
    end

    function M.parse_x_tweet_detail_json(body)
        local ok, data = pcall(jn.json.decode, body)
        if not ok or type(data) ~= "table" then return nil end
        local res = data.data and data.data.tweetResult and data.data.tweetResult.result
        return M.extract_x_tweet_from_result(res)
    end

    function M.parse_x_user_tweets_json(body, default_handle)
        local ok, data = pcall(jn.json.decode, body)
        if not ok or type(data) ~= "table" then return {} end
        local out, seen = {}, {}
        local function walk(v, depth)
            if type(v) ~= "table" or depth > 24 then return end
            if v.rest_id and type(v.legacy) == "table" and type(v.legacy.full_text) == "string" then
                local tw = M.extract_x_tweet_from_result(v)
                if tw and not seen[tw.id] then
                    -- 若接口返回带 screen_name 且与监控号不同（如他人的插入推文），跳过
                    if tw.screen_name == "" or not default_handle
                        or tw.screen_name:lower() == default_handle:lower() then
                        seen[tw.id] = true
                        out[#out + 1] = tw
                    end
                end
                return
            end
            for _, child in pairs(v) do
                if type(child) == "table" then
                    walk(child, depth + 1)
                end
            end
        end
        walk(data, 0)
        table.sort(out, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
        return out
    end

    local RESET_KEYWORDS = {
        "reset", "quota", "rate limit", "usage limit", "limit", "banked",
        "bonus", "allowance", "credit", "replenish", "refresh", "cap",
        "double", "doubled", "rollout", "tier", "weekly", "5%-hour", "5 hour",
        "重置", "额度", "限额", "重置卡", "翻倍", "补偿", "恢复",
    }

    function M.looks_like_reset_tweet(text, handle)
        local low = tostring(text or ""):lower()
        if low == "" then return false end
        for _, kw in ipairs(RESET_KEYWORDS) do
            if low:find(kw:lower(), 1, false) then
                return true
            end
        end
        return false
    end

    function M.extract_x_status_id(url_or_text)
        if not url_or_text or url_or_text == "" then return nil, nil end
        local s = tostring(url_or_text)
        local u, id = s:match("https?://[%w%.]*x%.com/([%w_]+)/status/(%d+)")
        if id then return id, "https://x.com/" .. u .. "/status/" .. id end
        u, id = s:match("https?://[%w%.]*twitter%.com/([%w_]+)/status/(%d+)")
        if id then return id, "https://x.com/" .. u .. "/status/" .. id end
        id = s:match("https?://[%w%.]*fxtwitter%.com/[%w_]+/status/(%d+)")
            or s:match("https?://[%w%.]*vxtwitter%.com/[%w_]+/status/(%d+)")
        if id then return id, "https://x.com/i/status/" .. id end
        return nil, nil
    end

    -- ----------------------------------------------------------------
    -- 构建本次轮询任务列表（按已订阅产品裁剪，减少无效请求）
    -- ----------------------------------------------------------------
    function M.build_source_list(needed_products, fetch_all)
        local sources = {}
        local fx_on = common.cfg_bool("enable_fxtwitter_sources", true)
        local agg_on = common.cfg_bool("enable_aggregator_sources", true)
        local st_on = common.cfg_bool("enable_status_sources", true)
        local f_proxy = common.cfg_string("foreign_proxy", "")
        local c_proxy = common.cfg_string("cn_proxy", "")

        local function need(prod)
            if fetch_all then return true end
            if not needed_products then return false end
            return needed_products[prod] == true
        end

        if fx_on then
            for _, item in ipairs(FXTWITTER_HANDLES) do
                local want = need(item.product)
                -- @elonmusk 偶发同时提及 grok_bot；订阅任一 grok* 时都监控
                if not want and item.product == "grok" and need("grok_bot") then
                    want = true
                end
                if want then
                    sources[#sources + 1] = {
                        id = "fx_" .. item.handle,
                        kind = "fx_rss",
                        product = item.product,
                        name = item.name,
                        url = "https://fxtwitter.com/" .. item.handle .. "/feed.xml",
                        proxy = f_proxy,
                        handle = item.handle,
                    }
                end
            end
        end

        if agg_on then
            -- whenaireset 覆盖多产品（含 GLM / Kimi / Gemini CLI / Cursor 与交叉核验）
            local need_any_reset = fetch_all
            if not need_any_reset and needed_products then
                for _, pk in ipairs(common.RESET_PRODUCTS) do
                    if needed_products[pk] then need_any_reset = true break end
                end
            end
            if need_any_reset then
                sources[#sources + 1] = {
                    id = "agg_whenaireset",
                    kind = "whenaireset_rss",
                    product = nil,
                    name = "WhenAIReset RSS",
                    url = "https://whenaireset.com/feed.xml",
                    proxy = f_proxy,
                }
            end
            if need("antigravity") then
                sources[#sources + 1] = {
                    id = "agg_agyresets",
                    kind = "agyresets_json",
                    product = "antigravity",
                    name = "AGY Resets API",
                    url = "https://agyresets.com/api/v1/status",
                    proxy = f_proxy,
                }
            end
            if need("codex") then
                sources[#sources + 1] = {
                    id = "agg_whenreset_codex",
                    kind = "whenreset_rss",
                    product = "codex",
                    name = "WhenReset Codex RSS",
                    url = "https://whenreset.dev/api/reset-feed?provider=codex",
                    proxy = f_proxy,
                }
            end
            if need("claude") then
                sources[#sources + 1] = {
                    id = "agg_whenreset_claude",
                    kind = "whenreset_rss",
                    product = "claude",
                    name = "WhenReset Claude RSS",
                    url = "https://whenreset.dev/api/reset-feed?provider=claude",
                    proxy = f_proxy,
                }
            end
            if need("grok") or need("grok_bot") then
                sources[#sources + 1] = {
                    id = "agg_whenreset_grok",
                    kind = "whenreset_rss",
                    product = "grok",
                    name = "WhenReset Grok RSS",
                    url = "https://whenreset.dev/api/reset-feed?provider=grok",
                    proxy = f_proxy,
                }
            end
        end

        if st_on then
            if need("openai_status") then
                sources[#sources + 1] = {
                    id = "status_openai",
                    kind = "status_rss",
                    product = "openai_status",
                    name = "OpenAI Status",
                    url = "https://status.openai.com/feed.rss",
                    proxy = f_proxy,
                }
            end
            if need("claude_status") then
                sources[#sources + 1] = {
                    id = "status_claude",
                    kind = "status_rss",
                    product = "claude_status",
                    name = "Claude Status",
                    url = "https://status.claude.com/history.rss",
                    proxy = f_proxy,
                }
            end
            if need("deepseek_status") then
                local primary_ds = common.cfg_bool("deepseek_try_official_first", true)
                sources[#sources + 1] = {
                    id = "status_deepseek",
                    kind = primary_ds and "deepseek_official_rss" or "deepseek_entireweb",
                    product = "deepseek_status",
                    name = primary_ds and "DeepSeek Status (Official)" or "DeepSeek Status (Entireweb)",
                    url = primary_ds
                        and "https://status.deepseek.com/history.rss"
                        or "https://www.entireweb.com/zh-cn/status/deepseek",
                    fallback_urls = primary_ds and {
                        { kind = "deepseek_official_rss", url = "https://status.deepseek.com/feed.rss", proxy = c_proxy },
                        { kind = "deepseek_entireweb", url = "https://www.entireweb.com/zh-cn/status/deepseek", proxy = f_proxy ~= "" and f_proxy or c_proxy },
                    } or nil,
                    proxy = primary_ds and c_proxy or (f_proxy ~= "" and f_proxy or c_proxy),
                }
            end
        end

        -- 自定义扩展 RSS / Atom 源（参考 juya，支持 RSSHub 等多源）
        for idx, line in ipairs(common.cfg_list("extra_rss_feeds")) do
            local pkey, url = line:match("^([%w_%-]+)|(https?://.+)$")
            local mapped = nil
            if pkey and url then
                mapped = common.norm_product(pkey)
            else
                url = line
            end
            if url:match("^https?://") and (not mapped or need(mapped)) then
                sources[#sources + 1] = {
                    id = "extra_" .. tostring(idx) .. "_" .. common.fnv1a_hex(url),
                    kind = "custom_rss",
                    product = mapped,
                    name = "Custom RSS #" .. tostring(idx),
                    url = url,
                    -- 内网地址（localhost/127.0.0.1/172.x/10.x/192.168.x/rsshub）不走海外代理
                    proxy = (url:find("127%.0%.0%.1") or url:find("localhost")
                        or url:find("172%.") or url:find("10%.") or url:find("192%.168%.")
                        or url:find("rsshub:")) and "" or f_proxy,
                }
            end
        end

        return sources
    end

    -- ----------------------------------------------------------------
    -- RSS 2.0 / Atom XML 解析（提取前 N 条）
    -- ----------------------------------------------------------------
    local function extract_tag(seg, tag)
        local v = seg:match("<" .. tag .. "[^>]->%s*<!%[CDATA%[(.-)%]%]>%s*</" .. tag .. ">")
        if v then return common.trim(v) end
        v = seg:match("<" .. tag .. "[^>]->(.-)</" .. tag .. ">")
        if v then return common.unescape(common.trim(v)) end
        return ""
    end

    function M.parse_feed_xml(xml, max_items)
        if type(xml) ~= "string" or xml == "" then return {} end
        max_items = max_items or 15
        local items = {}

        -- 优先尝试 RSS 2.0 <item>
        local is_atom = false
        local pat = "<item[%s>](.-)</item>"
        if not xml:find("<item[%s>]", 1) and xml:find("<entry[%s>]", 1) then
            is_atom = true
            pat = "<entry[%s>](.-)</entry>"
        end

        for seg in xml:gmatch(pat) do
            local title = common.clean_html(extract_tag(seg, "title"))
            local link = extract_tag(seg, "link")
            if link == "" or is_atom then
                local href = seg:match('<link[^>]-rel="alternate"[^>]-href="([^"]+)"')
                    or seg:match('<link[^>]-href="([^"]+)"')
                if href and href ~= "" then link = common.unescape(href) end
            end
            local guid = extract_tag(seg, is_atom and "id" or "guid")
            local pub = extract_tag(seg, is_atom and "published" or "pubDate")
            if pub == "" then pub = extract_tag(seg, "updated") end
            if pub == "" then pub = extract_tag(seg, "dc:date") end

            local desc_raw = extract_tag(seg, "content:encoded")
            if desc_raw == "" then desc_raw = extract_tag(seg, "description") end
            if desc_raw == "" then desc_raw = extract_tag(seg, is_atom and "content" or "summary") end
            if desc_raw == "" and is_atom then desc_raw = extract_tag(seg, "summary") end
            local desc = common.clean_html(desc_raw)

            local x_id, x_url = M.extract_x_status_id(link .. " " .. desc_raw)
            local ts = common.parse_timestamp(pub) or 0

            items[#items + 1] = {
                title = title,
                link = common.trim(link),
                guid = guid ~= "" and guid or link,
                pub_raw = pub,
                ts = ts,
                desc = desc,
                desc_raw = desc_raw,
                x_status_id = x_id,
                x_status_url = x_url,
            }
            if #items >= max_items then break end
        end

        return items
    end

    -- ----------------------------------------------------------------
    -- 从具体源结果构造统一候选事件列表
    -- ----------------------------------------------------------------
    local function map_whenaireset_product(title, desc)
        local tag = tostring(title or ""):match("^%[([^%]]+)%]") or ""
        local tlow = tag:lower()
        local dlow = (tostring(title or "") .. " " .. tostring(desc or "")):lower()
        if tlow:find("codex", 1, true) then return "codex" end
        if tlow:find("antigravity", 1, true) then return "antigravity" end
        if tlow:find("claude", 1, true) then return "claude" end
        if tlow:find("grok", 1, true) then
            if dlow:find("grok bot", 1, true) or dlow:find("@bot", 1, true) then
                return "grok_bot"
            end
            return "grok"
        end
        if tlow:find("glm", 1, true) then return "glm" end
        if tlow:find("qoder", 1, true) then return "qoder" end
        if tlow:find("kimi", 1, true) then return "kimi" end
        if tlow:find("gemini", 1, true) then return "gemini_cli" end
        if tlow:find("cursor", 1, true) then return "cursor" end
        return nil
    end

    local function infer_whenaireset_kind(title)
        local tlow = tostring(title or ""):lower()
        if tlow:find("direct reset", 1, true) then return "direct_reset", true end
        if tlow:find("banked reset", 1, true) or tlow:find("reset card", 1, true) then return "banked_reset", true end
        if tlow:find("scheduled", 1, true) or tlow:find("upcoming", 1, true) then return "scheduled_reset", false end
        if tlow:find("rule change", 1, true) then return "rule_change", false end
        return nil, false
    end

    local function infer_status_stage(text)
        local low = tostring(text or ""):lower()
        if low:find("resolved", 1, true) or low:find("已恢复", 1, true) then
            return "status_resolved", false
        end
        local is_major = low:find("major outage", 1, true) ~= nil
            or low:find("critical", 1, true) ~= nil
            or low:find("all models", 1, true) ~= nil
            or low:find("全面中断", 1, true) ~= nil
        return "status_incident", is_major
    end

    function M.extract_candidates(src, body, needed_products, include_unsubscribed)
        local candidates = {}

        local function wants(prod)
            if include_unsubscribed then return true end
            if not prod then return true end
            return needed_products and needed_products[prod] == true
        end

        if src.kind == "agyresets_json" then
            local ok, data = pcall(jn.json.decode, body)
            if not ok or type(data) ~= "table" or type(data.data) ~= "table" then
                return candidates
            end
            local d = data.data
            local function push_agy(node, kind_override, is_sched)
                if type(node) ~= "table" then return end
                local id = tostring(node.id or "")
                local src_url = (type(node.source) == "table" and node.source.url) or ""
                local xid, xurl = M.extract_x_status_id(src_url)
                if not xid and id ~= "" and id:match("^%d+$") then
                    xid = id
                    xurl = src_url ~= "" and src_url or ("https://x.com/_mohansolo/status/" .. id)
                end
                local ts = common.parse_timestamp(node.announced_at or node.scheduled_for or "") or 0
                local text = common.trim(node.text or "")
                if text == "" and not is_sched then return end
                local ev_key = xid and ("x:" .. xid) or ("agy:" .. id .. ":" .. tostring(ts))
                candidates[#candidates + 1] = {
                    event_key = ev_key,
                    product = "antigravity",
                    event_kind = kind_override or (is_sched and "scheduled_reset" or "direct_reset"),
                    is_major = not is_sched,
                    source_name = "AGY Resets / @_mohansolo",
                    source_url = xurl ~= "" and xurl or src.url,
                    x_status_id = xid,
                    title = is_sched and "Antigravity 官方预告即将重置" or "Antigravity 额度重置公告",
                    raw_text = text,
                    announced_ts = ts,
                    preverified_structured = true,
                }
            end
            push_agy(d.latest_reset, nil, false)
            if type(d.scheduled_reset) == "table" then
                push_agy(d.scheduled_reset, "scheduled_reset", true)
            end
            return candidates
        end

        if src.kind == "deepseek_entireweb" then
            local clean = common.clean_html(body)
            local pos = clean:find("首页 › DeepSeek", 1, true)
                or clean:find("DeepSeek 当前", 1, true)
                or clean:find("DeepSeek", 1, true)
                or 1
            -- 只取顶部状态卡片区域，避免页面底部 FAQ 科普里的“故障/中断”字眼误触发
            local hero = clean:sub(pos, pos + 1500)
            local h1 = tonumber(
                hero:match("其中%s*(%d+)%s*次是在过去一小时")
                or hero:match("(%d+)%s*已报告的问题%s*最近 1 小时")
                or hero:match("最近 1 小时%s*(%d+)")
                or hero:match("(%d+)%s*reported problems%s*last hour")
                or clean:match("状态 Operational.-最近 1 小时%s*(%d+)")
            ) or 0
            local h24 = tonumber(
                hero:match("共收到%s*(%d+)%s*次用户报告")
                or hero:match("(%d+)%s*已报告的问题%s*最近 24 小时")
                or hero:match("最近 24 小时%s*(%d+)")
            ) or 0
            local is_normal = (hero:find("当前运行正常", 1, true) ~= nil)
                or (hero:find("运行一切顺利", 1, true) ~= nil)
                or (hero:find("未检测到任何进行中的故障", 1, true) ~= nil)
                or (clean:find("状态 Operational", 1, true) ~= nil)
            local explicit_down = (not is_normal) and (
                hero:find("可能存在问题", 1, true) ~= nil
                or hero:find("检测到故障", 1, true) ~= nil
                or hero:find("目前正经历", 1, true) ~= nil
                or hero:find("Possible problems", 1, true) ~= nil
                or hero:find("Major Outage", 1, true) ~= nil
            )
            local thresh = common.cfg_num("deepseek_entireweb_threshold", 50)
            local unhealthy = explicit_down or (not is_normal) or (h1 >= thresh)
            local state_tag = unhealthy and "outage" or "normal"
            candidates[#candidates + 1] = {
                event_key = "ds_entireweb_state:" .. state_tag,
                product = "deepseek_status",
                event_kind = unhealthy and "status_incident" or "status_resolved",
                is_major = unhealthy and (h1 >= thresh * 2 or explicit_down),
                source_name = "Entireweb DeepSeek 监控",
                source_url = src.url,
                title = unhealthy and "DeepSeek 服务状态异常（Entireweb 监测）" or "DeepSeek 服务运行正常（Entireweb 监测）",
                raw_text = string.format(
                    "页面状态=%s；最近1小时用户报告=%d（告警阈值=%d）；最近24小时报告=%d",
                    unhealthy and "异常/故障上升" or "运行正常",
                    h1, thresh, h24
                ),
                announced_ts = os.time(),
                entireweb_state = state_tag,
                skip_unless_state_changed = true,
            }
            return candidates
        end

        if src.kind == "x_gql_tweets" then
            local tweets = M.parse_x_user_tweets_json(body, src.handle)
            for _, tw in ipairs(tweets) do
                if M.looks_like_reset_tweet(tw.text, src.handle) then
                    local prod = src.product
                    if prod == "grok" and tw.text:lower():find("grok bot", 1, true) then
                        prod = "grok_bot"
                    end
                    if wants(prod) then
                        local handle_use = tw.screen_name ~= "" and tw.screen_name or src.handle
                        candidates[#candidates + 1] = {
                            event_key = "x:" .. tw.id,
                            product = prod,
                            source_name = src.name,
                            source_url = "https://x.com/" .. tostring(handle_use) .. "/status/" .. tw.id,
                            x_status_id = tw.id,
                            title = common.clip(tw.text, 120),
                            raw_text = tw.text,
                            announced_ts = tw.ts,
                        }
                    end
                end
            end
            return candidates
        end

        -- 通用 RSS / Atom（fx_rss, whenaireset_rss, whenreset_rss, status_rss, deepseek_official_rss, custom_rss）
        local items = M.parse_feed_xml(body, 15)
        for _, it in ipairs(items) do
            if src.kind == "fx_rss" then
                local combined = (it.title ~= "" and (it.title .. "\n") or "") .. it.desc
                if M.looks_like_reset_tweet(combined, src.handle) then
                    local xid = it.x_status_id or common.fnv1a_hex(it.guid or it.link or combined)
                    local prod = src.product
                    -- @elonmusk 发推如明确提 Grok Bot 则归为 grok_bot
                    if prod == "grok" and combined:lower():find("grok bot", 1, true) then
                        prod = "grok_bot"
                    end
                    if wants(prod) then
                        candidates[#candidates + 1] = {
                            event_key = "x:" .. tostring(xid),
                            product = prod,
                            source_name = src.name,
                            source_url = it.x_status_url or it.link,
                            x_status_id = it.x_status_id,
                            title = common.clip(it.title ~= "" and it.title or combined, 120),
                            raw_text = combined,
                            announced_ts = it.ts,
                        }
                    end
                end
            elseif src.kind == "whenreset_rss" then
                local xid = it.x_status_id
                local ev_key = xid and ("x:" .. xid) or ("wr:" .. src.product .. ":" .. common.fnv1a_hex(it.guid .. it.title))
                local prod = src.product
                local combined = it.title .. "\n" .. it.desc
                if prod == "grok" and combined:lower():find("grok bot", 1, true) then
                    prod = "grok_bot"
                end
                if wants(prod) then
                    candidates[#candidates + 1] = {
                        event_key = ev_key,
                        product = prod,
                        source_name = src.name,
                        source_url = it.x_status_url or it.link,
                        x_status_id = xid,
                        title = it.title,
                        raw_text = combined,
                        announced_ts = it.ts,
                        needs_x_lookup = (xid ~= nil),
                    }
                end
            elseif src.kind == "whenaireset_rss" then
                local prod = map_whenaireset_product(it.title, it.desc)
                local kind_hint, major_hint = infer_whenaireset_kind(it.title)
                if prod and kind_hint and wants(prod) then
                    local slug_key = "war:" .. prod .. ":" .. kind_hint .. ":" .. tostring(math.floor((it.ts or 0) / 60)) .. ":" .. common.fnv1a_hex(it.link .. "|" .. it.title)
                    candidates[#candidates + 1] = {
                        event_key = it.x_status_id and ("x:" .. it.x_status_id) or slug_key,
                        product = prod,
                        event_kind = kind_hint,
                        is_major = major_hint,
                        source_name = "WhenAIReset",
                        source_url = it.x_status_id and it.x_status_url or it.link,
                        x_status_id = it.x_status_id,
                        title = it.title,
                        raw_text = it.title .. "\n" .. it.desc,
                        announced_ts = it.ts,
                        preverified_structured = true,
                    }
                end
            elseif src.kind == "status_rss" or src.kind == "deepseek_official_rss" then
                if wants(src.product) then
                    local combined = it.title .. "\n" .. it.desc
                    local st_kind, is_maj = infer_status_stage(combined)
                    -- 关键：同一故障每次阶段推进（Investigating→Identified→Monitoring→Resolved）都有新 pubDate / 新 description，
                    -- 因此 hash(guid + desc前缀 + pub) 可以精确做到「每阶段推进都推送一次，未变不重复」
                    local stage_sig = common.fnv1a_hex((it.guid or it.link) .. "|" .. it.pub_raw .. "|" .. common.clip(it.desc, 160))
                    candidates[#candidates + 1] = {
                        event_key = "st:" .. src.product .. ":" .. stage_sig,
                        product = src.product,
                        event_kind = st_kind,
                        is_major = is_maj,
                        source_name = src.name,
                        source_url = it.link ~= "" and it.link or src.url,
                        title = it.title,
                        raw_text = combined,
                        announced_ts = it.ts,
                        preverified_structured = true,
                    }
                end
            elseif src.kind == "custom_rss" then
                local combined = (it.title ~= "" and (it.title .. "\n") or "") .. it.desc
                -- 如果用户没在 URL 前指定产品键，则先按关键词筛一波再交给 LLM 判别
                if src.product or M.looks_like_reset_tweet(combined, "") then
                    local xid = it.x_status_id
                    local ev_key = xid and ("x:" .. xid)
                        or ("custom:" .. common.fnv1a_hex(src.url .. "|" .. (it.guid or it.link) .. "|" .. it.pub_raw))
                    candidates[#candidates + 1] = {
                        event_key = ev_key,
                        product = src.product,
                        source_name = src.name,
                        source_url = it.x_status_url or it.link,
                        x_status_id = xid,
                        title = it.title,
                        raw_text = combined,
                        announced_ts = it.ts,
                    }
                end
            end
        end

        return candidates
    end

    return M
end
