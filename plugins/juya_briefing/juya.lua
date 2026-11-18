-- ============================================================================
-- juya.lua — 橘鸦 AI 早报（daily.juya.uk）抓取与解析
-- ----------------------------------------------------------------------------
-- 该站点每天一期：RSS 的每个 <item> 是「一期」的入口（标题为日期，链到
-- /issues/<date>/），正文页面才是服务端渲染的新闻列表：
--   <h2>分类</h2> <section class="news-item">
--     <h3><a href="主来源">标题</a></h3>
--     <blockquote>摘要</blockquote>
--     <div class="news-body-content">详情</div>
--     <a href="来源1">…</a> <a href="来源2">…</a>
--   </section> …
-- 同一事件的多家报道在页面里已合并为一条（多个来源链接），无需再做聚类。
-- ----------------------------------------------------------------------------
-- 由调用方经 loadstring 注入 jn（引擎未给插件目录挂 package.path）
return function(jn)
local M = {}

local ENT = { amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'", nbsp = " " }

local function unescape(s)
    if not s or s == "" then return "" end
    s = s:gsub("&#(%d+);", function(d)
        local n = tonumber(d)
        if not n or n > 127 then return "" end
        return string.char(n)
    end)
    s = s:gsub("&#[xX](%x+);", function(h)
        local n = tonumber(h, 16)
        if not n or n > 127 then return "" end
        return string.char(n)
    end)
    s = s:gsub("&(%a+);", function(e) return ENT[e] or "" end)
    return s
end

local function norm_ws(s)
    s = tostring(s or ""):gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 去标签：先删展开按钮（其文本是「…」「−」），再删其余标签
local function strip_tags(s)
    if not s or s == "" then return "" end
    s = s:gsub("<button[^>]->.-</button>", " ")
    s = s:gsub("<[^>]->", "")
    return unescape(s)
end

local function clean(s) return norm_ws(strip_tags(s)) end

-- GET 一个 URL，返回 body 或 nil, err
function M.get(url)
    if not (url and url ~= "") then return nil, "空 URL" end
    if not (jn.http and jn.http.get) then return nil, "缺少 http 权限" end
    local ok, res, err = pcall(jn.http.get, url)
    if not ok then return nil, tostring(res) end
    if not res then return nil, tostring(err or "请求失败") end
    local status = tonumber(res.status) or 0
    if status ~= 200 then return nil, "HTTP " .. tostring(status) end
    local body = res.body
    if type(body) ~= "string" or body == "" then return nil, "空响应" end
    return body
end

-- 解析 RSS，取最新一期的 <link>
function M.latest_issue_from_rss(rss_url)
    local body, err = M.get(rss_url)
    if not body then return nil, err end
    local item = body:match("<item>(.-)</item>")
    if not item then return nil, "RSS 无 item" end
    local link = item:match("<link>%s*<!%[CDATA%[(.-)%]%]>")
        or item:match("<link>([^<]+)</link>")
        or item:match('<link[^>]-href="([^"]+)"')
    if not link then return nil, "RSS item 无 link" end
    return (unescape(link):gsub("%s+$", ""))
end

-- 从 <h2> 切分类；返回 {{name=, body=}}
local function split_categories(html)
    local cats, prev_end, prev_name = {}, nil, nil
    local init = 1
    while true do
        local s, e, name = html:find("<h2[^>]->(.-)</h2>", init)
        if not s then break end
        if prev_end then
            cats[#cats + 1] = { name = clean(prev_name), body = html:sub(prev_end, s - 1) }
        end
        prev_end, prev_name = e + 1, name
        init = e + 1
    end
    if prev_end then cats[#cats + 1] = { name = clean(prev_name), body = html:sub(prev_end) } end
    return cats
end

local function parse_item(seg)
    local it = { links = {}, seen = {} }
    local href, ttl = seg:match('<h3[^>]->%s*<a href="([^"]+)"[^>]->(.-)</a>')
    it.url = unescape(href or "")
    it.title = clean(ttl or "")
    if it.title == "" then return nil end

    local q = seg:match("<blockquote>(.-)</blockquote>")
    it.summary = clean(q or "")
    local d = seg:match('<div class="news%-body%-content">(.-)</div>')
    it.detail = clean(d or it.summary)

    local function add_link(u, text)
        u = unescape(u)
        if u == "" or it.seen[u] then return end
        it.seen[u] = true
        local label = norm_ws(text or "")
        if label == "" then
            label = u:gsub("^https?://", ""):gsub("/$", "")
        end
        it.links[#it.links + 1] = { url = u, text = label }
    end

    -- 配图（正文里的 <img src>，站点用的是绝对地址 assets.juya.uk）
    it.images = {}
    local iseen = {}
    for img in seg:gmatch('<img[^>]-src="([^"]+)"') do
        if img ~= "" and not iseen[img] then
            iseen[img] = true
            it.images[#it.images + 1] = unescape(img)
        end
    end

    -- 主链排最前，其余按出现顺序
    if it.url ~= "" then add_link(it.url, it.title) end
    for u, text in seg:gmatch('<a[^>]-href="(https?://[^"]+)"[^>]->(.-)</a>') do
        add_link(u, clean(text))
    end
    return it
end

-- 解析一期页面 → {{name=分类, items={{title,url,summary,detail,links}}}}
function M.parse_issue(html)
    local out = {}
    for _, c in ipairs(split_categories(html)) do
        local items, p = {}, 1
        while true do
            local s, e = c.body:find('<section class="news%-item">', p)
            if not s then break end
            local se = c.body:find("</section>", e)
            if not se then break end
            local it = parse_item(c.body:sub(e + 1, se - 1))
            if it then items[#items + 1] = it end
            p = se + #"</section>"
        end
        if #items > 0 then out[#out + 1] = { name = c.name, items = items } end
    end
    return out
end

-- 拉取「当天」那一期：issue 模板优先，失败回退 RSS 最新一期
-- feeds = { rss = "...", issue = "https://.../issues/{date}/" }
-- 返回 url, html, source("issue"|"rss"), err
function M.fetch_issue(feeds, date)
    date = date or os.date("%Y-%m-%d")
    if feeds and feeds.issue and feeds.issue ~= "" then
        local url = feeds.issue:gsub("{date}", date)
        local body, err = M.get(url)
        if body and body:find('class="news%-item"') then
            return url, body, "issue"
        end
        if body then return nil, nil, nil, "期号页无新闻内容" end
        -- 404/超时都视为「当天没出刊」，交给 RSS 兜底
        if err and not err:find("HTTP 404", 1, true) then
            jn.log.warn("[juya] 抓期号页失败: " .. tostring(err))
        end
    end
    if feeds and feeds.rss and feeds.rss ~= "" then
        local link, err = M.latest_issue_from_rss(feeds.rss)
        if not link then return nil, nil, nil, "RSS 取期失败: " .. tostring(err) end
        local body, err2 = M.get(link)
        if not body then return nil, nil, nil, "期号页抓取失败: " .. tostring(err2) end
        return link, body, "rss", nil
    end
    return nil, nil, nil, "未配置 RSS / 期号页"
end

-- 从期号 URL 里取日期（https://daily.juya.uk/issues/2026-11-18/）
function M.issue_date(url)
    return tostring(url or ""):match("/issues/(%d%d%d%d%-%d%d%-%d%d)")
end

-- 扁平化：返回 {{category=, title=, url=, summary=, detail=, links=}}，按页面顺序
function M.flatten(cats)
    local out = {}
    for _, c in ipairs(cats or {}) do
        for _, it in ipairs(c.items) do
            out[#out + 1] = {
                category = c.name, title = it.title, url = it.url,
                summary = it.summary, detail = it.detail, links = it.links, images = it.images or {},
            }
        end
    end
    return out
end

-- 把全部来源链接压成一行（去重，最多 max 条）
function M.links_text(links, max)
    max = max or 6
    local parts = {}
    for i, l in ipairs(links or {}) do
        if i > max then break end
        parts[#parts + 1] = l.url
    end
    return table.concat(parts, "\n")
end

return M
end
