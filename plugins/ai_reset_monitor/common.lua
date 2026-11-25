-- common.lua — 配置读取、UA、时间解析、静默时段与订阅规则解析

return function(jn)
    local M = {}

    M.PLUGIN_NAME = "ai_reset_monitor"
    M.UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    M.RESET_PRODUCTS = {
        "codex", "antigravity", "claude", "grok", "grok_bot",
        "glm", "qoder", "kimi", "gemini_cli", "cursor",
    }
    M.STATUS_PRODUCTS = {
        "openai_status", "claude_status", "deepseek_status",
    }

    M.PRODUCT_LABELS = {
        codex           = "Codex (OpenAI)",
        antigravity     = "Antigravity (Google)",
        claude          = "Claude / Claude Code",
        grok            = "Grok (xAI)",
        grok_bot        = "Grok Bot (xAI)",
        glm             = "GLM Coding Plan (智谱 / Z.ai)",
        qoder           = "Qoder",
        kimi            = "Kimi / Kimi Code",
        gemini_cli      = "Gemini CLI (Google)",
        cursor          = "Cursor",
        openai_status   = "OpenAI 服务状态",
        claude_status   = "Claude 服务状态",
        deepseek_status = "DeepSeek 服务状态",
    }

    local PRODUCT_ALIAS = {
        codex           = "codex",
        openai_codex    = "codex",
        antigravity     = "antigravity",
        agy             = "antigravity",
        claude          = "claude",
        ["claude-code"] = "claude",
        claude_code     = "claude",
        claudecode      = "claude",
        grok            = "grok",
        ["grok-bot"]    = "grok_bot",
        grok_bot        = "grok_bot",
        grokbot         = "grok_bot",
        glm             = "glm",
        zhipu           = "glm",
        zai             = "glm",
        qoder           = "qoder",
        kimi            = "kimi",
        ["kimi-code"]   = "kimi",
        kimi_code       = "kimi",
        ["gemini-cli"]  = "gemini_cli",
        gemini_cli      = "gemini_cli",
        gemini          = "gemini_cli",
        cursor          = "cursor",
        ["openai-status"]   = "openai_status",
        openai_status       = "openai_status",
        openai              = "openai_status",
        ["claude-status"]   = "claude_status",
        claude_status       = "claude_status",
        ["deepseek-status"] = "deepseek_status",
        deepseek_status     = "deepseek_status",
        deepseek            = "deepseek_status",
    }

    local VALID_STYLES = {
        objective = true,
        persona = true,
        both = true,
        major_persona = true,
    }

    function M.trim(s)
        if s == nil then return "" end
        return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    function M.cfg_bool(key, default)
        local v = jn.config.get(key)
        if v == nil then return default end
        if type(v) == "boolean" then return v end
        local s = M.trim(v):lower()
        if s == "" then return default end
        return s ~= "false" and s ~= "0" and s ~= "no" and s ~= "off"
    end

    function M.cfg_num(key, default)
        local v = jn.config.get(key)
        if v == nil or v == "" then return default end
        local n = tonumber(v)
        if n == nil then return default end
        return n
    end

    function M.cfg_string(key, default)
        local v = jn.config.get(key)
        if v == nil then return default end
        local s = M.trim(v)
        if s == "" then return default end
        return s
    end

    function M.cfg_list(key)
        local v = jn.config.get(key)
        local out = {}
        if type(v) == "table" then
            for _, item in ipairs(v) do
                local s = M.trim(item)
                if s ~= "" then out[#out + 1] = s end
            end
        elseif type(v) == "string" and v ~= "" then
            for line in v:gmatch("[^\r\n]+") do
                local s = M.trim(line)
                if s ~= "" then out[#out + 1] = s end
            end
        end
        return out
    end

    -- ----------------------------------------------------------------
    -- UTF-8 长度与安全截断
    -- ----------------------------------------------------------------
    function M.utf8_len(text)
        text = tostring(text or "")
        local count, i, n = 0, 1, #text
        while i <= n do
            count = count + 1
            local b = text:byte(i)
            local step = 1
            if b >= 240 then step = 4
            elseif b >= 224 then step = 3
            elseif b >= 192 then step = 2 end
            i = i + step
        end
        return count
    end

    function M.clip(text, max_chars)
        text = tostring(text or "")
        if max_chars <= 0 or #text <= max_chars then return text end
        local pos, i, n = {}, 1, #text
        while i <= n do
            pos[#pos + 1] = i
            local b = text:byte(i)
            local step = 1
            if b >= 240 then step = 4
            elseif b >= 224 then step = 3
            elseif b >= 192 then step = 2 end
            i = i + step
            if #pos > max_chars then break end
        end
        if #pos <= max_chars then return text end
        return text:sub(1, pos[max_chars + 1] - 1) .. "…"
    end

    -- ----------------------------------------------------------------
    -- HTML/XML 实体与标签清洗
    -- ----------------------------------------------------------------
    local ENT = {
        amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
        nbsp = " ", mdash = "—", ndash = "–", hellip = "…",
    }

    local function codepoint_to_utf8(cp)
        if cp < 0 or cp > 0x10FFFF then return "" end
        if cp < 0x80 then return string.char(cp) end
        if cp < 0x800 then
            return string.char(
                0xC0 + math.floor(cp / 64),
                0x80 + (cp % 64)
            )
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

    function M.unescape(s)
        if not s or s == "" then return "" end
        s = s:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
        s = s:gsub("&#(%d+);", function(d)
            local n = tonumber(d)
            return n and codepoint_to_utf8(n) or ""
        end)
        s = s:gsub("&#[xX](%x+);", function(h)
            local n = tonumber(h, 16)
            return n and codepoint_to_utf8(n) or ""
        end)
        s = s:gsub("&(%a+);", function(e) return ENT[e] or ("&" .. e .. ";") end)
        return s
    end

    function M.clean_html(s)
        if not s or s == "" then return "" end
        s = M.unescape(s)
        s = s:gsub("<script[^>]->.-</script>", " ")
        s = s:gsub("<style[^>]->.-</style>", " ")
        s = s:gsub("<br%s*/?>", "\n")
        s = s:gsub("</p>", "\n"):gsub("</div>", "\n"):gsub("</li>", "\n")
        s = s:gsub("<[^>]->", "")
        s = M.unescape(s)
        s = s:gsub("[ \t\r]+", " ")
        s = s:gsub(" *\n *", "\n")
        s = s:gsub("\n\n+", "\n")
        return M.trim(s)
    end

    function M.norm_product(raw)
        local s = M.trim(raw):lower()
        return PRODUCT_ALIAS[s]
    end

    function M.norm_style(raw, fallback)
        local s = M.trim(raw):lower()
        if VALID_STYLES[s] then return s end
        return fallback or "both"
    end

    -- ----------------------------------------------------------------
    -- 分群订阅解析
    -- 每行格式: 群号|订阅键列表|可选风格覆写
    -- 返回 { { group_id = number, products = { [key]=true }, style = string|nil }, ... }
    -- ----------------------------------------------------------------
    function M.parse_subscriptions()
        local lines = M.cfg_list("group_subscriptions")
        local groups = {}
        local by_gid = {}

        local function add_product_token(set, tok)
            tok = M.trim(tok):lower()
            if tok == "" then return end
            if tok == "all" or tok == "*" then
                for _, k in ipairs(M.RESET_PRODUCTS) do set[k] = true end
                for _, k in ipairs(M.STATUS_PRODUCTS) do set[k] = true end
                return
            elseif tok == "reset_all" or tok == "resets" then
                for _, k in ipairs(M.RESET_PRODUCTS) do set[k] = true end
                return
            elseif tok == "status_all" or tok == "status" then
                for _, k in ipairs(M.STATUS_PRODUCTS) do set[k] = true end
                return
            end
            local k = M.norm_product(tok)
            if k then set[k] = true end
        end

        for _, line in ipairs(lines) do
            local parts = {}
            for seg in (line .. "|"):gmatch("(.-)|") do
                parts[#parts + 1] = M.trim(seg)
            end
            local gid = tonumber(parts[1])
            if gid and gid > 0 then
                local entry = by_gid[gid]
                if not entry then
                    entry = { group_id = gid, products = {}, style = nil }
                    by_gid[gid] = entry
                    groups[#groups + 1] = entry
                end
                local spec = parts[2]
                if not spec or spec == "" then spec = "all" end
                for tok in spec:gmatch("[^,，%s]+") do
                    add_product_token(entry.products, tok)
                end
                if parts[3] and parts[3] ~= "" and VALID_STYLES[parts[3]:lower()] then
                    entry.style = parts[3]:lower()
                end
            end
        end
        return groups
    end

    function M.subscribed_products_union(subs)
        local u = {}
        for _, g in ipairs(subs or {}) do
            for k, v in pairs(g.products or {}) do
                if v then u[k] = true end
            end
        end
        return u
    end

    -- ----------------------------------------------------------------
    -- 时间解析：RFC 822 / RFC 1123 与 ISO 8601 → UTC Unix 时间戳 / 北京时间字符串
    -- ----------------------------------------------------------------
    local MONTHS = {
        jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
        jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
    }

    local function utc_offset_seconds()
        local now = os.time()
        local local_t = os.date("*t", now)
        local utc_t = os.date("!*t", now)
        local_t.isdst = false
        return os.time(local_t) - os.time(utc_t)
    end

    local LOCAL_OFFSET = utc_offset_seconds()

    local function utc_table_to_epoch(y, m, d, hh, mm, ss)
        local t = os.time({
            year = y, month = m, day = d,
            hour = hh, min = mm, sec = ss, isdst = false,
        })
        return t + LOCAL_OFFSET
    end

    function M.parse_timestamp(raw)
        local s = M.trim(raw)
        if s == "" then return nil end

        -- ISO 8601: 2026-11-23T20:16:58Z / +08:00 / .000Z
        local y, mo, d, hh, mm, ss, tz = s:match(
            "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)[^Z%+%-]*(.*)$"
        )
        if y then
            local ep = utc_table_to_epoch(tonumber(y), tonumber(mo), tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss))
            local sign, th, tm = M.trim(tz):match("^([%+%-])(%d%d):?(%d%d)")
            if sign then
                local off = (tonumber(th) * 3600 + tonumber(tm) * 60) * (sign == "+" and 1 or -1)
                ep = ep - off
            end
            return ep
        end

        -- RFC 822: Mon, 23 Nov 2026 20:16:58 GMT / +0000
        local day_s, mon_s, yr_s, h_s, m_s, s_s, rest = s:match(
            "^%a%a%a,%s*(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s*(.*)$"
        )
        if day_s and MONTHS[mon_s:lower()] then
            local ep = utc_table_to_epoch(tonumber(yr_s), MONTHS[mon_s:lower()], tonumber(day_s),
                tonumber(h_s), tonumber(m_s), tonumber(s_s))
            local sign, th, tm = M.trim(rest):match("^([%+%-])(%d%d)(%d%d)")
            if sign then
                local off = (tonumber(th) * 3600 + tonumber(tm) * 60) * (sign == "+" and 1 or -1)
                ep = ep - off
            end
            return ep
        end

        -- Twitter/X API created_at: Tue Nov 24 00:43:26 +0000 2026
        local x_mon, x_day, x_h, x_m, x_s, x_tz, x_yr = s:match(
            "^%a+%s+(%a%a%a)%s+(%d%d?)%s+(%d%d):(%d%d):(%d%d)%s+([%+%-]%d%d%d%d)%s+(%d%d%d%d)$"
        )
        if x_mon and MONTHS[x_mon:lower()] then
            local ep = utc_table_to_epoch(tonumber(x_yr), MONTHS[x_mon:lower()], tonumber(x_day),
                tonumber(x_h), tonumber(x_m), tonumber(x_s))
            local sign, th, tm = x_tz:match("^([%+%-])(%d%d)(%d%d)$")
            if sign then
                local off = (tonumber(th) * 3600 + tonumber(tm) * 60) * (sign == "+" and 1 or -1)
                ep = ep - off
            end
            return ep
        end

        return nil
    end

    function M.url_encode(str)
        if str == nil then return "" end
        return (tostring(str):gsub("([^%w%-_%.~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end))
    end

    -- 解析用户配置的 x_cookies（支持 Cookie 头字符串或 Cookie-Editor JSON 数组）
    function M.parse_x_cookies(raw)
        local s = M.trim(raw)
        if s == "" then return nil end

        local kv = {}
        if s:sub(1, 1) == "[" or s:sub(1, 1) == "{" then
            local ok, decoded = pcall(jn.json.decode, s)
            if ok and type(decoded) == "table" then
                if decoded[1] ~= nil then
                    for _, item in ipairs(decoded) do
                        if type(item) == "table" and item.name and item.value then
                            kv[tostring(item.name)] = tostring(item.value)
                        end
                    end
                else
                    for k, v in pairs(decoded) do
                        if v ~= nil then kv[tostring(k)] = tostring(v) end
                    end
                end
            end
        end

        if next(kv) == nil then
            -- 兼容前缀带 "Cookie:" 的粘贴格式
            s = s:gsub("^[Cc]ookie:%s*", "")
            for seg in (s .. ";"):gmatch("(.-);") do
                local eq = seg:find("=", 1, true)
                if eq then
                    local k = M.trim(seg:sub(1, eq - 1))
                    local v = M.trim(seg:sub(eq + 1))
                    if k ~= "" and v ~= "" then
                        kv[k] = v
                    end
                end
            end
        end

        local auth_token = M.trim(kv.auth_token or "")
        local ct0 = M.trim(kv.ct0 or "")
        if auth_token == "" or ct0 == "" then
            return nil
        end

        local parts = {
            "auth_token=" .. auth_token,
            "ct0=" .. ct0,
        }
        if kv.twid and kv.twid ~= "" then
            parts[#parts + 1] = "twid=" .. M.trim(kv.twid)
        end

        return {
            auth_token = auth_token,
            ct0 = ct0,
            cookie_header = table.concat(parts, "; "),
        }
    end

    function M.format_cst(epoch_or_raw)
        local ep = type(epoch_or_raw) == "number" and epoch_or_raw or M.parse_timestamp(epoch_or_raw)
        if not ep then return M.trim(epoch_or_raw) end
        -- 强制转为 UTC+8 北京时间显示，不受宿主机时区影响
        return os.date("!%Y-%m-%d %H:%M", ep + 8 * 3600) .. " (UTC+8)"
    end

    function M.now_cst_hm()
        local ep = os.time() + 8 * 3600
        local t = os.date("!*t", ep)
        return t.hour * 60 + t.min
    end

    -- ----------------------------------------------------------------
    -- 夜间静默时段判定（HH:MM-HH:MM，北京时间）
    -- ----------------------------------------------------------------
    function M.is_in_quiet_hours(now_min)
        local spec = M.cfg_string("quiet_hours", "")
        if spec == "" then return false end
        local sh, sm, eh, em = spec:match("^(%d%d?):(%d%d)%s*%-%s*(%d%d?):(%d%d)$")
        if not sh then return false end
        local s_min = tonumber(sh) * 60 + tonumber(sm)
        local e_min = tonumber(eh) * 60 + tonumber(em)
        if s_min == e_min then return false end
        now_min = now_min or M.now_cst_hm()
        if s_min < e_min then
            return now_min >= s_min and now_min < e_min
        end
        -- 跨零点，例如 01:00-07:30 以外如 23:30-07:30
        return now_min >= s_min or now_min < e_min
    end

    -- ----------------------------------------------------------------
    -- 简单 FNV-1a 32位哈希，生成短 key
    -- ----------------------------------------------------------------
    function M.fnv1a_hex(str)
        local hash = 2166136261
        for i = 1, #str do
            local b = str:byte(i)
            -- Lua 5.1 / gopher-lua 无原生 bit32，用算术模拟异或
            local x, a, p = 0, hash, 1
            for _ = 1, 8 do
                local ra = a % 2
                local rb = b % 2
                if ra ~= rb then x = x + p end
                a = math.floor(a / 2)
                b = math.floor(b / 2)
                p = p * 2
            end
            hash = (a * p + x)
            -- 乘 16777619 mod 2^32，分高低 16 位防 double 精度丢失
            local lo = hash % 65536
            local hi = math.floor(hash / 65536) % 65536
            local mul = 16777619
            local mlo = lo * mul
            local mhi = (hi * mul) % 65536
            hash = (mhi * 65536 + mlo) % 4294967296
        end
        return string.format("%08x", hash)
    end

    -- ----------------------------------------------------------------
    -- 零宽水印（与公众号/仓库总结插件同款，兼容两种大小写/空格变体）
    -- ----------------------------------------------------------------
    local WM_TEXT = "Generated by JuanNiang Neo"
    local WM_TEXT_ALT = "Generated By JuanNiangNeo"
    local WM_HEAD = "\239\187\191"
    local WM_ZERO = "\226\128\139"
    local WM_ONE = "\226\128\140"
    local WM_LEGACY = "\226\128\139\226\128\140\226\128\141\239\187\191"

    local function wm_encode(text)
        local bits = {}
        for i = 1, #text do
            local b = text:byte(i)
            for k = 7, 0, -1 do
                bits[#bits + 1] = (math.floor(b / 2 ^ k) % 2 == 1) and WM_ONE or WM_ZERO
            end
        end
        return WM_HEAD .. table.concat(bits)
    end

    M.WATERMARK = wm_encode(WM_TEXT)

    function M.is_bot_output(raw)
        if not raw or raw == "" then return false end
        if raw:find(WM_LEGACY, 1, true) then return true end
        local pos = 1
        while true do
            local p = raw:find(WM_HEAD, pos, true)
            if not p then return false end
            local bytes, cur, nbits, i = {}, 0, 0, p + #WM_HEAD
            while #bytes < 32 do
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
            if #got >= 8 and (WM_TEXT:sub(1, #got) == got or WM_TEXT_ALT:sub(1, #got) == got) then
                return true
            end
            pos = p + #WM_HEAD
        end
    end

    function M.strip_wm(s)
        s = tostring(s or "")
        return (s:gsub("\226\128\139", ""):gsub("\226\128\140", "")
                 :gsub("\226\128\141", ""):gsub("\239\187\191", ""))
    end

    -- ----------------------------------------------------------------
    -- JSON 解码封装（清洗 LLM 代码块包裹）
    -- ----------------------------------------------------------------
    function M.decode_json_loose(raw)
        if not raw or raw == "" then return nil end
        local s = M.trim(raw)
        s = s:gsub("^```[jJ][sS][oO][nN]%s*", ""):gsub("^```%s*", ""):gsub("%s*```$", "")
        local ok, data = pcall(jn.json.decode, s)
        if ok and type(data) == "table" then return data end
        local l, r = s:find("{.*}")
        if l and r then
            local ok2, d2 = pcall(jn.json.decode, s:sub(l, r))
            if ok2 and type(d2) == "table" then return d2 end
        end
        return nil
    end

    return M
end
