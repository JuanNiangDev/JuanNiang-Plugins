-- sources.lua — CQ 码展开（转发/图片/回复编号关联）与严格基于零宽水印的来源采集

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
    local da_image_seq = 0
    local da_forward_seq = 0

    function M.reset_vision_counter()
        da_vision_used = 0
        da_image_seq = 0
        da_forward_seq = 0
    end

    function M.vision_used()
        return da_vision_used
    end

    local function html_unescape_basic(s)
        s = tostring(s or "")
        return (s:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">")
                 :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&"))
    end

    local function unescape_card_url(u)
        u = cq_unescape(tostring(u or ""))
        u = u:gsub("\\/", "/")
        return normalize_url(u)
    end

    function M.wx_article_key(u)
        u = unescape_card_url(u)
        local id = u:match("mp%.weixin%.qq%.com/s/([%w%-_]+)")
        if id then return "wx:" .. id, "https://mp.weixin.qq.com/s/" .. id end
        local q = u:match("mp%.weixin%.qq%.com/s%?([%w%+%/%_%%%&%.%-=]+)")
        if q and q:find("__biz", 1, true) then
            local sn = q:match("[?&]sn=([^&]+)")
            if sn then
                return "wx?sn=" .. sn, "https://mp.weixin.qq.com/s?" .. q
            end
            local biz = q:match("__biz=([^&]+)") or ""
            local mid = q:match("[?&]mid=([^&]+)") or ""
            local idx = q:match("[?&]idx=([^&]+)") or ""
            return "wx?" .. biz .. "/" .. mid .. "/" .. idx, "https://mp.weixin.qq.com/s?" .. q
        end
        return nil, nil
    end

    function M.extract_wx_urls_from_text(raw)
        local out, seen = {}, {}
        if type(raw) ~= "string" or raw == "" then return out end
        local s = cq_unescape(raw):gsub("\\/", "/")
        local function add_hit(u)
            local k, norm = M.wx_article_key(u)
            if k and norm and not seen[k] then
                seen[k] = true
                out[#out + 1] = { key = k, url = norm }
            end
        end
        local pos = 1
        while true do
            local hit = s:find("mp.weixin.qq.com/s/", pos, true)
            if not hit then break end
            local id = s:sub(hit + #"mp.weixin.qq.com/s/"):match("^([%w%-_]+)")
            if id then add_hit("https://mp.weixin.qq.com/s/" .. id) end
            pos = hit + 1
        end
        pos = 1
        while true do
            local hit = s:find("mp.weixin.qq.com/s?", pos, true)
            if not hit then break end
            local q = s:sub(hit + #"mp.weixin.qq.com/s?"):match("^([%w%+%/%_%%%&%.%-=]+)")
            if q then add_hit("https://mp.weixin.qq.com/s?" .. q) end
            pos = hit + 1
        end
        return out
    end

    function M.extract_json_card_info(raw_json)
        if type(raw_json) ~= "string" or raw_json == "" then return nil end
        local raw = cq_unescape(raw_json)
        local ok, obj = pcall(jn.json.decode, raw)
        local title, desc, url = "", "", ""
        if ok and type(obj) == "table" then
            local function walk(t, depth)
                if type(t) ~= "table" or depth > 6 then return end
                if title == "" then
                    local tv = t.title or t.prompt
                    if type(tv) == "string" and tv ~= "" then title = tv end
                end
                if desc == "" then
                    local dv = t.desc or t.summary
                    if type(dv) == "string" and dv ~= "" then desc = dv end
                end
                for _, k in ipairs({ "qqdocurl", "jumpUrl", "url", "uri", "targetUrl", "sourcelink" }) do
                    local uv = t[k]
                    if type(uv) == "string" and uv:find("^https?://") then
                        local cand = unescape_card_url(uv)
                        if url == "" or cand:find("mp%.weixin%.qq%.com", 1) then
                            url = cand
                        end
                    end
                end
                for _, v in pairs(t) do
                    if type(v) == "table" then walk(v, depth + 1) end
                end
            end
            walk(obj, 0)
        end
        if url == "" then
            local norm_raw = raw:gsub("\\/", "/")
            local wx = M.extract_wx_urls_from_text(norm_raw)
            if wx[1] then url = wx[1].url end
        end
        title = html_unescape_basic(title):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        desc = html_unescape_basic(desc):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if title == "" and desc == "" and url == "" then return nil end
        return { title = title, desc = desc, url = url }
    end

    function M.extract_xml_card_info(raw_xml)
        if type(raw_xml) ~= "string" or raw_xml == "" then return nil end
        local xml = cq_unescape(raw_xml)
        local title = xml:match("<title[^>]*>([^<]*)</title>") or ""
        local desc = xml:match("<des[^>]*>([^<]*)</des>") or xml:match("<summary[^>]*>([^<]*)</summary>") or ""
        local url = xml:match('<item[^>]-url="(https?://[^"]+)"')
            or xml:match('url="(https?://[^"]+)"')
            or xml:match("<url[^>]*>(https?://[^<]+)</url>")
            or ""
        title = html_unescape_basic(title):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        desc = html_unescape_basic(desc):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        url = unescape_card_url(url)
        if title == "" and desc == "" and url == "" then return nil end
        return { title = title, desc = desc, url = url }
    end

    local function format_card_text(info, full)
        if not info then return "" end
        local head = {}
        if info.title ~= "" then head[#head + 1] = info.title end
        if info.desc ~= "" and info.desc ~= info.title then head[#head + 1] = da_clip(info.desc, 120) end
        local label = (#head > 0) and ("【分享卡片：" .. table.concat(head, " | ") .. "】") or "【分享卡片】"
        if info.url ~= "" then
            return full and (label .. "\n" .. info.url) or (label .. info.url)
        end
        return label
    end

    local function da_image_text(url, file, indexed)
        if not url or url == "" then
            if indexed then
                da_image_seq = da_image_seq + 1
                return string.format("[图#%d]", da_image_seq)
            end
            return "[图片]"
        end
        local key = "da:img:v2:" .. (((file and file ~= "") and file) or url)
        local desc = nil
        local cached = jn.cache.get(key)
        if type(cached) == "string" and cached ~= "" then
            desc = cached
        elseif da_bool("vision_describe", true)
            and jn.llm and jn.llm.vision_url
            and da_vision_used < da_num("vision_image_limit", 30) then
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
                "用一句中文描述这张图片的核心内容（画面、文字、截图主题或笑点），最多40字，只写图中明确可见的内容，不要编造",
                { timeout = 30 })
            if ok and not err and type(text) == "string" and text ~= "" then
                desc = da_clip(text:gsub("\r", " "):gsub("\n", " "), 70)
                jn.cache.set(key, desc, 7 * 86400)
            else
                jn.log.warn("[" .. common.PLUGIN_NAME .. "] 图片描述失败 file=" .. tostring(file or "-")
                    .. " url=" .. da_clip(fresh, 80) .. " err=" .. tostring(err or text))
            end
        end

        if indexed then
            da_image_seq = da_image_seq + 1
            if desc and desc ~= "" then
                return string.format("[图#%d：%s]", da_image_seq, desc)
            end
            return string.format("[图#%d]", da_image_seq)
        end
        if desc and desc ~= "" then
            return "【图片：" .. desc .. "】"
        end
        return "[图片]"
    end

    local function expand_forward_images(s)
        return (tostring(s or ""):gsub("%[CQ:image,([^%]]+)%]", function(attrs)
            local url = attrs:match("url=([^,%]]+)")
            local file = attrs:match("file=([^,%]]+)")
            return da_image_text(url and (url:gsub("&amp;", "&")) or "", file, true)
        end))
    end

    function M.da_forward_text(fid, full, depth, allow_vision)
        depth = tonumber(depth) or 0
        if depth > 2 then return "【合并转发】" end

        local raw_ck = "da:fwd:raw:v3:" .. tostring(fid) .. (full and ":full" or "")
        local nodes = nil
        local cached_raw = jn.cache.get(raw_ck)
        if type(cached_raw) == "table" and type(cached_raw.nodes) == "table" then
            nodes = cached_raw.nodes
        end

        if not nodes then
            if not jn.onebot11 or not jn.onebot11.get_forward_msg_sync then
                return "【合并转发】"
            end
            local ok, got, err = pcall(jn.onebot11.get_forward_msg_sync, fid)
            if not ok or err or type(got) ~= "table" or #got == 0 then
                jn.log.warn("[" .. common.PLUGIN_NAME .. "] 合并转发展开失败 id=" .. tostring(fid) .. " err=" .. tostring(err or ok))
                return "【合并转发】"
            end
            nodes = got
            jn.cache.set(raw_ck, { nodes = nodes }, 7 * 86400)
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
                    if type(seg) == "table" and type(seg.data) == "table" then
                        if seg.type == "text" then
                            local t = tostring(seg.data.text or "")
                            t = t:gsub("%[CQ:json,data=([^%]]+)%]", function(d)
                                return format_card_text(M.extract_json_card_info(d), full)
                            end)
                            t = t:gsub("%[CQ:xml,data=([^%]]+)%]", function(d)
                                return format_card_text(M.extract_xml_card_info(d), full)
                            end)
                            if allow_vision then
                                t = expand_forward_images(t)
                            end
                            if t ~= "" then texts[#texts + 1] = t end
                        elseif seg.type == "image" then
                            if allow_vision then
                                local img_url = tostring(seg.data.url or seg.data.file or "")
                                local img_file = tostring(seg.data.file or "")
                                texts[#texts + 1] = da_image_text((img_url:gsub("&amp;", "&")), img_file, true)
                            else
                                texts[#texts + 1] = "[图]"
                            end
                        elseif seg.type == "json" then
                            local card_txt = format_card_text(M.extract_json_card_info(tostring(seg.data.data or "")), full)
                            if card_txt ~= "" then texts[#texts + 1] = card_txt end
                        elseif seg.type == "xml" then
                            local card_txt = format_card_text(M.extract_xml_card_info(tostring(seg.data.data or "")), full)
                            if card_txt ~= "" then texts[#texts + 1] = card_txt end
                        elseif seg.type == "forward" and seg.data.id and tostring(seg.data.id) ~= tostring(fid) then
                            texts[#texts + 1] = M.da_forward_text(tostring(seg.data.id), full, depth + 1, allow_vision)
                        end
                    end
                end
            elseif type(content) == "string" and content ~= "" then
                local t = content:gsub("%[CQ:json,data=([^%]]+)%]", function(d)
                    return format_card_text(M.extract_json_card_info(d), full)
                end)
                t = t:gsub("%[CQ:xml,data=([^%]]+)%]", function(d)
                    return format_card_text(M.extract_xml_card_info(d), full)
                end)
                if allow_vision then
                    t = expand_forward_images(t)
                end
                texts[#texts + 1] = t
            end
            local who = tostring(n.name or ("群友" .. tostring(n.uin or "")))
            local joiner = full and "\n" or " "
            local body_txt = table.concat(texts, joiner)
            if not full then
                body_txt = strip_wm(body_txt)
            end
            parts[#parts + 1] = who .. "：" .. da_clip(body_txt, width)
        end

        if full then
            return table.concat(parts, "\n")
        end

        local prefix = "【合并转发"
        if depth == 0 and allow_vision then
            da_forward_seq = da_forward_seq + 1
            prefix = string.format("[转发#%d｜%d条] ", da_forward_seq, inner)
        else
            prefix = "【合并转发 " .. inner .. " 条】"
        end
        local out = prefix .. table.concat(parts, " / ")
        if inner > limit then out = out .. " …（另 " .. (inner - limit) .. " 条）" end
        return out
    end

    -- 仅从合并转发的独立节点中抽取带零宽水印的机器人口径原文（避免混入人类节点或“昵称：”前缀）
    function M.collect_forward_watermarked_texts(fid, out, depth)
        out = out or {}
        depth = tonumber(depth) or 0
        if depth > 2 then return out end
        local raw_ck = "da:fwd:raw:v3:" .. tostring(fid) .. ":full"
        local cached_raw = jn.cache.get(raw_ck)
        local nodes = (type(cached_raw) == "table" and type(cached_raw.nodes) == "table") and cached_raw.nodes or nil
        if not nodes then
            M.da_forward_text(fid, true, depth, false)
            cached_raw = jn.cache.get(raw_ck)
            nodes = (type(cached_raw) == "table" and type(cached_raw.nodes) == "table") and cached_raw.nodes or nil
        end
        if type(nodes) ~= "table" then return out end
        for _, n in ipairs(nodes) do
            local content = n.content
            if type(content) == "table" then
                local texts = {}
                for _, seg in ipairs(content) do
                    if type(seg) == "table" and type(seg.data) == "table" then
                        if seg.type == "text" then
                            local t = tostring(seg.data.text or "")
                            if t ~= "" then texts[#texts + 1] = t end
                        elseif seg.type == "image" then
                            local u = tostring(seg.data.url or seg.data.file or "")
                            if u ~= "" then texts[#texts + 1] = "[CQ:image,url=" .. u .. "]" end
                        elseif seg.type == "forward" and seg.data.id and tostring(seg.data.id) ~= tostring(fid) then
                            M.collect_forward_watermarked_texts(tostring(seg.data.id), out, depth + 1)
                        end
                    end
                end
                local joined = table.concat(texts, "\n")
                if is_bot_output(joined) then
                    out[#out + 1] = joined
                end
            elseif type(content) == "string" and is_bot_output(content) then
                out[#out + 1] = content
            end
        end
        return out
    end

    local function da_reply_text(id, expanded_by_msg_id)
        local num_id = tonumber(id)
        if num_id and type(expanded_by_msg_id) == "table" and expanded_by_msg_id[tostring(num_id)] then
            local row = expanded_by_msg_id[tostring(num_id)]
            local src = strip_wm(tostring(row.content or ""))
            if src ~= "" then
                return "【回复 " .. tostring(row.nickname or "群友") .. "：「" .. da_clip(src, 140) .. "」】"
            end
        end
        local rows, err = jn.database.query([[
            SELECT nickname, content FROM ]] .. common.TABLE_MESSAGES .. [[
            WHERE message_id = ? LIMIT 1
        ]], { num_id })
        if err or type(rows) ~= "table" or not rows[1] then return "" end
        local src = strip_wm(rows[1].content or "")
        if src == "" then return "" end
        return "【回复 " .. tostring(rows[1].nickname or "群友") .. "：「" .. da_clip(src, 140) .. "」】"
    end

    function M.expand_cq_content(raw, fallback, expanded_by_msg_id)
        if type(raw) ~= "string" or raw == "" then return strip_wm(fallback or "") end
        local s = raw
        if da_bool("expand_reply", true) then
            s = s:gsub("%[CQ:reply,id=(%-?%d+)%]", function(id) return da_reply_text(id, expanded_by_msg_id) end)
        else
            s = s:gsub("%[CQ:reply,id=%-?%d+%]", "")
        end
        if da_bool("expand_forward", true) then
            s = s:gsub("%[CQ:forward,id=([^,%]]+)%]", function(fid)
                return M.da_forward_text(fid, false, 0, true)
            end)
        end
        s = s:gsub("%[CQ:json,data=([^%]]+)%]", function(d)
            local txt = format_card_text(M.extract_json_card_info(d), false)
            return txt ~= "" and txt or "[卡片]"
        end)
        s = s:gsub("%[CQ:xml,data=([^%]]+)%]", function(d)
            local txt = format_card_text(M.extract_xml_card_info(d), false)
            return txt ~= "" and txt or "[卡片]"
        end)
        s = s:gsub("%[CQ:image,([^%]]+)%]", function(attrs)
            local url = attrs:match("url=([^,%]]+)")
            local file = attrs:match("file=([^,%]]+)")
            return da_image_text(url and (url:gsub("&amp;", "&")) or "", file, true)
        end)
        s = s:gsub("%[CQ:record,[^%]]*%]", "[语音]")
        s = s:gsub("%[CQ:video,[^%]]*%]", "[视频]")
        s = s:gsub("%[CQ:file,[^%]]*%]", "[文件]")
        return strip_wm(s)
    end

    -- ----------------------------------------------------------------
    -- 严格仅靠零宽水印识别本机卡片块（绝不依赖 emoji！）
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

    local function detect_repo_in_text(clean_text)
        local o, r = clean_text:match("github%.com/([%w%-_%.]+)/([%w%-_%.]+)")
        if o and r then
            r = r:gsub("%.git$", ""):gsub("[%)%,%.%!%?%;:]+$", "")
            return "github", o .. "/" .. r, "https://github.com/" .. o .. "/" .. r
        end
        local sub, ho, hr = clean_text:match("huggingface%.co/(models|datasets|spaces)/([%w%-_%.]+)/([%w%-_%.]+)")
        if sub and ho and hr then
            hr = hr:gsub("%.git$", ""):gsub("[%)%,%.%!%?%;:]+$", "")
            return "hf", ho .. "/" .. hr, "https://huggingface.co/" .. sub .. "/" .. ho .. "/" .. hr
        end
        local ho2, hr2 = clean_text:match("huggingface%.co/([%w%-_%.]+)/([%w%-_%.]+)")
        if ho2 and hr2 and ho2 ~= "api" and ho2 ~= "models" and ho2 ~= "datasets" and ho2 ~= "spaces" then
            hr2 = hr2:gsub("%.git$", ""):gsub("[%)%,%.%!%?%;:]+$", "")
            return "hf", ho2 .. "/" .. hr2, "https://huggingface.co/" .. ho2 .. "/" .. hr2
        end
        for _, host in ipairs({ "cn", "ai" }) do
            local msub, mo, mr = clean_text:match("modelscope%." .. host .. "/(models|datasets)/([%w%-_%.]+)/([%w%-_%.]+)")
            if msub and mo and mr then
                mr = mr:gsub("%.git$", ""):gsub("[%)%,%.%!%?%;:]+$", "")
                return "ms", mo .. "/" .. mr, "https://modelscope." .. host .. "/" .. msub .. "/" .. mo .. "/" .. mr
            end
        end
        return nil, nil, nil
    end

    local function strip_leading_decor(s)
        s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
        -- 若原文开头有展示图标或标签前缀（不用于判定类型，仅清洗展示文本）
        s = s:gsub("^📦%s*", ""):gsub("^📰%s*", ""):gsub("^📝%s*", ""):gsub("^📖%s*", "")
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    function M.parse_bot_blocks(text)
        local raw_all = tostring(text or "")
        if not is_bot_output(raw_all) then
            return {}
        end

        -- 拆分同一条消息/转发内的多个卡片块：
        -- 每个区块内部必须亲自带有效水印才予采纳，绝不混采同消息中的无水印人类内容。
        local raw_chunks = {}
        local cur_lines = {}
        local cur_has_url = false
        local cur_has_wm = false
        local function push_chunk()
            if #cur_lines == 0 or not cur_has_wm then
                cur_lines = {}
                cur_has_url = false
                cur_has_wm = false
                return
            end
            local has_nonempty = false
            for _, l in ipairs(cur_lines) do
                if strip_wm(l):gsub("%[CQ:[^%]]*%]", ""):gsub("%s+", "") ~= "" then
                    has_nonempty = true
                    break
                end
            end
            if has_nonempty then
                raw_chunks[#raw_chunks + 1] = cur_lines
            end
            cur_lines = {}
            cur_has_url = false
            cur_has_wm = false
        end

        local pos, len = 1, #raw_all
        while pos <= len do
            local nl = raw_all:find("\n", pos, true)
            local line = (nl and raw_all:sub(pos, nl - 1)) or raw_all:sub(pos)
            pos = (nl and nl + 1) or (len + 1)

            local line_wm = is_bot_output(line)
            local clean_line = strip_wm(line):gsub("%[CQ:[^%]]*%]", ""):gsub("\r", "")
            local trimmed = clean_line:gsub("^%s+", ""):gsub("%s+$", "")

            if trimmed ~= "" then
                if line_wm and cur_has_url then
                    push_chunk()
                end
                if line_wm then cur_has_wm = true end
                cur_lines[#cur_lines + 1] = line
                if trimmed:find("https?://") then
                    cur_has_url = true
                end
            end
        end
        push_chunk()

        local blocks = {}
        for _, lines in ipairs(raw_chunks) do
            local images = {}
            local clean = {}
            for _, l in ipairs(lines) do
                collect_cq_images(l, images)
                local cl = strip_wm(l):gsub("%[CQ:[^%]]*%]", ""):gsub("\r", "")
                cl = cl:gsub("^%s+", ""):gsub("%s+$", "")
                if cl ~= "" then
                    clean[#clean + 1] = cl
                end
            end

            if #clean > 0 then
                local joined = table.concat(clean, "\n")
                local wx_hits = M.extract_wx_urls_from_text(joined)
                local rkind, rname, rurl = detect_repo_in_text(joined)

                if wx_hits[1] then
                    local title = strip_leading_decor(clean[1])
                    if title:find("https?://") or title:find("^原文链接[:：]") or title:find("^🔗") then
                        title = ""
                    end
                    local sum_parts = {}
                    for i = 2, #clean do
                        local seg = clean[i]
                        if not seg:find("^https?://")
                            and not seg:find("^🔗%s*原文链接")
                            and not seg:find("^原文链接[:：]")
                            and not seg:find("^📖") then
                            sum_parts[#sum_parts + 1] = strip_leading_decor(seg)
                        end
                    end
                    blocks[#blocks + 1] = {
                        kind = "article",
                        url = wx_hits[1].url,
                        title = title,
                        summary = table.concat(sum_parts, " "),
                        text = joined,
                        images = images,
                    }
                elseif rkind and rname and rurl then
                    local title_guess = ""
                    if clean[2] and not clean[2]:find("^https?://") then
                        title_guess = strip_leading_decor(clean[2])
                    end
                    local sum_lines = {}
                    for i = 3, #clean do
                        if not clean[i]:find("^https?://") then
                            sum_lines[#sum_lines + 1] = strip_leading_decor(clean[i])
                        end
                    end
                    blocks[#blocks + 1] = {
                        kind = "repo",
                        repo_kind = rkind,
                        name = rname,
                        url = normalize_url(rurl),
                        title = title_guess,
                        summary = table.concat(sum_lines, "\n"),
                        text = joined,
                        images = images,
                        degraded = false,
                    }
                end
            end
        end
        return blocks
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
        local bot_article, bot_raw, card_articles = {}, {}, {}
        local img_total = 0

        local function register_bot_blocks(src_text)
            for _, b in ipairs(M.parse_bot_blocks(src_text)) do
                if projects_on and b.kind == "repo" and b.name ~= "" then
                    local key = b.name:lower()
                    b.key = key
                    b.kind = b.repo_kind or infer_repo_kind(b.url)
                    local prev_idx = pindex[key]
                    if prev_idx then
                        local prev = projects[prev_idx]
                        if (not prev.text or #b.text > #prev.text) or (#b.images > #prev.images) then
                            img_total = img_total + #b.images
                            projects[prev_idx] = b
                        end
                    else
                        img_total = img_total + #b.images
                        pindex[key] = #projects + 1
                        projects[#projects + 1] = b
                    end
                elseif b.kind == "article" and b.url and b.url ~= "" then
                    local ak, norm = M.wx_article_key(b.url)
                    local map_key = ak or normalize_url(b.url)
                    if norm then b.url = norm end
                    bot_article[map_key] = b
                end
            end
        end

        local function collect_card_articles(scan_raw)
            if type(scan_raw) ~= "string" or scan_raw == "" then return end
            for d in scan_raw:gmatch("%[CQ:json,data=([^%]]+)%]") do
                local info = M.extract_json_card_info(d)
                if info and info.url ~= "" then
                    local ak, norm = M.wx_article_key(info.url)
                    if ak and norm and (info.title ~= "" or info.desc ~= "") then
                        card_articles[ak] = card_articles[ak] or {
                            url = norm,
                            title = info.title,
                            summary = (info.desc ~= "" and info.desc ~= info.title) and info.desc or "",
                        }
                    end
                end
            end
            for d in scan_raw:gmatch("%[CQ:xml,data=([^%]]+)%]") do
                local info = M.extract_xml_card_info(d)
                if info and info.url ~= "" then
                    local ak, norm = M.wx_article_key(info.url)
                    if ak and norm and (info.title ~= "" or info.desc ~= "") then
                        card_articles[ak] = card_articles[ak] or {
                            url = norm,
                            title = info.title,
                            summary = (info.desc ~= "" and info.desc ~= info.title) and info.desc or "",
                        }
                    end
                end
            end
            for title, desc, url in scan_raw:gmatch("【分享卡片：([^|】]+)%s*|?%s*([^】]*)】%s*(https?://[^%s]+)") do
                local ak, norm = M.wx_article_key(url)
                if ak and norm then
                    title = title:gsub("^%s+", ""):gsub("%s+$", "")
                    desc = desc:gsub("^%s+", ""):gsub("%s+$", "")
                    card_articles[ak] = card_articles[ak] or {
                        url = norm,
                        title = title,
                        summary = (desc ~= "" and desc ~= title) and desc or "",
                    }
                end
            end
        end

        for _, m in ipairs(messages) do
            local raw = m.raw_message or ""
            local text = m.content or ""
            local fid = raw:match("%[CQ:forward,id=([^,%]]+)%]")
            local full_fwd = fid and M.da_forward_text(fid, true, 0, false) or nil

            local is_bot = is_bot_output(raw) or is_bot_output(text)
            local pure_bot_fwd = false
            if not is_bot and full_fwd and is_bot_output(full_fwd) then
                is_bot = true
                pure_bot_fwd = true
                for _, hit in ipairs(M.extract_wx_urls_from_text(full_fwd)) do
                    if not full_fwd:find("原文链接：" .. hit.url, 1, true) then
                        pure_bot_fwd = false
                        break
                    end
                end
            end

            -- 严格仅从经过零宽水印校验的消息/转发节点中检索搬运
            if is_bot then
                if is_bot_output(raw) or pure_bot_fwd then
                    bot_raw[raw] = true
                end
                if is_bot_output(raw) then
                    register_bot_blocks(raw)
                elseif fid then
                    for _, node_txt in ipairs(M.collect_forward_watermarked_texts(fid)) do
                        register_bot_blocks(node_txt)
                    end
                elseif is_bot_output(text) then
                    register_bot_blocks(text)
                end
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
        local function add_article(url, explicit_key)
            url = normalize_url(url)
            if url == "" then return end
            local ak, norm = M.wx_article_key(url)
            local key = explicit_key or ak or url
            local clean_u = norm or url
            if not aindex[key] then
                aindex[key] = #articles + 1
                articles[#articles + 1] = { url = clean_u, canon_key = key, count = 0 }
            end
            articles[aindex[key]].count = articles[aindex[key]].count + 1
        end

        for _, m in ipairs(messages) do
            local raw = m.raw_message or ""
            if not is_bot_output(raw) and not bot_raw[raw] then
                local fid = raw:match("%[CQ:forward,id=([^,%]]+)%]")
                local scan = (fid and M.da_forward_text(fid, true, 0, false))
                    or ((m.content and m.content ~= "") and m.content or raw)
                collect_card_articles(raw)
                if scan ~= raw then collect_card_articles(scan) end

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
                for _, hit in ipairs(M.extract_wx_urls_from_text(scan)) do
                    add_article(hit.url, hit.key)
                end
                if scan ~= raw then
                    for _, hit in ipairs(M.extract_wx_urls_from_text(raw)) do
                        add_article(hit.url, hit.key)
                    end
                end
            end
        end

        for key, b in pairs(bot_article) do
            if b.url and b.url ~= "" and not aindex[key] then
                add_article(b.url, key)
            end
        end

        for _, a in ipairs(articles) do
            local key = a.canon_key or normalize_url(a.url)
            local b = bot_article[key] or bot_article[normalize_url(a.url)]
            if b then
                a.title = (b.title ~= "" and b.title) or nil
                a.summary = (b.summary ~= "" and b.summary) or nil
                a.from_watermark = true
            end
            if (not a.title or a.title == "") and card_articles[key] then
                local ca = card_articles[key]
                if ca.title and ca.title ~= "" then a.title = ca.title end
                if (not a.summary or a.summary == "") and ca.summary and ca.summary ~= "" then
                    a.summary = ca.summary
                end
            end
        end

        local with_title = 0
        for _, a in ipairs(articles) do
            if (a.title or "") ~= "" then with_title = with_title + 1 end
        end
        jn.log.info(string.format("[%s] 项目水印搬运：%d 个（带图 %d 张）", common.PLUGIN_NAME, #projects, img_total))
        jn.log.info(string.format("[%s] 来源采集：公众号 %d（水印/卡片已有标题 %d）", common.PLUGIN_NAME, #articles, with_title))
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
            raw = M.da_forward_text(fid, true, 0, false)
        else
            raw = tostring(m.content or "")
        end
        local text = clean_quote_text(raw)
        if text == "" then return nil end
        return text
    end

    return M
end
