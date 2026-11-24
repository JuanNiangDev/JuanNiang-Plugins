-- common.lua — daily_analysis 通用配置、UTF-8 截断、Base64、JSON 转义解析与零宽水印

return function(jn)
    local M = {}

    M.PLUGIN_NAME = "daily_analysis"
    M.TABLE_MESSAGES = "pluggin_daily_analysis_messages"
    M.TABLE_REPORTS = "pluggin_daily_analysis_reports"

    function M.da_bool(key, default)
        local v = jn.config.get(key)
        if v == nil then return default end
        return v ~= false and v ~= "false" and v ~= "0"
    end

    function M.da_num(key, default)
        local n = tonumber(jn.config.get(key))
        return n or default
    end

    function M.da_string(key, default)
        local v = jn.config.get(key)
        if v == nil or v == "" then return default end
        return tostring(v)
    end

    -- ----------------------------------------------------------------
    -- UTF-8 安全截断
    -- ----------------------------------------------------------------
    function M.utf8_offsets(s)
        local pos, i, n = {}, 1, #s
        while i <= n do
            pos[#pos + 1] = i
            local b = s:byte(i)
            local step = 1
            if b >= 240 then step = 4
            elseif b >= 224 then step = 3
            elseif b >= 192 then step = 2 end
            i = i + step
        end
        return pos
    end

    function M.clip(text, max)
        text = tostring(text or "")
        if max <= 0 then return "" end
        if #text <= max then return text end
        local pos = M.utf8_offsets(text)
        if #pos <= max then return text end
        return text:sub(1, pos[max + 1] - 1) .. "…"
    end

    -- 单条超长消息保留首尾（约 75% 开头 + 20% 结尾）
    function M.clip_head_tail(text, max)
        text = tostring(text or "")
        if max <= 0 then return "" end
        if #text <= max then return text end
        local pos = M.utf8_offsets(text)
        local total = #pos
        if total <= max then return text end
        local head_n = math.max(1, math.floor(max * 0.75))
        local tail_n = math.max(0, max - head_n - 20)
        local head = text:sub(1, pos[head_n + 1] - 1)
        if tail_n <= 0 then
            return head .. string.format("\n…（已截断，原长 %d 字）", total)
        end
        local tail_idx = math.max(head_n + 1, total - tail_n + 1)
        return head .. string.format("\n…（已截断，原长 %d 字）…\n", total) .. text:sub(pos[tail_idx])
    end

    -- ----------------------------------------------------------------
    -- Base64 解码（分块 flush，防 gopher-lua registry overflow）
    -- ----------------------------------------------------------------
    local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local B64IDX = {}
    for i = 1, #B64 do B64IDX[B64:sub(i, i)] = i - 1 end

    function M.b64_decode(s)
        if not s or s == "" then return "" end
        s = s:gsub("[^" .. B64 .. "=]", "")
        local acc, out, nacc, bits = "", {}, 0, 0
        for i = 1, #s do
            local ch = s:sub(i, i)
            if ch == "=" then break end
            local v = B64IDX[ch]
            if v then
                nacc = nacc * 64 + v
                bits = bits + 6
                if bits >= 8 then
                    bits = bits - 8
                    out[#out + 1] = string.char(math.floor(nacc / 2 ^ bits) % 256)
                    nacc = nacc % 2 ^ bits
                end
            end
            if #out >= 512 then
                acc = acc .. table.concat(out)
                out = {}
            end
        end
        if #out > 0 then acc = acc .. table.concat(out) end
        return acc
    end

    -- ----------------------------------------------------------------
    -- JSON 字符串控制字符转义与健壮解析（1KB 分块缓冲防大表栈溢出）
    -- ----------------------------------------------------------------
    function M.safe_concat(list, sep)
        local n = #list
        if n == 0 then return "" end
        sep = sep or ""
        if n <= 512 then return table.concat(list, sep) end
        local chunks = {}
        for i = 1, n, 512 do
            chunks[#chunks + 1] = table.concat(list, sep, i, math.min(n, i + 511))
        end
        return M.safe_concat(chunks, sep)
    end

    function M.escape_json_string_controls(src)
        if not src or src == "" then return src end
        local out, buf = {}, {}
        local function flush()
            if #buf > 0 then
                out[#out + 1] = table.concat(buf)
                buf = {}
            end
        end
        local in_str, esc = false, false
        for i = 1, #src do
            local c = src:sub(i, i)
            local r = c
            if in_str then
                if esc then
                    esc = false
                elseif c == "\\" then
                    esc = true
                elseif c == '"' then
                    in_str = false
                elseif c == "\n" then
                    r = "\\n"
                elseif c == "\r" then
                    r = "\\r"
                elseif c == "\t" then
                    r = "\\t"
                elseif c == "\b" then
                    r = "\\b"
                elseif c == "\f" then
                    r = "\\f"
                elseif c:byte() < 32 then
                    r = string.format("\\u%04x", c:byte())
                end
            elseif c == '"' then
                in_str = true
                esc = false
            end
            buf[#buf + 1] = r
            if #buf >= 1024 then flush() end
        end
        flush()
        return M.safe_concat(out)
    end

    function M.decode_llm_json(raw, tag)
        if not raw or raw == "" then return nil, "empty" end
        local json_str = raw:match("```json%s*(.-)%s*```") or raw:match("```%s*(.-)%s*```") or raw

        local function try_decode(src)
            if not src or src == "" then return nil, "empty" end
            local ok, res = pcall(jn.json.decode, M.escape_json_string_controls(src))
            if ok and type(res) == "table" then return res, nil end
            return nil, res
        end

        local res, err = try_decode(json_str)
        if res then return res, nil end

        local s = json_str:find("{", 1, true)
        local e = json_str:match(".*()}")
        if s and e and e > s then
            res, err = try_decode(json_str:sub(s, e))
            if res then return res, nil end
        end

        jn.log.warn("[" .. M.PLUGIN_NAME .. "] " .. (tag or "LLM") .. " JSON 解析失败: " .. tostring(err)
            .. " head=" .. json_str:sub(1, 300):gsub("\n", "\\n"))
        return nil, tostring(err)
    end

    -- ----------------------------------------------------------------
    -- 零宽水印与文本清洗
    -- ----------------------------------------------------------------
    local WM_TEXT = "Generated by JuanNiang Neo"
    local WM_HEAD = "\239\187\191"
    local WM_ZERO = "\226\128\139"
    local WM_ONE = "\226\128\140"
    local WM_LEGACY = "\226\128\139\226\128\140\226\128\141\239\187\191"

    function M.is_bot_output(raw)
        if not raw or raw == "" then return false end
        if raw:find(WM_LEGACY, 1, true) then return true end
        local pos = 1
        while true do
            local p = raw:find(WM_HEAD, pos, true)
            if not p then return false end
            local bytes, cur, nbits, i = {}, 0, 0, p + #WM_HEAD
            while #bytes < 8 do
                local ch = raw:sub(i, i + 2)
                if ch == WM_ZERO then
                    cur = cur * 2; nbits = nbits + 1
                elseif ch == WM_ONE then
                    cur = cur * 2 + 1; nbits = nbits + 1
                else
                    break
                end
                if nbits == 8 then
                    bytes[#bytes + 1] = string.char(cur)
                    cur, nbits = 0, 0
                end
                i = i + 3
            end
            local got = table.concat(bytes)
            if #got >= 8 and WM_TEXT:sub(1, #got) == got then return true end
            pos = p + #WM_HEAD
        end
    end

    function M.strip_wm(s)
        s = tostring(s or "")
        return (s:gsub("\226\128\139", ""):gsub("\226\128\140", "")
                 :gsub("\226\128\141", ""):gsub("\239\187\191", ""))
    end

    function M.clean_quote_text(s)
        s = tostring(s or "")
        s = s:gsub("【回复.-」】", "")
        s = s:gsub("%[CQ:[^%]]*%]", "")
        s = s:gsub("%[图片[^%]]*%]", "")
        s = s:gsub("\r", "")
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        s = s:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
        return s
    end

    function M.normalize_url(u)
        u = tostring(u or ""):gsub("&amp;", "&")
        return (u:gsub("[%)%,%.%!%?%;:]+$", ""))
    end

    function M.cq_unescape(s)
        s = tostring(s or "")
        return (s:gsub("&amp;", "&"):gsub("&#44;", ","):gsub("&#91;", "["):gsub("&#93;", "]"))
    end

    return M
end
