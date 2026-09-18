-- ====================================================================
-- MeT_Music
-- 基于 MeT Music API 的点歌插件
--
-- 命令：
--   /music search <关键词> [数量]  搜索歌曲（默认 5 首），T2I 渲染结果图
--   /music play <编号>             播放搜索结果中的歌曲（自定义音乐卡片）
--   /music                          查看命令说明 + 支持 MeT Music 项目
--
-- API（默认 https://music.met6.top:444，可面板配置）：
--   GET /api/web/cloudsearch?keywords=&limit=&offset=&type=1  搜索
--   GET /api/meting/?type=url&id=<mid>                        音频直链（302 跳转）
--
-- 搜索结果缓存 10 分钟（群+用户隔离），期间可用编号播放。
-- ====================================================================

local jn = require("jn")

local DEFAULT_LIMIT = 5
local MAX_LIMIT = 10
local SEARCH_TTL = 600 -- 搜索结果缓存秒数

-- ====================================================================
-- 工具函数
-- ====================================================================

local function url_encode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function html_escape(s)
    return (tostring(s)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64_sub(buf, lo, hi)
    local v = math.floor(buf / 2 ^ lo) % 2 ^ (hi - lo + 1)
    return B64_CHARS:sub(v + 1, v + 1)
end

--- 纯 Lua base64 编码（封面图转 data URI 用，渲染环境无外网）
local function b64encode(data)
    local out = {}
    local i, n = 1, #data
    while i <= n do
        local a, b, c = data:byte(i) or 0, data:byte(i + 1), data:byte(i + 2)
        local buf = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = b64_sub(buf, 18, 23) .. b64_sub(buf, 12, 17)
            .. (b and b64_sub(buf, 6, 11) or "=")
            .. (c and b64_sub(buf, 0, 5) or "=")
        i = i + 3
    end
    return table.concat(out)
end

local function fmt_duration(ms)
    local total = math.floor((tonumber(ms) or 0) / 1000)
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function join_artists(song)
    local names = {}
    if type(song.ar) == "table" then
        for _, a in ipairs(song.ar) do
            names[#names + 1] = tostring(a.name or "")
        end
    end
    if #names == 0 then return "未知歌手" end
    return table.concat(names, " / ")
end

local function api_base()
    local base = tostring(jn.config.get("base_url") or "https://music.met6.top:444")
    return (base:gsub("/+$", ""))
end

local function cache_key(event)
    return string.format("metm:search:%s:%s", tostring(event.group_id or 0), tostring(event.user_id or 0))
end

-- 按事件回复（群聊回群聊，私聊回私聊）
local function reply(event, message)
    if (tonumber(event.group_id) or 0) ~= 0 then
        return jn.onebot11.send_group_msg(tonumber(event.group_id), message)
    end
    return jn.onebot11.send_private_msg(tonumber(event.user_id), message)
end

-- ====================================================================
-- 搜索结果渲染（T2I）
-- ====================================================================

local template_cache = nil
local function get_template()
    if template_cache == nil then
        local content, err = jn.file.read("search_result.html")
        if not content then
            jn.log.error("[MeT_Music] 读取结果模板失败: " .. (err or "unknown"))
            template_cache = ""
        else
            template_cache = content
        end
    end
    return template_cache ~= "" and template_cache or nil
end

-- 封面下载转 base64（渲染环境无外网，外链图不可用）；失败返回 nil 走占位样式
local function fetch_cover_b64(pic_url)
    if type(pic_url) ~= "string" or pic_url == "" then return nil end
    local resp, err = jn.http.get(pic_url)
    if err or not resp or resp.status ~= 200 or resp.body == "" then
        jn.log.warn("[MeT_Music] 封面下载失败: " .. tostring(pic_url))
        return nil
    end
    local mime = pic_url:find("%.png", 1, true) and "image/png" or "image/jpeg"
    return "data:" .. mime .. ";base64," .. b64encode(resp.body)
end

local function build_rows_html(songs)
    local rows = {}
    for i, song in ipairs(songs) do
        local album = (song.al and type(song.al) == "table") and tostring(song.al.name or "") or ""
        local sub = join_artists(song)
        if album ~= "" then sub = sub .. " · " .. album end
        local badge = tonumber(song.fee) == 1
            and '<span class="vip">VIP</span>'
            or '<span class="free">免费</span>'
        local cover_html
        local b64 = fetch_cover_b64(song.al and song.al.picUrl)
        if b64 then
            cover_html = string.format('<img class="cover" src="%s">', b64)
        else
            cover_html = '<div class="cover"></div>'
        end
        rows[#rows + 1] = table.concat({
            '<div class="song">',
            '<div class="idx">' .. i .. '</div>',
            cover_html,
            '<div class="info">',
            '<div class="name">' .. html_escape(song.name or "未知曲目") .. '</div>',
            '<div class="sub">' .. html_escape(sub) .. '</div>',
            '</div>',
            '<div class="right"><div class="dur">' .. fmt_duration(song.dt) .. '</div>' .. badge .. '</div>',
            '</div>',
        })
    end
    return table.concat(rows, "\n")
end

-- 渲染结果图，成功返回图片 URL，失败返回 nil
local function render_result(songs, keywords)
    if not jn.t2i.is_active() then return nil end
    local template = get_template()
    if not template then return nil end
    local html = template
        :gsub("__KEYWORDS__", function() return html_escape(keywords) end)
        :gsub("__ROWS__", function() return build_rows_html(songs) end)
    local url, err = jn.t2i.generate_url(html, {
        viewport_width = 560,
        full_page = true,
    })
    if not url then
        jn.log.error("[MeT_Music] 结果图渲染失败: " .. (err or "unknown"))
        return nil
    end
    return url
end

-- ====================================================================
-- 子命令实现
-- ====================================================================

local function do_search(args, event)
    local count = DEFAULT_LIMIT
    local parts = args
    if #args >= 2 then
        local n = tonumber(args[#args])
        if n and n == math.floor(n) and n >= 1 and n <= MAX_LIMIT then
            count = math.floor(n)
            parts = {}
            for i = 1, #args - 1 do parts[i] = args[i] end
        end
    end
    local keywords = table.concat(parts, " ")
    if keywords == "" then
        reply(event, "用法：/music search <关键词> [数量(1-" .. MAX_LIMIT .. ")]，例如 /music search 晴天 5")
        return
    end

    local url = api_base()
        .. "/api/web/cloudsearch?keywords=" .. url_encode(keywords)
        .. "&limit=" .. count .. "&offset=0&type=1"
    local resp, err = jn.http.get(url)
    if err or not resp or resp.status ~= 200 then
        reply(event, "搜索请求失败了喵（" .. tostring(err or ("HTTP " .. tostring(resp and resp.status))) .. "），稍后再试试～")
        return
    end
    local ok, data = pcall(jn.json.decode, resp.body)
    local songs = ok and type(data) == "table" and data.result and data.result.songs or nil
    if not songs or #songs == 0 then
        reply(event, "没搜到「" .. keywords .. "」相关的歌，换个关键词试试喵～")
        return
    end

    -- 缓存供 play 使用（包一层 map，规避缓存往返后数组键型变化；群+用户隔离）
    jn.cache.set(cache_key(event), { songs = songs }, SEARCH_TTL)

    local image_url = render_result(songs, keywords)
    if image_url then
        reply(event, { { type = "image", data = { file = image_url } } })
    else
        -- T2I 不可用降级为文本列表
        local lines = { "「" .. keywords .. "」搜索结果：" }
        for i, song in ipairs(songs) do
            lines[#lines + 1] = string.format("%d. %s - %s [%s]",
                i, song.name or "?", join_artists(song),
                (song.al and song.al.name) or "")
        end
        lines[#lines + 1] = "回复 /music play <编号> 播放"
        reply(event, table.concat(lines, "\n"))
    end
end

local function do_play(args, event)
    local idx = tonumber(args[1])
    if not idx or idx ~= math.floor(idx) then
        reply(event, "用法：/music play <编号>，编号来自最近的 /music search 结果图")
        return
    end
    local cached = jn.cache.get(cache_key(event))
    local songs = (type(cached) == "table") and cached.songs or nil
    if type(songs) ~= "table" or #songs == 0 then
        reply(event, "最近没有可用的搜索结果，先 /music search <关键词> 搜一下喵～")
        return
    end
    local song = songs[idx]
    if type(song) ~= "table" then
        reply(event, "编号超出范围啦，只有 1-" .. #songs .. " 喵～")
        return
    end

    local base = api_base()
    local pic = (song.al and type(song.al) == "table") and tostring(song.al.picUrl or "") or ""
    local segments = {
        { type = "music", data = {
            type = "custom",
            url = "https://y.qq.com/n/ryqq/songDetail/" .. tostring(song.id or ""),
            audio = base .. "/api/meting/?type=url&id=" .. tostring(song.id or ""),
            title = tostring(song.name or "未知曲目"),
            image = pic,
            content = join_artists(song),
        } },
    }
    local ok = reply(event, segments)
    if not ok then
        -- 卡片发送失败降级为文本直链
        reply(event, string.format("▶ %s - %s\n%s",
            song.name or "?", join_artists(song),
            base .. "/api/meting/?type=url&id=" .. tostring(song.id or "")))
    end
end

-- ====================================================================
-- 命令注册
-- ====================================================================

local HELP = table.concat({
    "🎵 MeT Music 点歌：",
    "/music search <关键词> [数量] — 搜索歌曲（默认 5 首，结果渲染成图片）",
    "/music play <编号> — 播放搜索结果中的歌曲（音乐卡片，可直接点击播放）",
    "",
    "❤️ 喜欢的话支持一下 MeT Music 项目：",
    "网站：https://music.met6.top:444/app/",
    "仓库：https://github.com/MeTerminator/MeT-Music_App",
    "　　　https://github.com/MeTerminator/MeT-Music_Player",
}, "\n")

jn.command.register("music", function(args, event)
    local sub = tostring(args[1] or ""):lower()
    if sub == "search" then
        local rest = {}
        for i = 2, #args do rest[#rest + 1] = args[i] end
        do_search(rest, event)
    elseif sub == "play" then
        do_play({ args[2] }, event)
    else
        reply(event, HELP)
    end
end)

jn.log.info("[MeT_Music] 点歌插件已加载：/music search | /music play")
