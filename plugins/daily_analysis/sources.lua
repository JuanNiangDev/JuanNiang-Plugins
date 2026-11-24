-- sources.lua — CQ 码展开（转发/图片/回复）与本机水印来源采集

return function(jn, common)
    local M = {}

    local da_bool = common.da_bool
    local da_num = common.da_num
    local da_string = common.da_string
    local da_clip = common.clip
    local is_bot_output = common.is_bot_output
    local strip_wm = common.strip_wm
    local clean_quote_text = common.clean_quote_text
    local normalize_url = common.normalize_url
    local cq_unescape = common.cq_unescape

    local da_vision_used = 0

    function M.reset_vision_counter()
        da_vision_used = 0
    end

    function M.vision_used()
        return da_vision_used
    end

    function M.da_forward_text(fid, full)
        local ck = "da:fwd:" .. fid .. (full and ":full" or "")
        local cached = jn.cache.get(ck)
        if type(cached) == "string" then return cached end
        if not jn.onebot11 or not jn.onebot11.get_forward_msg_sync then
            return "【合并转发】"
        end
        local ok, nodes, err = pcall(jn.onebot11.get_forward_msg_sync, fid)
        if not ok or err or type(nodes) ~= "table" or #nodes == 0 then
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 合并转发展开失败 id=" .. tostring(fid) .. " err=" .. tostring(err or ok))
            return "【合并转发】"
        end

        local limit = full and 60 or da_num("forward_node_limit", 50)
        local width = full and 4000 or da_num("forward_node_chars", 4000)
        local parts, inner = {}, #nodes
        for i, n in ipairs(nodes) do
            if i > limit then break end
            local texts = {}
            local content = n.content
            if type(content) == "table" then
                for _, seg in ipairs(content) do
                    if type(seg) == "table" and seg.type == "text" and type(seg.data) == "table" then
                        local t = seg.data.text
                        if type(t) == "string" and t ~= "" then texts[#texts + 1] = t end
                    elseif type(seg) == "table" and seg.type == "image" then
                        texts[#texts + 1] = "[图]"
                    elseif type(seg) == "table" and seg.type == "xml" and type(seg.data) == "table" then
                        local xml = tostring(seg.data.data or "")
                        local titles = {}
                        for title in xml:gmatch("<title[^>]*>([^<]*)</title>") do
                            local v = title:gsub("^%s+", ""):gsub("%s+$", "")
                            if v ~= "" then titles[#titles + 1] = v end
                        end
                        if #titles > 0 then texts[#texts + 1] = table.concat(titles, " / ") end
                    end
                end
            elseif type(content) == "string" and content ~= "" then
                texts[#texts + 1] = content
            end
            local who = tostring(n.name or ("群友" .. tostring(n.uin or "")))
            local joiner = full and "\n" or " "
            parts[#parts + 1] = who .. "：" .. da_clip(table.concat(texts, joiner), width)
        end
        local out
        if full then
            out = table.concat(parts, "\n")
        else
            out = "【合并转发 " .. inner .. " 条】" .. table.concat(parts, " / ")
            if inner > limit then out = out .. " …（另 " .. (inner - limit) .. " 条）" end
        end
        jn.cache.set(ck, out, 7 * 86400)
        return out
    end

    local function da_image_text(url, file)
        local key = "da:img:" .. (((file and file ~= "") and file) or url)
        local cached = jn.cache.get(key)
        if type(cached) == "string" then return cached end
        if not da_bool("vision_describe", true)
            or not jn.llm or not jn.llm.vision_url
            or da_vision_used >= da_num("vision_image_limit", 10) then
            return "[图片]"
        end
        da_vision_used = da_vision_used + 1

        local fresh = url
        if file and file ~= "" and jn.onebot11 and jn.onebot11.get_image then
            local ok_renew, info, renew_err = pcall(jn.onebot11.get_image, file)
            if ok_renew and type(info) == "table" and type(info.url) == "string" and info.url ~= "" then
                fresh = info.url
            else
                jn.log.warn("[" .. common.PLUGIN_NAME .. "] get_image 续签失败 file=" .. da_clip(file, 80)
                    .. " err=" .. tostring(renew_err or info))
            end
        end

        local ok, text, err = pcall(jn.llm.vision_url,
            da_string("vision_provider", "wb-api-image"),
            fresh,
            "用一句中文描述这张图片的内容，最多30字，只写图中明确可见的内容，不要编造",
            { timeout = 30 })
        if ok and not err and type(text) == "string" and text ~= "" then
            local out = "【图片：" .. da_clip(text, 60) .. "】"
            jn.cache.set(key, out, 7 * 86400)
            return out
        end
        jn.log.warn("[" .. common.PLUGIN_NAME .. "] 图片描述失败 file=" .. tostring(file or "-")
            .. " url=" .. da_clip(fresh, 80) .. " err=" .. tostring(err or text))
        return "[图片]"
    end

    local function da_reply_text(id)
        local rows, err = jn.database.query([[
            SELECT nickname, content FROM ]] .. common.TABLE_MESSAGES .. [[
            WHERE message_id = ? LIMIT 1
        ]], { tonumber(id) })
        if err or type(rows) ~= "table" or not rows[1] then return "" end
        local src = rows[1].content or ""
        if src == "" then return "" end
        return "【回复 " .. tostring(rows[1].nickname or "群友") .. "：「" .. da_clip(src, 80) .. "」】"
    end

    function M.expand_cq_content(raw, fallback)
        if type(raw) ~= "string" or raw == "" then return fallback or "" end
        local s = raw
        if da_bool("expand_reply", true) then
            s = s:gsub("%[CQ:reply,id=(%-?%d+)%]", function(id) return da_reply_text(id) end)
        else
            s = s:gsub("%[CQ:reply,id=%-?%d+%]", "")
        end
        if da_bool("expand_forward", true) then
            s = s:gsub("%[CQ:forward,id=([^,%]]+)%]", function(fid) return M.da_forward_text(fid) end)
        end
        s = s:gsub("%[CQ:image,([^%]]+)%]", function(attrs)
            local url = attrs:match("url=([^,%]]+)")
            local file = attrs:match("file=([^,%]]+)")
            if not url or url == "" then return "[图片]" end
            return da_image_text((url:gsub("&amp;", "&")), file)
        end)
        s = s:gsub("%[CQ:record,[^%]]*%]", "[语音]")
        s = s:gsub("%[CQ:video,[^%]]*%]", "[视频]")
        s = s:gsub("%[CQ:file,[^%]]*%]", "[文件]")
        return s
    end

    -- ----------------------------------------------------------------
    -- 本机卡片块解析与水印来源采集
    -- ----------------------------------------------------------------
    local IMG_CQ_PREFIX = "[CQ:image,"

    local function collect_cq_images(line, images)
        local pos = 1
        while true do
            local s = line:find(IMG_CQ_PREFIX, pos, true)
            if not s then break end
            local e = line:find("]", s + 1, true)
            if not e then break end
            local body = line:sub(s + #IMG_CQ_PREFIX, e - 1)
            local url = body:match("url=(https?://[^,%s]+)") or body:match("file=(https?://[^,%s]+)")
            if url and url ~= "" then images[#images + 1] = cq_unescape(url) end
            pos = e + 1
        end
    end

    function M.parse_bot_blocks(text)
        local blocks, cur = {}, nil
        local function flush()
            if not cur then return end
            local clean = {}
            for i, l in ipairs(cur.lines) do
                local line = tostring(l):gsub("%[CQ:[^%]]*%]", ""):gsub("\r", "")
                line = strip_wm(line)
                if i == 1 then line = line:gsub("^%s+", "") end
                clean[#clean + 1] = line:gsub("%s+$", "")
            end
            while #clean > 0 and clean[#clean] == "" do clean[#clean] = nil end

            local title, summary, anchor = "", "", nil
            for i, l in ipairs(clean) do
                if l:find("📝", 1, true) or l:find("📰", 1, true) then anchor = i; break end
            end
            if anchor then
                local l = clean[anchor]
                local p1, p2 = l:find("📝", 1, true), l:find("📰", 1, true)
                local p, mlen = p1, #"📝"
                if not p or (p2 and p2 < p) then p, mlen = p2, #"📰" end
                if p then title = l:sub(p + mlen):gsub("^%s+", ""):gsub("%s+$", "") end
                for i = anchor + 1, #clean do
                    local seg = clean[i]
                    local skip = seg:find("📖", 1, true) or seg:find("🔗", 1, true)
                    if seg ~= "" and not skip and not seg:find("^https?://") then summary = seg; break end
                end
            end
            blocks[#blocks + 1] = {
                kind = cur.kind, name = cur.name, url = cur.url,
                title = title, summary = summary,
                text = table.concat(clean, "\n"), images = cur.images,
            }
            cur = nil
        end

        local src = tostring(text or "")
        local pos, len = 1, #src
        while pos <= len do
            local nl = src:find("\n", pos, true)
            local line = (nl and src:sub(pos, nl - 1)) or src:sub(pos)
            pos = (nl and nl + 1) or (len + 1)

            local pbox = line:find("📦", 1, true)
            local pnews = line:find("📰", 1, true)
            local started = false
            if pbox then
                flush()
                local name = strip_wm(line:sub(pbox + #"📦"))
                name = name:gsub("%[CQ:[^%]]*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
                cur = { kind = "repo", lines = { line:sub(pbox) }, name = name, images = {} }
                started = true
            elseif pnews then
                flush()
                cur = { kind = "article", lines = { line:sub(pnews) }, images = {} }
                started = true
            end
            if cur then
                if not started then cur.lines[#cur.lines + 1] = line end
                collect_cq_images(line, cur.images)
                if not cur.url then
                    local u = line:match("(https?://[^%s]+)")
                    if u then
                        u = u:match("^([^%[]*)") or u
                        cur.url = normalize_url(strip_wm(u))
                    end
                end
            end
        end
        flush()
        return blocks
    end

    function M.is_degraded_repo_block(b)
        if not b or b.kind ~= "repo" then return true end
        local title = tostring(b.title or "")
        local summary = tostring(b.summary or "")
        if title == "" and summary == "" then return true end
        if title ~= "" and summary ~= "" then
            local suffix = title:match("：%s*(.+)$")
            if suffix and suffix == summary then return true end
        end
        return false
    end

    local function infer_repo_kind(url)
        local u = tostring(url or ""):lower()
        if u:find("huggingface.co", 1, true) or u:find("hf-mirror.com", 1, true) then return "hf" end
        if u:find("modelscope.", 1, true) then return "ms" end
        return "github"
    end

    function M.collect_sources(messages)
        local projects, pindex = {}, {}
        local projects_on = da_bool("enable_projects", true)
        local bot_article, bot_raw = {}, {}
        local img_total = 0

        for _, m in ipairs(messages) do
            local raw = m.raw_message or ""
            local text = m.content or ""
            local is_bot = is_bot_output(raw) or is_bot_output(text)
            if not is_bot and raw:find("[CQ:forward,", 1, true)
                and not (text:find("📰", 1, true) or text:find("📦", 1, true)) then
                local fid = raw:match("%[CQ:forward,id=([^,%]]+)%]")
                if fid then
                    local ex = M.da_forward_text(fid, true)
                    if is_bot_output(ex) then
                        is_bot = true
                        text = ex
                    end
                end
            end
            if is_bot then
                bot_raw[raw] = true
                local src = raw:find("📦", 1, true) and raw or text
                for _, b in ipairs(M.parse_bot_blocks(src)) do
                    if projects_on and b.kind == "repo" and b.name ~= "" then
                        local key = b.name:lower()
                        b.key = key
                        b.degraded = M.is_degraded_repo_block(b)
                        if b.degraded then
                            b.repo_kind = infer_repo_kind(b.url)
                            b.text = nil
                        end
                        local prev_idx = pindex[key]
                        if prev_idx then
                            local prev = projects[prev_idx]
                            if not b.degraded or prev.degraded then
                                img_total = img_total + #b.images
                                projects[prev_idx] = b
                            end
                        else
                            img_total = img_total + #b.images
                            pindex[key] = #projects + 1
                            projects[#projects + 1] = b
                        end
                    elseif b.kind == "article" and b.url and b.url ~= "" then
                        bot_article[normalize_url(b.url)] = b
                    end
                end
            end
        end

        for _, p in ipairs(projects) do
            if p.degraded then
                p.kind = p.repo_kind or infer_repo_kind(p.url)
                p.url = p.url or ("https://github.com/" .. p.name)
            end
        end

        local repo_seen = {}
        for k in pairs(pindex) do repo_seen[k] = true end
        local function add_repo(kind, name, url)
            if not projects_on then return end
            name = name:gsub("%.git$", ""):gsub("[%)%,%.%!%?%;:]+$", "")
            local owner, repo = name:match("^([^/]+)/([^/]+)$")
            if not owner or not repo then return end
            if kind == "github" then
                local bad = { issues = true, pull = true, blob = true, tree = true,
                              releases = true, actions = true, wiki = true, sponsors = true, discussions = true }
                if bad[repo:lower()] then return end
            end
            local key = name:lower()
            if repo_seen[key] then return end
            repo_seen[key] = true
            projects[#projects + 1] = { key = key, kind = kind, name = name, url = normalize_url(url) }
        end

        local articles, aindex = {}, {}
        local function add_article(url)
            url = normalize_url(url)
            if url == "" then return end
            if not aindex[url] then
                aindex[url] = #articles + 1
                articles[#articles + 1] = { url = url, count = 0 }
            end
            articles[aindex[url]].count = articles[aindex[url]].count + 1
        end

        for _, m in ipairs(messages) do
            local raw = m.raw_message or ""
            if not is_bot_output(raw) and not bot_raw[raw] then
                local scan = (m.content and m.content ~= "") and m.content or raw
                for owner, repo in scan:gmatch("github%.com/([%w%-_%.]+)/([%w%-_%.]+)") do
                    add_repo("github", owner .. "/" .. repo, "https://github.com/" .. owner .. "/" .. repo)
                end
                for sub, owner, repo in scan:gmatch("huggingface%.co/(models|datasets)/([%w%-_%.]+)/([%w%-_%.]+)") do
                    add_repo("hf", owner .. "/" .. repo, "https://huggingface.co/" .. sub .. "/" .. owner .. "/" .. repo)
                end
                for owner, repo in scan:gmatch("huggingface%.co/([%w%-_%.]+)/([%w%-_%.]+)") do
                    if owner ~= "models" and owner ~= "datasets" and owner ~= "spaces" and owner ~= "api" then
                        add_repo("hf", owner .. "/" .. repo, "https://huggingface.co/" .. owner .. "/" .. repo)
                    end
                end
                for _, host in ipairs({ "cn", "ai" }) do
                    local pat = "modelscope%." .. host .. "/(models|datasets)/([%w%-_%.]+)/([%w%-_%.]+)"
                    for sub, owner, repo in scan:gmatch(pat) do
                        add_repo("ms", owner .. "/" .. repo,
                            "https://modelscope." .. host .. "/" .. sub .. "/" .. owner .. "/" .. repo)
                    end
                end
                for u in scan:gmatch("(https?://mp%.weixin%.qq%.com/s[%w%-_%.%?%%&=/#]+)") do
                    add_article(u)
                end
            end
        end

        for _, a in ipairs(articles) do
            local b = bot_article[normalize_url(a.url)]
            if b then
                a.title = (b.title ~= "" and b.title) or nil
                a.summary = (b.summary ~= "" and b.summary) or nil
            end
        end

        local with_title = 0
        for _, a in ipairs(articles) do
            if (a.title or "") ~= "" then with_title = with_title + 1 end
        end
        jn.log.info(string.format("[%s] 项目复制：%d 个（带图 %d 张）", common.PLUGIN_NAME, #projects, img_total))
        jn.log.info(string.format("[%s] 来源采集：公众号 %d（已有标题 %d）", common.PLUGIN_NAME, #articles, with_title))
        return projects, articles
    end

    function M.quote_source_text(messages, msg_id)
        local idx = tonumber(msg_id)
        if not idx then return nil end
        local row = messages[idx]
        if type(row) ~= "table" then return nil end
        local m = row._source_msg or row
        local raw = tostring(m.raw_message or "")
        local fid = raw:match("%[CQ:forward,id=([^,%]]+)%]")
            or tostring(m.content or ""):match("%[CQ:forward,id=([^,%]]+)%]")
        if fid then
            raw = M.da_forward_text(fid, true)
        else
            raw = tostring(m.content or "")
        end
        local text = clean_quote_text(raw)
        if text == "" then return nil end
        return text
    end

    return M
end
