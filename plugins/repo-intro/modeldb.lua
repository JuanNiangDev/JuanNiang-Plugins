-- modeldb.lua — Hugging Face / ModelScope 模型规格、上下文、模态与定价渲染（card-6）

return function(jn)
    local M = {}

    local modeldb = nil
    local function modeldb_load()
        if modeldb then return modeldb end
        local content = jn.file.read("data/modeldb.json")
        if not content then
            jn.log.warn("[repo-intro] modeldb.json 读取失败")
            return nil
        end
        local ok, parsed = pcall(jn.json.decode, content)
        if not ok or type(parsed) ~= "table" then
            jn.log.warn("[repo-intro] modeldb.json 解析失败")
            return nil
        end
        modeldb = parsed
        return modeldb
    end

    local function norm_key(s)
        if not s then return "" end
        return (s:lower():gsub("[^%w]", ""))
    end

    local SUFFIXES = { "instruct", "chat", "base", "it", "latest", "free", "v1", "v2", "v3" }

    function M.find(hf_id)
        local db = modeldb_load()
        if not db or not db.alias then return nil end
        local function lookup(nk)
            if nk == "" then return nil end
            local key = db.alias[nk]
            if key then return key end
            for _, sfx in ipairs(SUFFIXES) do
                local k2 = db.alias[nk .. sfx]
                if k2 then return k2 end
                if nk:sub(-#sfx) == sfx then
                    k2 = db.alias[nk:sub(1, -#sfx - 1)]
                    if k2 then return k2 end
                end
            end
            return nil
        end
        local key = lookup(norm_key(hf_id))
        if not key then
            local bare = tostring(hf_id):match("([^/]+)$")
            if bare then key = lookup(norm_key(bare)) end
        end
        if not key or not db.models then return nil end
        return db.models[key]
    end

    local function fmt_params_count(n)
        n = tonumber(n)
        if not n or n <= 0 then return nil end
        local function trim0(s) return (s:gsub("%.?0+$", "")) end
        if n >= 1e12 then return trim0(string.format("%.1f", n / 1e12)) .. "T" end
        if n >= 1e11 then return string.format("%.0f", n / 1e9) .. "B" end
        if n >= 1e9 then return trim0(string.format("%.1f", n / 1e9)) .. "B" end
        if n >= 1e8 then return string.format("%.0f", n / 1e6) .. "M" end
        if n >= 1e6 then return trim0(string.format("%.1f", n / 1e6)) .. "M" end
        if n >= 1e4 then return string.format("%.0f", n / 1e3) .. "K" end
        return tostring(n)
    end

    local function params_from_name(name)
        if not name or name == "" then return nil end
        local init = 1
        while true do
            local s, e, num, unit = name:find("(%d+%.?%d*)([BM])", init)
            if not s then return nil end
            local nxt = name:sub(e + 1, e + 1)
            if nxt == "" or not nxt:match("[%w]") then
                local v = tonumber(num)
                if v and v > 0 then
                    return unit == "B" and v * 1e9 or v * 1e6
                end
            end
            init = e + 1
        end
    end

    local function params_from_readme(readme)
        if not readme or readme == "" then return nil end
        for line in readme:sub(1, 6000):gmatch("[^\n]+") do
            local low = line:lower()
            if low:find("param", 1, true) or line:find("参数量", 1, true) or line:find("参数", 1, true) then
                local num, unit = line:match("(%d+%.?%d*)%s*([BMT])")
                local v = tonumber(num)
                if v and v > 0 then
                    if unit == "T" then v = v * 1e12
                    elseif unit == "M" then v = v * 1e6
                    else v = v * 1e9 end
                    return v
                end
            end
        end
        return nil
    end

    local function model_params(e, mi)
        local total, known = nil, false
        local p = e.meta and e.meta.params
        if p then
            local s = fmt_params_count(p)
            if s then total, known = s, true end
        end
        if not known then
            local mp = mi and mi.params
            if mp and mp ~= "" then
                local num = tonumber(mp:match("^([%d%.]+)"))
                if not (mp:match("T$") and num and num > 10) then
                    total, known = tostring(mp), true
                end
            end
        end
        if not known then
            local from_name = params_from_name((e.meta and e.meta.name)
                or ((e.owner or "") .. "/" .. (e.repo or "")))
            if from_name then total, known = fmt_params_count(from_name), true end
        end
        if not known then
            local from_readme = params_from_readme(e.readme)
            if from_readme then total, known = fmt_params_count(from_readme), true end
        end
        if not known then return "—", false end
        local name = (e.meta and e.meta.name) or (e.owner .. "/" .. e.repo)
        local act = name:match("A(%d+%.?%d*)B")
        if act then
            local a = act:gsub("%.0+$", "")
            if a == "" then a = act end
            return total .. "(A" .. a .. "B)", true
        end
        return total, true
    end

    local function fmt_context(n)
        n = tonumber(n)
        if not n or n <= 0 then return "—" end
        if n >= 1000000 then
            local m = n / 1000000
            return string.format("%.1f", m):gsub("%.?0+$", "") .. "M"
        end
        if n >= 1024 then
            return tostring(math.floor((n + 512) / 1024)) .. "k"
        end
        return tostring(n)
    end

    local function ctx_from_readme(readme)
        if not readme or readme == "" then return nil end
        for line in readme:sub(1, 8000):gmatch("[^\n]+") do
            local low = line:lower()
            local pos = low:find("context", 1, true) or line:find("上下文", 1, true)
            if pos then
                local tail = line:sub(pos, math.min(#line, pos + 60))
                local head = line:sub(math.max(1, pos - 24), pos)
                local function parse(seg)
                    local wan = seg:match("(%d+%.?%d*)%s*万")
                    if wan then return tonumber(wan) * 10000 end
                    local num, unit = seg:match("(%d+%.?%d*)%s*([kKmM]?)")
                    local v = tonumber(num)
                    if not v then return nil end
                    local u = string.lower(unit or "")
                    if u == "k" then v = v * 1024
                    elseif u == "m" then v = v * 1048576 end
                    if v < 128 then return nil end
                    return v
                end
                local v = parse(tail) or parse(head)
                if v then return v end
            end
        end
        return nil
    end

    local function model_ctx(e, mi)
        local c = tonumber(mi and mi.ctx)
        if c and c > 0 then return c end
        return ctx_from_readme(e.readme)
    end

    local MOD_ICONS = {
        text   = { '<svg class="ico" viewBox="0 0 16 16"><path d="M2 1h7l4 4v10H2V1zm2 2v2h5V3H4zm0 4v1h8V7H4zm0 3v1h8v-1H4z"/></svg>', "文本" },
        image  = { '<svg class="ico" viewBox="0 0 16 16"><path d="M2 2h12v12H2V2zm1 1v6l3-3 2 2 2-2 3 3V3H3zm2 2a1 1 0 1 0 0-2 1 1 0 0 0 0 2z"/></svg>', "图片" },
        audio  = { '<svg class="ico" viewBox="0 0 16 16"><path d="M11 1.5v9a2.5 2.5 0 1 1-1-2.03V5.1L5 6.3v6.2a2.5 2.5 0 1 1-1-2.03V5.1L11 1.5z"/></svg>', "音频" },
        video  = { '<svg class="ico" viewBox="0 0 16 16"><path d="M0 3h16v10H0V3zm2 2v6h12V5H2zm3 1.5v3L9 8 5 6.5z"/></svg>', "视频" },
        pdf    = { '<svg class="ico" viewBox="0 0 16 16"><path d="M2 1h8l4 4v10H2V1zm4 3v1h4V4H6zm0 3v1h6V7H6zm0 3v1h6v-1H6z"/></svg>', "PDF" },
        tool   = { '<svg class="ico" viewBox="0 0 16 16"><path d="M7 1h2v3h3v2H9v3H7V6H4V4h3V1zM4 9h2v2H4V9zm8 0h2v2h-2V9zm-8 4h2v2H4v-2zm8 0h2v2h-2v-2z"/></svg>', "工具" },
    }

    local function model_modality_html(mi)
        local md = mi and mi.md or {}
        local parts = {}
        for _, mod in ipairs(md) do
            local entry = MOD_ICONS[mod]
            if entry then
                parts[#parts + 1] = '<span class="mod-item">' .. entry[1] .. entry[2] .. '</span>'
            end
        end
        if #parts == 0 then return "" end
        return table.concat(parts)
    end

    local function fmt_price(v)
        v = tonumber(v)
        if not v then return nil end
        if v == 0 then return "免费" end
        if v < 0.01 then return string.format("%.3f", v) end
        if v < 1 then return string.format("%.2f", v) end
        return string.format("%.2f", v)
    end

    local CN_PROVIDERS = {
        deepseek = true, qwen = true, alibaba = true, zhipu = true, chatglm = true, glm = true,
        kimi = true, moonshot = true, doubao = true, volc = true, volcengine = true, baidu = true, hunyuan = true,
        tencent = true, minimax = true, bytedance = true, iflytek = true, xfyun = true, stepfun = true, ernie = true,
        spark = true, ["01ai"] = true, minimaxai = true,
    }

    local function is_cn_model(e, mi)
        if mi and mi.cn then return true end
        if mi and mi.pl and mi.pl ~= "" then return true end
        local low = ((e.meta and e.meta.name) or (e.owner .. "/" .. e.repo)):lower()
        for org in pairs(CN_PROVIDERS) do
            if low:find(org, 1, true) then return true end
        end
        return false
    end

    local function model_pricing_html(e, mi)
        local pr = mi and mi.pr or {}
        if #pr == 0 then
            local c = mi and mi.cost
            if type(c) == "table" then
                local ci, co, cc = tonumber(c.input), tonumber(c.output), tonumber(c.cache)
                if ci or co then
                    pr = { { cur = "USD", tier = "standard", input = ci, output = co, cache = cc } }
                end
            end
        end
        if #pr == 0 then
            if mi then return '<div class="price-title">价格 · 未公开</div>' end
            return '<div class="price-title">价格 · 开放权重</div>'
        end
        local cn = is_cn_model(e, mi)
        local sym, cur = cn and "¥" or "$", cn and "CNY" or "USD"
        local USD_RATE = 7.2
        local function conv(v)
            if not v then return nil end
            return math.floor(v * USD_RATE * 100 + 0.5) / 100
        end
        local std, off, tiers = {}, {}, {}
        local function collect(p)
            if p.cur == cur then
                if p.tier == "off_peak" then off[#off + 1] = p
                elseif (p.min ~= nil and p.min ~= 0) or p.max ~= nil then tiers[#tiers + 1] = p
                else std[#std + 1] = p end
            end
        end
        for _, p in ipairs(pr) do collect(p) end
        if #std == 0 and #off == 0 and #tiers == 0 and cn then
            for _, p in ipairs(pr) do
                if p.cur == "USD" then
                    collect({ cur = "CNY", tier = p.tier, min = p.min, max = p.max,
                        input = conv(p.input), output = conv(p.output),
                        thinking = conv(p.thinking), cache = conv(p.cache) })
                end
            end
        end
        local rows = {}
        if #tiers == 0 then
            local s = std[1]
            if s then
                local ii, oo = fmt_price(s.input), fmt_price(s.output)
                local kv = {}
                if ii and oo then
                    kv[#kv + 1] = '输入 <b>' .. sym .. ii .. '</b>'
                    kv[#kv + 1] = '输出 <b>' .. sym .. oo .. '</b>'
                end
                local th = fmt_price(s.thinking)
                if th and oo and th ~= oo then
                    kv[#kv + 1] = '思考 <b class="price-think">' .. sym .. th .. '</b>'
                end
                local cc = fmt_price(s.cache)
                if cc then kv[#kv + 1] = '缓存 <b>' .. sym .. cc .. '</b>' end
                if #kv > 0 then rows[#rows + 1] = '<div class="price-row">' .. table.concat(kv, ' · ') .. '</div>' end
            end
        end
        local o = off[1]
        if o then
            local ii, oo = fmt_price(o.input), fmt_price(o.output)
            if ii and oo then
                rows[#rows + 1] = '<div class="price-row price-offpeak">闲时 · 输入 <b>' .. sym .. ii
                    .. '</b> · 输出 <b>' .. sym .. oo .. '</b></div>'
            end
        end
        if #tiers > 0 then
            local tkv, seen = {}, {}
            for _, t in ipairs(tiers) do
                local ii, oo = fmt_price(t.input), fmt_price(t.output)
                if ii and oo then
                    local rng = (t.max == nil or t.max == 0) and ('>' .. fmt_context(t.min) .. ' ctx')
                        or ('≤' .. fmt_context(t.max) .. ' ctx')
                    local rk = tostring(t.input or "") .. "/" .. tostring(t.output or "")
                    if not seen[rk] then
                        seen[rk] = true
                        tkv[#tkv + 1] = rng .. ' <b>' .. sym .. ii .. '/' .. sym .. oo .. '</b>'
                    end
                end
            end
            if #tkv > 0 then
                rows[#rows + 1] = '<div class="price-row price-tier">上下文：' .. table.concat(tkv, ' · ') .. '</div>'
            end
        end
        if #rows == 0 then return "" end
        return '<div class="price-title">价格 · ' .. (cur == "CNY" and "CNY" or "USD") .. '</div>'
            .. table.concat(rows)
    end

    local function escape_html(s)
        return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
    end

    local function meta_chips(e, mi)
        local val, known = model_params(e, mi)
        local ctx = model_ctx(e, mi)
        local chips = {}
        if known then
            chips[#chips + 1] = '<span class="chip"><span class="lbl">参数量</span><span class="val">'
                .. val .. '</span></span>'
        end
        if ctx then
            chips[#chips + 1] = '<span class="chip"><span class="lbl">上下文</span><span class="val">'
                .. fmt_context(ctx) .. '</span></span>'
        end
        if #chips == 0 then
            local t = (e.llm and e.llm.type) or ""
            if t ~= "" then
                chips[#chips + 1] = '<span class="chip"><span class="lbl">类型</span><span class="val">'
                    .. escape_html(t) .. '</span></span>'
            end
        end
        return chips[1] or "", chips[2] or ""
    end

    function M.fill_model_template(tpl, e)
        local m = e.meta or {}
        local mi = M.find(m.name or (e.owner .. "/" .. e.repo))
        local chip1, chip2 = meta_chips(e, mi)
        local modality = model_modality_html(mi)
        local avatar_url = nil
        if m.avatar_src ~= nil and m.avatar_src ~= "" then
            avatar_url = (m.avatar_src:find("huggingface.co", 1, true) ~= nil)
                and ("https://wsrv.nl/?url=" .. m.avatar_src .. "&w=280&h=280&fit=cover")
                or m.avatar_src
        elseif m.avatar ~= nil and m.avatar ~= "" then
            avatar_url = m.avatar
        end
        local avatar_html, title_class = "", " no-avatar"
        if avatar_url then
            avatar_html = '<div class="avatar"><img src="' .. avatar_url
                .. '" onerror="this.parentNode.style.display=\'none\'" alt=""></div>'
            title_class = ""
        end
        local data = {
            OWNER = e.owner,
            REPO = e.repo,
            AVATAR_HTML = avatar_html,
            TITLE_CLASS = title_class,
            PARAMS_CHIP = chip1,
            CONTEXT_CHIP = chip2,
            MOD_HINT = (modality ~= "" and '<span class="mod-hint">输入</span>' or ""),
            MODALITY_HTML = modality,
            PRICING_HTML = model_pricing_html(e, mi),
        }
        local out = tpl
        for k, v in pairs(data) do
            out = out:gsub("{{" .. k .. "}}", function() return tostring(v) end)
        end
        return out
    end

    return M
end
