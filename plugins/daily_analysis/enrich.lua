-- enrich.lua — 无水印/降级开源项目补全（缓存桥 → 本地缓存 → 元数据+README 批量 LLM）

return function(jn, common, sources)
    local M = {}

    local HF_PROXY = "socks5://172.27.0.1:20170"
    local INTRO_CACHE = "http://172.27.0.1:5284/repo-intro"

    local function trim(s)
        s = tostring(s or "")
        return (s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
    end

    local function fmt_k(n)
        n = tonumber(n) or 0
        if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
        if n >= 1000 then return string.format("%.1fk", n / 1000) end
        return tostring(n)
    end

    local function repo_intro_cache(r)
        local encoded = r.name:gsub("[^%w%-_%.]", function(c)
            return string.format("%%%02X", c:byte())
        end)
        local res = jn.http.get(INTRO_CACHE .. "?repo=" .. encoded, "")
        if not (res and res.status == 200) then return nil end
        local d = jn.json.decode(res.body)
        if type(d) == "table" and ((d.summary and d.summary ~= "") or (d.desc_cn and d.desc_cn ~= "")) then
            return d
        end
        return nil
    end

    local function fetch_github(r)
        local res, herr = jn.http.get("https://api.github.com/repos/" .. r.name, "")
        if res and res.status == 404 then
            r.invalid = true
            jn.log.warn(string.format("[%s] GitHub 仓库 404，已剔除 %s", common.PLUGIN_NAME, r.name))
            return "", ""
        end
        if not (res and res.status == 200) then
            jn.log.warn(string.format("[%s] GitHub 简介获取失败 %s status=%s err=%s",
                common.PLUGIN_NAME, r.name, tostring(res and res.status), tostring(herr)))
            return "", ""
        end
        local raw_desc, summary, readme = "", "", ""
        local d = jn.json.decode(res.body)
        if type(d) == "table" then
            raw_desc = trim(d.description)
            local meta = {}
            if trim(d.language) ~= "" then meta[#meta + 1] = d.language end
            if tonumber(d.stargazers_count) then meta[#meta + 1] = "⭐ " .. fmt_k(d.stargazers_count) end
            summary = raw_desc
            if #meta > 0 then
                summary = (summary ~= "" and (summary .. " ") or "") .. "（" .. table.concat(meta, " · ") .. "）"
            end
            if summary == "" and type(d.topics) == "table" then
                local tags = {}
                for i = 1, math.min(4, #d.topics) do tags[#tags + 1] = tostring(d.topics[i]) end
                if #tags > 0 then summary = "标签：" .. table.concat(tags, ", ") end
            end
        end
        local rres = jn.http.get("https://api.github.com/repos/" .. r.name .. "/readme", "")
        if rres and rres.status == 200 then
            local rd = jn.json.decode(rres.body)
            if type(rd) == "table" and type(rd.content) == "string" then
                readme = common.clip(common.b64_decode(rd.content), 8000)
            end
        end
        return raw_desc, summary, readme
    end

    local function fetch_hf(r, proxy)
        local is_ds = r.url:find("/datasets/", 1, true) ~= nil
        local api = is_ds and ("https://huggingface.co/api/datasets/" .. r.name)
            or ("https://huggingface.co/api/models/" .. r.name)
        local res, herr = jn.http.get(api, proxy)
        if res and res.status == 404 then
            r.invalid = true
            jn.log.warn(string.format("[%s] HF 仓库 404，已剔除 %s", common.PLUGIN_NAME, r.name))
            return "", ""
        end
        if not (res and res.status == 200) then
            jn.log.warn(string.format("[%s] HF 简介获取失败 %s status=%s err=%s",
                common.PLUGIN_NAME, r.name, tostring(res and res.status), tostring(herr)))
            return "", ""
        end
        local raw_desc, summary, readme = "", "", ""
        local d = jn.json.decode(res.body)
        if type(d) == "table" then
            local head = trim(d.pipeline_tag)
            if head == "" and type(d.tags) == "table" then
                local tags = {}
                for i = 1, math.min(3, #d.tags) do tags[#tags + 1] = tostring(d.tags[i]) end
                head = table.concat(tags, ", ")
            end
            raw_desc = head
            local meta = {}
            if tonumber(d.downloads) then meta[#meta + 1] = "⬇ " .. fmt_k(d.downloads) end
            if tonumber(d.likes) then meta[#meta + 1] = "♥ " .. fmt_k(d.likes) end
            summary = head
            if #meta > 0 then
                summary = (summary ~= "" and (summary .. " · ") or "") .. table.concat(meta, " · ")
            end
        end
        local sub = is_ds and "datasets/" or ""
        local rres = jn.http.get("https://huggingface.co/" .. sub .. r.name .. "/raw/main/README.md", proxy)
        if rres and rres.status == 200 and type(rres.body) == "string" then
            readme = common.clip(rres.body, 8000)
        end
        return raw_desc, summary, readme
    end

    local function fetch_ms(r)
        local sub = r.url:find("/datasets/", 1, true) and "datasets" or "models"
        local res = jn.http.get("https://modelscope.cn/api/v1/" .. sub .. "/" .. r.name, "")
        if res and res.status == 404 then
            r.invalid = true
            return "", ""
        end
        if res and res.status == 200 then
            local d = jn.json.decode(res.body)
            local dd = type(d) == "table" and (d.Data or d) or nil
            if type(dd) == "table" then
                local raw_desc = trim(dd.Description or dd.ChineseName or "")
                return raw_desc, raw_desc, common.clip(tostring(dd.ReadmeContent or ""), 8000)
            end
        end
        return "", "", ""
    end

    local function enrich_one(r)
        local cache_key = "repoinfo:v4:" .. r.key
        local llm_cache_key = "da:repo_sum:v1:" .. r.key

        local ri = repo_intro_cache(r)
        if ri then
            r.ri = ri
            r.summary = trim(ri.summary)
            if r.summary == "" then r.summary = trim(ri.desc_cn) end
            jn.cache.set(cache_key, { summary = r.summary, ri = ri }, 604800)
            return
        end

        local lcached = jn.cache.get(llm_cache_key)
        if type(lcached) == "table" and ((lcached.summary and lcached.summary ~= "") or (lcached.title and lcached.title ~= "")) then
            r.ri = lcached
            r.summary = trim(lcached.summary)
            return
        end

        local cached = jn.cache.get(cache_key)
        if type(cached) == "table" and cached.invalid then
            r.invalid = true
            return
        end
        if type(cached) == "table" and cached.ri
            and ((cached.ri.summary and cached.ri.summary ~= "") or (cached.ri.desc_cn and cached.ri.desc_cn ~= "")) then
            r.ri = cached.ri
            r.summary = trim(cached.summary)
            return
        end

        local raw_desc, summary, readme = "", "", ""
        if r.kind == "github" then
            raw_desc, summary, readme = fetch_github(r)
        elseif r.kind == "hf" then
            raw_desc, summary, readme = fetch_hf(r, HF_PROXY)
        elseif r.kind == "ms" then
            raw_desc, summary, readme = fetch_ms(r)
        end

        if r.invalid then
            jn.cache.set(cache_key, { summary = "", invalid = true }, 604800)
            return
        end
        r.raw_desc = raw_desc
        r.readme = readme
        if summary ~= "" then r.summary = summary end
        r.need_llm = (raw_desc ~= "" or readme ~= "")
        jn.cache.set(cache_key, { summary = summary, invalid = false }, summary ~= "" and 604800 or 86400)
    end

    local function build_repo_batches(list)
        local batches = {}
        local sys = [[你是开源项目介绍助手。用户会给你若干个（GitHub / Hugging Face / ModelScope）仓库的官方简介与 README 摘录，请为每个仓库写出简体中文介绍并严格返回 JSON：
{"repos":[{"index":1,"title":"简短中文定位标题(≤30字)","desc_cn":"官方简介的简体中文翻译(≤60字，无简介则空字符串)","summary":"100~300字简体中文介绍：讲清是什么、核心功能/能力、支持哪些工具或关键用法；只依据提供的元数据与 README，禁止编造数据或写空话套话"}]}]]
        for start = 1, #list, 4 do
            local chunk, parts = {}, {}
            for k = start, math.min(start + 3, #list) do
                local r = list[k]
                chunk[#chunk + 1] = r
                local block = {
                    string.format("【仓库 %d】%s (%s)", #chunk, r.name, r.url or ""),
                    "官方简介：" .. (r.raw_desc or ""),
                }
                if r.readme and r.readme ~= "" then
                    block[#block + 1] = "README 摘录：\n" .. r.readme
                end
                parts[#parts + 1] = table.concat(block, "\n")
            end
            batches[#batches + 1] = { chunk = chunk, sys = sys, user = table.concat(parts, "\n\n") }
        end
        return batches
    end

    local function apply_repo_batch(chunk, obj)
        if not (obj and type(obj.repos) == "table") then return end
        for _, item in ipairs(obj.repos) do
            if type(item) == "table" and item.index then
                local r = chunk[tonumber(item.index)]
                if r then
                    local title = trim(item.title or "")
                    local desc_cn = trim(item.desc_cn or "")
                    local sum = tostring(item.summary or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if title ~= "" or sum ~= "" then
                        r.ri = { title = title, desc_cn = desc_cn, summary = sum }
                        r.summary = sum
                        jn.cache.set("da:repo_sum:v1:" .. r.key, r.ri, 604800)
                    end
                end
            end
        end
    end

    local function summarize_missing_repos(list)
        if #list == 0 or not (jn.llm and jn.llm.chat) then return end
        local timeout = math.max(30, common.da_num("llm_timeout", 360))
        for _, b in ipairs(build_repo_batches(list)) do
            local obj = nil
            for attempt = 1, 2 do
                local resp, err = jn.llm.chat({
                    { role = "system", content = b.sys },
                    { role = "user", content = b.user },
                }, { timeout = timeout })
                if not err and resp and resp ~= "" then
                    obj = common.decode_llm_json(resp, "项目补全")
                    if obj and type(obj.repos) == "table" then break end
                else
                    jn.log.warn(string.format("[%s] 无水印项目总结失败(第 %d 次): %s",
                        common.PLUGIN_NAME, attempt, tostring(err or "空响应")))
                end
            end
            apply_repo_batch(b.chunk, obj)
        end
    end

    local function run_async_batches(batches, idx, attempt, tag, list_field, apply_fn, on_done)
        if idx > #batches then
            on_done()
            return
        end
        local b = batches[idx]
        local timeout = math.max(30, common.da_num("llm_timeout", 360))
        common.llm_chat_async({
            { role = "system", content = b.sys },
            { role = "user", content = b.user },
        }, { timeout = timeout }, function(resp, err)
            local obj = nil
            if not err and resp and resp ~= "" then
                obj = common.decode_llm_json(resp, tag)
            else
                jn.log.warn(string.format("[%s] %s失败(第 %d 次): %s",
                    common.PLUGIN_NAME, tag, attempt, tostring(err or "空响应")))
            end
            if obj and type(obj[list_field]) == "table" then
                pcall(apply_fn, b.chunk, obj)
                run_async_batches(batches, idx + 1, 1, tag, list_field, apply_fn, on_done)
            elseif attempt < 2 then
                run_async_batches(batches, idx, attempt + 1, tag, list_field, apply_fn, on_done)
            else
                run_async_batches(batches, idx + 1, 1, tag, list_field, apply_fn, on_done)
            end
        end)
    end

    local function collect_need_llm_repos(repos)
        local need_llm = {}
        for _, r in ipairs(repos or {}) do
            if not r.text and ((r.summary or "") == "" or r.degraded) then
                pcall(enrich_one, r)
                if not r.invalid and not r.ri and r.need_llm then
                    need_llm[#need_llm + 1] = r
                end
            end
        end
        return need_llm
    end

    function M.enrich_repos(repos)
        if not repos or #repos == 0 then return end
        local need_llm = collect_need_llm_repos(repos)
        if #need_llm > 0 then
            jn.log.info(string.format("[%s] 补全总结 %d 个无水印开源项目", common.PLUGIN_NAME, #need_llm))
            pcall(summarize_missing_repos, need_llm)
        end
    end

    function M.enrich_repos_async(repos, on_done)
        on_done = on_done or function() end
        if not repos or #repos == 0 then on_done(); return end
        local need_llm = collect_need_llm_repos(repos)
        if #need_llm == 0 or not (jn.llm and (jn.llm.chat_async or jn.llm.chat)) then
            on_done()
            return
        end
        jn.log.info(string.format("[%s] 补全总结 %d 个无水印开源项目", common.PLUGIN_NAME, #need_llm))
        run_async_batches(build_repo_batches(need_llm), 1, 1, "项目补全", "repos", apply_repo_batch, on_done)
    end

    -- ========================================================================
    -- 公众号文章补全（浏览器 UA 异步抓取 + 正文解析 + LLM 摘要）
    -- ========================================================================

    M.WX_HEADERS = {
        ["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        ["Referer"] = "https://mp.weixin.qq.com/",
        ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
    }

    local function utf8_char(cp)
        cp = tonumber(cp) or 0
        if cp <= 0 or cp > 0x10FFFF then return "" end
        if cp < 0x80 then return string.char(cp) end
        if cp < 0x800 then
            return string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
        end
        if cp < 0x10000 then
            return string.char(
                0xE0 + math.floor(cp / 4096),
                0x80 + (math.floor(cp / 64) % 64),
                0x80 + (cp % 64)
            )
        end
        return string.char(
            0xF0 + math.floor(cp / 262144),
            0x80 + (math.floor(cp / 4096) % 64),
            0x80 + (math.floor(cp / 64) % 64),
            0x80 + (cp % 64)
        )
    end

    local function decode_html_entities(s)
        s = tostring(s or "")
        if s == "" then return "" end
        local named = {
            amp = "&", lt = "<", gt = ">", quot = "\"",
            apos = "'", nbsp = " ", mdash = "—", ndash = "–",
            hellip = "…", lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”",
        }
        s = s:gsub("&([%a]+);", function(name)
            return named[name] or ("&" .. name .. ";")
        end)
        s = s:gsub("&#(%d+);", function(num)
            return utf8_char(tonumber(num))
        end)
        s = s:gsub("&#[xX]([%da-fA-F]+);", function(hex)
            return utf8_char(tonumber(hex, 16))
        end)
        return s
    end

    local function unescape_js_str(s)
        s = tostring(s or "")
        if s == "" then return "" end
        s = s:gsub("\\x([%da-fA-F][%da-fA-F])", function(h)
            return string.char(tonumber(h, 16))
        end)
        s = s:gsub("\\u([%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F])", function(h)
            return utf8_char(tonumber(h, 16))
        end)
        s = s:gsub("\\n", "\n"):gsub("\\r", ""):gsub("\\t", " ")
        s = s:gsub('\\"', '"'):gsub("\\'", "'"):gsub("\\/", "/"):gsub("\\\\", "\\")
        return s
    end

    local function html_to_text(html)
        html = tostring(html or "")
        if html == "" then return "" end
        html = html:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]>", " ")
        html = html:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]>", " ")
        html = html:gsub("<[nN][oO][sS][cC][rR][iI][pP][tT][^>]*>.-</[nN][oO][sS][cC][rR][iI][pP][tT]>", " ")
        html = html:gsub("<[bB][rR]%s*/?>", "\n")
        html = html:gsub("</[pP]>", "\n")
        html = html:gsub("</[dD][iI][vV]>", "\n")
        html = html:gsub("</[hH][1-6]>", "\n")
        html = html:gsub("</[lL][iI]>", "\n")
        html = html:gsub("</[tT][rR]>", "\n")
        html = html:gsub("<[^>]+>", " ")
        html = decode_html_entities(html)
        local lines = {}
        for line in (html .. "\n"):gmatch("([^\n]*)\n") do
            local clean = trim(line)
            if clean ~= "" then lines[#lines + 1] = clean end
        end
        return table.concat(lines, "\n")
    end

    local function extract_meta(html, key)
        local lk = key:lower()
        for tag in html:gmatch("<[mM][eE][tT][aA]%s+([^>]+)>") do
            local ltag = tag:lower()
            if ltag:find('property="' .. lk .. '"', 1, true)
                or ltag:find("property='" .. lk .. "'", 1, true)
                or ltag:find('name="' .. lk .. '"', 1, true)
                or ltag:find("name='" .. lk .. "'", 1, true) then
                local content = tag:match('[cC][oO][nN][tT][eE][nN][tT]%s*=%s*"([^"]*)"')
                    or tag:match("[cC][oO][nN][tT][eE][nN][tT]%s*=%s*'([^']*)'")
                if content and content ~= "" then
                    return trim(decode_html_entities(content))
                end
            end
        end
        return ""
    end

    local function extract_div_by_id(html, target_id)
        local start_pos
        local patterns = {
            'id%s*=%s*"' .. target_id .. '"',
            "id%s*=%s*'" .. target_id .. "'",
        }
        for _, pat in ipairs(patterns) do
            local p = html:find(pat)
            if p then
                local tag_start = html:sub(1, p):match(".*()<[dD][iI][vV]%s")
                    or html:sub(1, p):match(".*()<[a-zA-Z]+%s")
                if tag_start then
                    start_pos = tag_start
                    break
                end
            end
        end
        if not start_pos then return "" end
        local open_end = html:find(">", start_pos)
        if not open_end then return "" end
        local tag_name = html:sub(start_pos + 1, open_end):match("^([%a]+)") or "div"
        local ltag = tag_name:lower()
        if ltag ~= "div" then
            local close_pos = html:find("</" .. tag_name .. "%s*>", open_end + 1)
            return close_pos and html:sub(open_end + 1, close_pos - 1) or ""
        end
        local depth = 1
        local pos = open_end + 1
        while pos <= #html do
            local next_open = html:find("<[dD][iI][vV][%s>]", pos)
            local next_close, next_close_end = html:find("</[dD][iI][vV]%s*>", pos)
            if not next_close then break end
            if next_open and next_open < next_close then
                depth = depth + 1
                pos = next_open + 4
            else
                depth = depth - 1
                if depth == 0 then
                    return html:sub(open_end + 1, next_close - 1)
                end
                pos = next_close_end + 1
            end
        end
        return ""
    end

    local function extract_js_string_field(html, field)
        local patterns = {
            "['\"]?" .. field .. "['\"]?%s*:%s*(%a*)%s*(['\"])",
            "var%s+" .. field .. "%s*=%s*(%a*)%s*(['\"])",
        }
        for _, pat in ipairs(patterns) do
            local idx = 1
            while true do
                local s, e, fn_wrap, quote = html:find(pat, idx)
                if not s then break end
                if fn_wrap == "" or fn_wrap == "JsDecode" then
                    local buf, i = {}, e + 1
                    local closed = false
                    while i <= #html do
                        local ch = html:sub(i, i)
                        if ch == "\\" and i < #html then
                            buf[#buf + 1] = html:sub(i, i + 1)
                            i = i + 2
                        elseif ch == quote then
                            closed = true
                            break
                        else
                            buf[#buf + 1] = ch
                            i = i + 1
                        end
                    end
                    if closed then
                        local val = decode_html_entities(unescape_js_str(table.concat(buf)))
                        if val ~= "" then return val end
                    end
                end
                idx = e + 1
            end
        end
        return ""
    end

    function M.parse_wechat_html(body)
        local html = tostring(body or "")
        local out = { title = "", account = "", desc = "", content = "", blocked = false }
        if html == "" then return out end

        if html:find("当前环境异常", 1, true)
            or html:find("完成验证后即可继续访问", 1, true)
            or html:find("该内容已被发布者删除", 1, true)
            or html:find("此内容因违规无法查看", 1, true)
            or html:find("此内容已被投诉", 1, true) then
            out.blocked = true
        end

        out.title = extract_meta(html, "og:title")
        if out.title == "" then out.title = extract_meta(html, "twitter:title") end
        if out.title == "" then out.title = trim(extract_js_string_field(html, "msg_title")) end
        if out.title == "" then out.title = trim(extract_js_string_field(html, "title")) end
        if out.title == "" then
            local t = html:match("<[tT][iI][tT][lL][eE][^>]*>(.-)</[tT][iI][tT][lL][eE]>")
            if t then out.title = trim(decode_html_entities(t)) end
        end

        local acc_html = extract_div_by_id(html, "js_name")
        if acc_html ~= "" then out.account = trim(html_to_text(acc_html)) end
        if out.account == "" then out.account = trim(extract_js_string_field(html, "nick_name")) end
        if out.account == "" then out.account = trim(extract_js_string_field(html, "nickname")) end
        if out.account == "" then out.account = extract_meta(html, "author") end

        out.desc = extract_meta(html, "og:description")
        if out.desc == "" then out.desc = extract_meta(html, "description") end
        if out.desc == "" then out.desc = trim(extract_js_string_field(html, "msg_desc")) end
        if out.desc == "" then out.desc = trim(extract_js_string_field(html, "desc")) end

        local js_content = extract_div_by_id(html, "js_content")
        local text = html_to_text(js_content)
        if text == "" then
            local cno = extract_js_string_field(html, "content_noencode")
            if cno ~= "" then text = html_to_text(cno) end
        end
        if #text > 3500 then text = common.clip_head_tail(text, 3500) end
        out.content = text
        return out
    end

    local function article_cache_key(a)
        local key = (a.canon_key and a.canon_key ~= "") and a.canon_key
            or (sources and sources.wx_article_key and sources.wx_article_key(a.url))
            or tostring(a.url or "")
        key = key:gsub("[^%w%-_.:/]", "_")
        if #key > 140 then key = key:sub(1, 140) end
        return "da:wx_sum:v1:" .. key
    end

    function M.prepare_article_fetch(articles, max_fetch)
        if type(articles) ~= "table" or #articles == 0 then return {} end
        local limit = tonumber(max_fetch) or 12
        local pending = {}
        for _, a in ipairs(articles) do
            local u = tostring(a.url or "")
            if u:find("mp%.weixin%.qq%.com", 1) then
                if (a.title or "") == "" or (a.summary or "") == "" then
                    if jn.cache and jn.cache.get then
                        local cached = jn.cache.get(article_cache_key(a))
                        if type(cached) == "table" then
                            if (a.title or "") == "" and type(cached.title) == "string" and cached.title ~= "" then
                                a.title = trim(cached.title)
                            end
                            if (a.summary or "") == "" and type(cached.summary) == "string" and cached.summary ~= "" then
                                a.summary = trim(cached.summary)
                            end
                            if (a.account or "") == "" and type(cached.account) == "string" and cached.account ~= "" then
                                a.account = trim(cached.account)
                            end
                        end
                    end
                end
                if ((a.title or "") == "" or (a.summary or "") == "") and #pending < limit then
                    pending[#pending + 1] = {
                        article = a,
                        url = u,
                        cache_key = article_cache_key(a),
                    }
                end
            end
        end
        return pending
    end

    local function parse_fetched_need_llm(fetched_items)
        local need_llm = {}
        for _, item in ipairs(fetched_items) do
            local a = item.article
            if a then
                local parsed = nil
                if item.status == 200 and type(item.body) == "string" and item.body ~= "" then
                    parsed = M.parse_wechat_html(item.body)
                    item.parsed = parsed
                    if not parsed.blocked then
                        if (a.title or "") == "" and parsed.title ~= "" then
                            a.title = parsed.title
                        end
                        if (a.account or "") == "" and parsed.account ~= "" then
                            a.account = parsed.account
                        end
                    end
                end
                if (a.summary or "") == "" then
                    if parsed and not parsed.blocked and parsed.content ~= "" and #parsed.content >= 40 then
                        need_llm[#need_llm + 1] = item
                    elseif parsed and not parsed.blocked and parsed.desc ~= "" then
                        a.summary = trim(common.clip(parsed.desc, 120))
                    end
                end
            end
        end
        return need_llm
    end

    local function build_article_batches(need_llm)
        local batches = {}
        local sys = [[你是公众号新闻摘要助手。用户会给你若干篇微信公众号文章的标题、来源与正文摘录，请为每篇文章提取清晰标题与简明摘要，并严格返回 JSON：
{"articles":[{"index":1,"title":"文章标题(≤36字，若原文已给准确标题可直接沿用或略微精简)","summary":"50~100字简体中文摘要：提炼核心事实、结论、发布内容或核心观点；严禁编造原文未提及的信息"}]}]]
        for start = 1, #need_llm, 4 do
            local chunk, parts = {}, {}
            for k = start, math.min(start + 3, #need_llm) do
                local it = need_llm[k]
                chunk[#chunk + 1] = it
                local a = it.article
                local p = it.parsed or {}
                local block = {
                    string.format("【文章 %d】URL: %s", #chunk, a.url or ""),
                    "已知标题：" .. ((a.title and a.title ~= "") and a.title or "（待提取）"),
                }
                if a.account and a.account ~= "" then
                    block[#block + 1] = "公众号：" .. a.account
                end
                if p.desc and p.desc ~= "" then
                    block[#block + 1] = "导语/描述：" .. p.desc
                end
                block[#block + 1] = "正文摘录：\n" .. (p.content or "")
                parts[#parts + 1] = table.concat(block, "\n")
            end
            batches[#batches + 1] = { chunk = chunk, sys = sys, user = table.concat(parts, "\n\n") }
        end
        return batches
    end

    local function apply_article_batch(chunk, obj)
        if not (obj and type(obj.articles) == "table") then return end
        for _, res_item in ipairs(obj.articles) do
            if type(res_item) == "table" and res_item.index then
                local it = chunk[tonumber(res_item.index)]
                if it and it.article then
                    local t = trim(res_item.title or "")
                    local s = trim(res_item.summary or "")
                    if (it.article.title or "") == "" and t ~= "" then
                        it.article.title = t
                    end
                    if s ~= "" then
                        it.article.summary = common.clip(s, 120)
                    end
                end
            end
        end
    end

    local function finalize_fetched_articles(fetched_items)
        for _, item in ipairs(fetched_items) do
            local a = item.article
            local p = item.parsed
            if a and p and not p.blocked and (a.summary or "") == "" then
                if p.desc ~= "" then
                    a.summary = trim(common.clip(p.desc, 120))
                elseif p.content ~= "" then
                    a.summary = trim(common.clip(p.content, 100))
                end
            end
            if a and ((a.title or "") ~= "" or (a.summary or "") ~= "")
                and jn.cache and jn.cache.set and (not p or not p.blocked) then
                jn.cache.set(item.cache_key, {
                    title = a.title or "",
                    summary = a.summary or "",
                    account = a.account or "",
                }, 604800)
            end
        end
    end

    function M.summarize_fetched_articles(fetched_items)
        if type(fetched_items) ~= "table" or #fetched_items == 0 then return end
        local need_llm = parse_fetched_need_llm(fetched_items)
        if #need_llm > 0 and jn.llm and jn.llm.chat then
            local timeout = math.max(30, common.da_num("llm_timeout", 360))
            jn.log.info(string.format("[%s] 补全总结 %d 篇未捕获全文的公众号文章", common.PLUGIN_NAME, #need_llm))
            for _, b in ipairs(build_article_batches(need_llm)) do
                local obj = nil
                for attempt = 1, 2 do
                    local resp, err = jn.llm.chat({
                        { role = "system", content = b.sys },
                        { role = "user", content = b.user },
                    }, { timeout = timeout })
                    if not err and resp and resp ~= "" then
                        obj = common.decode_llm_json(resp, "文章补全")
                        if obj and type(obj.articles) == "table" then break end
                    else
                        jn.log.warn(string.format("[%s] 公众号文章总结失败(第 %d 次): %s",
                            common.PLUGIN_NAME, attempt, tostring(err or "空响应")))
                    end
                end
                apply_article_batch(b.chunk, obj)
            end
        end
        finalize_fetched_articles(fetched_items)
    end

    function M.summarize_fetched_articles_async(fetched_items, on_done)
        on_done = on_done or function() end
        if type(fetched_items) ~= "table" or #fetched_items == 0 then
            on_done()
            return
        end
        local need_llm = parse_fetched_need_llm(fetched_items)
        if #need_llm == 0 or not (jn.llm and (jn.llm.chat_async or jn.llm.chat)) then
            finalize_fetched_articles(fetched_items)
            on_done()
            return
        end
        jn.log.info(string.format("[%s] 补全总结 %d 篇未捕获全文的公众号文章", common.PLUGIN_NAME, #need_llm))
        run_async_batches(build_article_batches(need_llm), 1, 1, "文章补全", "articles", apply_article_batch, function()
            finalize_fetched_articles(fetched_items)
            on_done()
        end)
    end

    return M
end
