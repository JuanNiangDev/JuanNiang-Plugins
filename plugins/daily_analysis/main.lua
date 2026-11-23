-- ============================================================================
-- daily_analysis: 群聊日常分析与总结插件
-- 作者: Churnie HXCN
-- 复刻自: astrbot_plugin_qq_group_daily_analysis (专为 JuanNiang-Neo 架构深度定制)
-- ============================================================================

local jn = require("jn")
-- 新引擎用 jn.file.read；旧引擎没有 jn.file，退回 package.path 从插件目录 require。
local function load_juya()
    local factory
    if type(jn.file) == "table" and type(jn.file.read) == "function" then
        local src, err = jn.file.read("juya.lua")
        if not src then return nil, "juya.lua 读取失败: " .. tostring(err) end
        local chunk, lerr = loadstring(src, "juya.lua")
        if not chunk then return nil, "juya.lua 语法错误: " .. tostring(lerr) end
        local ok, f = pcall(chunk)
        if not ok or type(f) ~= "function" then return nil, "juya.lua 初始化失败" end
        factory = f
    else
        local old_path = package and package.path
        if package then package.path = "data/pluggins/daily_analysis/?.lua;" .. tostring(old_path or "") end
        local ok, f = pcall(require, "juya")
        if package then package.path = old_path or "" end
        if not ok or type(f) ~= "function" then return nil, "juya.lua 读取失败: " .. tostring(f) end
        factory = f
    end
    local ok2, mod = pcall(factory, jn)
    if not ok2 or type(mod) ~= "table" then return nil, "juya.lua 执行失败: " .. tostring(mod) end
    return mod
end
local juya, juya_err = load_juya()
if not juya then jn.log.error("juya 模块加载失败: " .. tostring(juya_err)) end

-- 全局常量
local PLUGIN_NAME = "daily_analysis"
local TABLE_MESSAGES = "pluggin_daily_analysis_messages"
local TABLE_REPORTS = "pluggin_daily_analysis_reports"

-- 内部运行状态
local state = {
    bot_uin = 0,
    timer_id = 0,
    last_daily_date = "",
    manual_running = false,
    manual_triggered_once = false,
}

-- 前向声明
local check_manual_trigger
local check_daily_timer
local prune_expired_messages

-- ============================================================================
-- 1. 数据库初始化
-- ============================================================================
local function init_db()
    local sql = [[
        CREATE TABLE IF NOT EXISTS ]] .. TABLE_MESSAGES .. [[ (
            id BIGSERIAL PRIMARY KEY,
            group_id BIGINT NOT NULL,
            user_id BIGINT NOT NULL,
            nickname TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL DEFAULT '',
            raw_message TEXT NOT NULL DEFAULT '',
            message_id BIGINT DEFAULT 0,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS idx_pdam_group_created ON ]] .. TABLE_MESSAGES .. [[ (group_id, created_at);
        CREATE TABLE IF NOT EXISTS ]] .. TABLE_REPORTS .. [[ (
            id BIGSERIAL PRIMARY KEY,
            group_id BIGINT NOT NULL,
            target_id BIGINT NOT NULL DEFAULT 0,
            report_date DATE NOT NULL DEFAULT CURRENT_DATE,
            mode TEXT NOT NULL DEFAULT '',
            section_count INT NOT NULL DEFAULT 0,
            node_count INT NOT NULL DEFAULT 0,
            sections TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL DEFAULT '',
            created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS idx_pdar_group_date ON ]] .. TABLE_REPORTS .. [[ (group_id, report_date);
    ]]
    local _, err = jn.database.exec(sql)
    if err then
        jn.log.error("[" .. PLUGIN_NAME .. "] 初始化数据库失败: " .. tostring(err))
    else
        jn.log.info("[" .. PLUGIN_NAME .. "] 数据库表初始化就绪")
    end
end

-- ============================================================================
-- 2. 基础辅助函数
-- ============================================================================
local function get_bot_uin()
    if state.bot_uin and state.bot_uin > 0 then
        return state.bot_uin
    end
    if jn.onebot11 and jn.onebot11.get_login_info then
        local info, err = jn.onebot11.get_login_info()
        if info and info.user_id then
            state.bot_uin = tonumber(info.user_id) or 0
            return state.bot_uin
        end
    end
    return 0
end

local function get_target_groups()
    local raw = jn.config.get("target_groups")
    local list = {}
    if type(raw) == "table" then
        for _, v in pairs(raw) do
            local gid = tonumber(v)
            if gid and gid > 0 then
                list[gid] = true
            end
        end
    elseif type(raw) == "string" then
        for item in raw:gmatch("[^,，%s]+") do
            local gid = tonumber(item)
            if gid and gid > 0 then
                list[gid] = true
            end
        end
    end
    return list
end

local function is_target_group(group_id)
    local targets = get_target_groups()
    return targets[tonumber(group_id)] == true
end

local function clean_message_text(raw)
    if not raw or raw == "" then return "" end
    -- 刻意保留图片与合并转发的 CQ 码：这两类搬运内容的正文会在语料展开阶段
    -- 由 jn.llm.vision_url / jn.onebot11.get_forward_msg_sync 补齐（见 expand_cq_content），
    -- 若在此剥离就永远进不了总结语料；只移除回复引用与机器人指令。
    -- 移除回复引用 CQ 码
    local cleaned = raw:gsub("%[CQ:reply,id=%-?%d+%]", "")
    -- 过滤常规以 / 或 # 或 ! 开头的控制命令
    if cleaned:match("^%s*[/#%!]%S+") then
        return ""
    end
    -- 去除首尾空白
    cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
    return cleaned
end

-- ============================================================================
-- 3. 消息采集 (on_message)
-- ============================================================================
-- 水印识别在第 9 节定义；这里先声明，供采集阶段判断「本机输出」用
local is_bot_output
local da_forward_text

function on_message(event)
    if not event or event.message_type ~= "group" then
        return false, nil
    end

    local group_id = tonumber(event.group_id)
    if not group_id or not is_target_group(group_id) then
        return false, nil
    end

    local sender_id = tonumber(event.user_id) or 0
    local raw_msg = event.raw_message or ""

    -- 过滤机器人自身发言；但带本机水印的输出（repo-intro / 公众号总结）要入库，
    -- 否则日报无法复用「已经发过的总结」，只能让 LLM 重新瞎猜。
    -- 公众号总结是「合并转发」：水印在转发节点里，raw_message 只有 [CQ:forward,id=…]，
    -- 必须先展开再判断，并把展开后的标题/链接正文入库。
    local filter_bot = jn.config.get("filter_bot_messages")
    local bot_forward_text = nil
    if filter_bot == nil then filter_bot = true end
    if filter_bot then
        local bot_uin = get_bot_uin()
        if bot_uin > 0 and sender_id == bot_uin then
            local kept = is_bot_output and is_bot_output(raw_msg)
            if not kept then
                local fid = raw_msg:match("%[CQ:forward,id=([^,%]]+)%]")
                if fid and da_forward_text then
                    bot_forward_text = da_forward_text(fid, true)
                    kept = is_bot_output(bot_forward_text)
                end
            end
            if not kept then
                -- 带卡片特征却没有可识别水印：本机输出被改写/水印编码不一致时会静默丢消息，
                -- 日报「项目复制」会因此变空，这里留一条线索便于定位
                if raw_msg:find("📦", 1, true) or raw_msg:find("📰", 1, true) then
                    jn.log.warn(string.format("[%s] 疑似本机卡片输出但水印校验失败，未入库: %s",
                        PLUGIN_NAME, raw_msg:sub(1, 80)))
                end
                return false, nil
            end
        end
    end

    local nickname = ""
    if event.sender then
        nickname = event.sender.card or ""
        if nickname == "" then
            nickname = event.sender.nickname or ""
        end
    end
    if nickname == "" then
        nickname = "群友" .. tostring(sender_id)
    end

    local clean_text = clean_message_text(raw_msg)
    if clean_text == "" then
        return false, nil
    end
    -- 合并转发里的插件输出：正文存展开后的文本，标题/链接才能进日报来源
    if bot_forward_text and bot_forward_text ~= "" then
        clean_text = bot_forward_text
    end

    local msg_id = tonumber(event.message_id) or 0

    local sql = [[
        INSERT INTO ]] .. TABLE_MESSAGES .. [[
        (group_id, user_id, nickname, content, raw_message, message_id)
        VALUES (?, ?, ?, ?, ?, ?)
    ]]
    jn.database.exec(sql, { group_id, sender_id, nickname, clean_text, raw_msg, msg_id })

    -- 顺带检查后台手动触发开关
    check_manual_trigger()

    return false, nil
end

-- ============================================================================
-- 4. 历史记录查询与统计分析 (板块 1：群聊概况与活跃时段)
-- ============================================================================
local function fetch_group_messages(group_id, hours)
    hours = hours or 24
    local sql = [[
        SELECT id, user_id, nickname, content, raw_message, created_at
        FROM ]] .. TABLE_MESSAGES .. [[
        WHERE group_id = ?
          AND created_at >= NOW() - (INTERVAL '1 hour' * ?)
        ORDER BY created_at ASC
        LIMIT 2000
    ]]
    local rows, err = jn.database.query(sql, { group_id, hours })
    if err then
        jn.log.error("[" .. PLUGIN_NAME .. "] 查询群消息历史失败: " .. tostring(err))
        return {}
    end
    return rows or {}
end

local function analyze_statistics(messages)
    local total_count = #messages
    if total_count == 0 then
        return {
            total_count = 0,
            user_count = 0,
            peak_period = "无活跃记录",
            top_users = {},
        }
    end

    local user_counts = {}
    local user_names = {}
    local hour_counts = {}
    for h = 0, 23 do hour_counts[h] = 0 end

    for _, msg in ipairs(messages) do
        local uid = msg.user_id
        user_counts[uid] = (user_counts[uid] or 0) + 1
        user_names[uid] = msg.nickname or ("群友" .. uid)

        local created = tostring(msg.created_at or "")
        local hour_str = created:match("(%d%d):%d%d:%d%d")
        if hour_str then
            local h = tonumber(hour_str)
            if h and h >= 0 and h <= 23 then
                hour_counts[h] = hour_counts[h] + 1
            end
        end
    end

    local unique_users = 0
    local sorted_users = {}
    for uid, count in pairs(user_counts) do
        unique_users = unique_users + 1
        table.insert(sorted_users, { uid = uid, name = user_names[uid], count = count })
    end
    table.sort(sorted_users, function(a, b) return a.count > b.count end)

    local max_period_count = -1
    local peak_start = 0
    for h = 0, 22 do
        local window_sum = hour_counts[h] + hour_counts[h+1]
        if window_sum > max_period_count then
            max_period_count = window_sum
            peak_start = h
        end
    end
    local peak_period = string.format("%02d:00 - %02d:00", peak_start, peak_start + 2)

    return {
        total_count = total_count,
        user_count = unique_users,
        peak_period = peak_period,
        top_users = sorted_users,
    }
end

-- ============================================================================
-- 5a. CQ 码展开：合并转发 / 图片 / 语音视频文件 / 回复引用 → 可读文本
-- 群里大量讨论是围绕搬运内容展开的，原文里的 [CQ:forward,id=...] 与
-- [CQ:image,url=...] 对总结模型毫无语义，这里在生成语料前展开。
-- ============================================================================
local function da_bool(key, default)
    local v = jn.config.get(key)
    if v == nil then return default end
    return v ~= false and v ~= "false" and v ~= "0"
end

local function da_num(key, default)
    local n = tonumber(jn.config.get(key))
    return n or default
end

local function da_string(key, default)
    local v = jn.config.get(key)
    if v == nil or v == "" then return default end
    return tostring(v)
end

local function da_clip(text, max)
    text = tostring(text or "")
    if #text <= max then return text end
    return text:sub(1, max) .. "…"
end

-- 合并转发：jn.onebot11.get_forward_msg_sync 拉取内层节点，按昵称+正文拼接
-- full=true：给「入库复用」用，完整保留节点正文（标题/摘要/链接），不做截断
da_forward_text = function(fid, full)
    local ck = "da:fwd:" .. fid .. (full and ":full" or "")
    local cached = jn.cache.get(ck)
    if type(cached) == "string" then return cached end
    if not jn.onebot11 or not jn.onebot11.get_forward_msg_sync then
        return "【合并转发】"
    end
    local ok, nodes, err = pcall(jn.onebot11.get_forward_msg_sync, fid)
    if not ok or err or type(nodes) ~= "table" or #nodes == 0 then
        jn.log.warn("[daily_analysis] 合并转发展开失败 id=" .. tostring(fid) .. " err=" .. tostring(err or ok))
        return "【合并转发】"
    end

    local limit = full and 60 or da_num("forward_node_limit", 10)
    local width = full and 4000 or da_num("forward_node_chars", 120)
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
                    -- NapCat 把嵌套的聊天记录当成 xml 段，摘要在 <title> 里
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
        -- 全量模式保留段内换行：📰标题 / 摘要 / 🔗链接 各占一行，才能被来源解析识别
        local joiner = full and "\n" or " "
        parts[#parts + 1] = who .. "：" .. da_clip(table.concat(texts, joiner), width)
    end
    local out
    if full then
        -- 全量模式：每个节点单独成段，保留原文换行（标题/摘要/🔗链接都在里面）
        out = table.concat(parts, "\n")
    else
        out = "【合并转发 " .. inner .. " 条】" .. table.concat(parts, " / ")
        if inner > limit then out = out .. " …（另 " .. (inner - limit) .. " 条）" end
    end
    jn.cache.set(ck, out, 7 * 86400)
    return out
end

-- 图片：image_model Provider 描述（每份报告限量，避免总结时间爆炸）
local da_vision_used = 0
local function da_image_text(url, file)
    -- QQ 原始 rkey 会过期，缓存按 file 哈希走；同一张图换签名链接后仍能命中
    local key = "da:img:" .. (((file and file ~= "") and file) or url)
    local cached = jn.cache.get(key)
    if type(cached) == "string" then return cached end
    if not da_bool("vision_describe", true)
        or not jn.llm or not jn.llm.vision_url
        or da_vision_used >= da_num("vision_image_limit", 10) then
        return "[图片]"
    end
    da_vision_used = da_vision_used + 1

    -- 24h 日报运行时旧链接必过期；用 OneBot get_image 换一条新签发链接
    local fresh = url
    if file and file ~= "" and jn.onebot11 and jn.onebot11.get_image then
        local ok_renew, info, renew_err = pcall(jn.onebot11.get_image, file)
        if ok_renew and type(info) == "table" and type(info.url) == "string" and info.url ~= "" then
            fresh = info.url
        else
            jn.log.warn("[daily_analysis] get_image 续签失败 file=" .. da_clip(file, 80)
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
    jn.log.warn("[daily_analysis] 图片描述失败 file=" .. tostring(file or "-")
        .. " url=" .. da_clip(fresh, 80) .. " err=" .. tostring(err or text))
    return "[图片]"
end

-- 回复引用：把被回复消息的前 80 字作为上下文带进语料
local function da_reply_text(id)
    local rows, err = jn.database.query([[
        SELECT nickname, content FROM ]] .. TABLE_MESSAGES .. [[
        WHERE message_id = ? LIMIT 1
    ]], { tonumber(id) })
    if err or type(rows) ~= "table" or not rows[1] then return "" end
    local src = rows[1].content or ""
    if src == "" then return "" end
    return "【回复 " .. tostring(rows[1].nickname or "群友") .. "：「" .. da_clip(src, 80) .. "」】"
end

local function expand_cq_content(raw, fallback)
    if type(raw) ~= "string" or raw == "" then return fallback or "" end
    local s = raw
    if da_bool("expand_reply", true) then
        s = s:gsub("%[CQ:reply,id=(%-?%d+)%]", function(id)
            return da_reply_text(id)
        end)
    else
        s = s:gsub("%[CQ:reply,id=%-?%d+%]", "")
    end
    if da_bool("expand_forward", true) then
        s = s:gsub("%[CQ:forward,id=([^,%]]+)%]", function(fid)
            return da_forward_text(fid)
        end)
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

-- ============================================================================
-- 5. 构建聊天流 (修复 2741226099 多行空行被拆为 3 条消息的 Bug)
-- ============================================================================
local function format_chat_stream(messages)
    local formatted = {}

    for idx, msg in ipairs(messages) do
        local created = tostring(msg.created_at or "")
        local time_str = created:match("(%d%d:%d%d)") or "未知时间"
        -- 只给昵称、绝不给 QQ 号：模型一旦在语料里看到号码，就会原样写进话题与金句
        local name = tostring(msg.nickname or ("群友" .. tostring(msg.user_id)))
        name = name:gsub('[<>\n"]', " ")

        -- 关键防空行拆分设计：使用 <msg> 标签包裹单条消息全部内容（含内部所有空行与换行）
        local item_text = string.format(
            '<msg id="%d" time="%s" user="%s">\n%s\n</msg>',
            idx,
            time_str,
            name,
            msg.content or ""
        )
        table.insert(formatted, item_text)
    end

    return table.concat(formatted, "\n")
end

-- ============================================================================
-- 6. 复用 Bot 系统人设
-- ============================================================================
local function get_bot_persona_prompt()
    local persona_style = jn.config.get("use_bot_persona") or "deep"
    if persona_style == "none" then
        return "你是一个客观、严谨的中立群聊总结助手。"
    end

    local persona_text = ""
    if jn.agent and jn.agent.get_prompts then
        local prompts, _ = jn.agent.get_prompts()
        if prompts and type(prompts) == "table" then
            for _, p in ipairs(prompts) do
                if p.is_active and (p.type == "personality" or p.type == "system") then
                    if p.content and #p.content > 0 then
                        persona_text = persona_text .. "\n" .. p.content
                    end
                end
            end
        end
    end

    if persona_text ~= "" then
        if persona_style == "deep" then
            return "【你的人格设定（最高优先级，在话题分析、点评和全群总结时，深度还原此人设口吻、口癖与性格特质）】：\n" .. persona_text
        else
            return "【你的人格参考（保持适度幽默风趣，口吻贴合此人设）】：\n" .. persona_text
        end
    end

    return "你是一个风趣幽默、擅长观察但又不失温情的群聊观察员。"
end

-- ============================================================================
-- 7. 构建 LLM 提示词
-- ============================================================================
-- sections 解析在后文定义，这里先声明以便 prompt 复用（单一配置源）
local parse_sections_config

local function build_analysis_prompt(chat_stream, stats, persona_prompt)
    -- 单一配置源：生成数量直接取 sections 的「条数上限」列
    -- 0 = 关闭该板块（不要求生成）；-1 = 不限；>0 = 不多于 N；未配置该板块按 0 处理
    local caps = {}
    for _, sec in ipairs(parse_sections_config()) do caps[sec.key] = sec.cap end
    local max_topics = caps.topics or 0
    local max_quotes = caps.quotes or 0
    local max_titles = caps.titles or 0
    local max_critiques = caps.critique or 0
    local use_persona = jn.config.get("use_bot_persona") or "deep"
    local topics_rule = ""
    if max_topics > 0 then
        topics_rule = string.format("提取不多于 %d 个今日核心热门话题", max_topics)
    elseif max_topics == -1 then
        topics_rule = "提取今日出现的所有核心热门话题，不限数量上限"
    else
        topics_rule = "无需提取话题（本项已关闭）"
    end

    local quotes_rule = ""
    if max_quotes > 0 then
        quotes_rule = string.format("甄选不多于 %d 句最具冲击力、反差感、神反转的「群圣经/高光金句」；引用必须逐字完整，禁止省略或概括", max_quotes)
    elseif max_quotes == -1 then
        quotes_rule = "甄选今日所有的逆天、反差、高光「群圣经/金句」，不限数量上限；引用必须逐字完整，禁止省略或概括"
    else
        quotes_rule = "无需提取金句（本项已关闭）"
    end

    local titles_rule = ""
    if max_titles > 0 then
        titles_rule = string.format("为不多于 %d 位发言活跃群友评选极具特色的荣誉头衔与行为特征画像", max_titles)
    elseif max_titles == -1 then
        titles_rule = "为今日所有活跃群友评选极具特色的头衔与行为特征画像，不限数量上限"
    else
        titles_rule = "无需评选头衔（本项已关闭）"
    end

    local critique_rule = ""
    if max_critiques ~= 0 then
        local count_text = (max_critiques > 0) and string.format("不多于 %d 个", max_critiques) or "不限数量"
        if use_persona == "none" then
            critique_rule = string.format("将今日聊天划分为 %s 抽象维度（如技术研讨、职业焦虑、日常摸鱼），为每个维度计算大致占比百分比，并给出客观严谨的分析点评与全天综合表现总结！", count_text)
        else
            critique_rule = string.format("将今日聊天划分为 %s 抽象维度（如技术研讨、职业焦虑、日常摸鱼），为每个维度计算大致占比百分比，并【结合你的人格设定】给出贴合你性格与口吻的精彩、幽默或生动点评，最后附一句全天综合表现总结！", count_text)
        end
    else
        critique_rule = "无需进行聊天质量点评（本项已关闭）"
    end

    local prompt = string.format([[
%s

你现在正在为群聊生成一份智能的「今日群聊日常分析报告」。
请根据下方给出的【群聊记录数据流】，按规则完成分析，并以严格的纯 JSON 格式返回。

## 核心任务要求：
1. 话题分析：%s。
   - summary 必须写成 150-300 字的叙事段落：交代起因、谁抛出了什么、群里怎么交锋、最后的结论或笑点；点名具体发言人（真实昵称），可以引用短句。
   - 禁止把「某人分享了一个链接/一篇公众号文章/一个仓库」单独列为话题——除非群里围绕它展开了讨论。零散分享并入最相关的话题，或合并成一条「资讯搬运」概述。
   - 提及发言人必须使用真实【QQ昵称】（nickname 属性），严禁只写参与者编号或纯 QQ 号。
   - 标题不超过 20 字，禁止「讨论 XX」「关于 XX」这种空壳标题。
2. 群圣经甄选：%s。
   ⚠️【入选门槛】只收让人拍案叫绝的内容：逆天逻辑、神反转、离谱反差、精准吐槽、或者真的牛逼。纯报错、纯复读、无信息短句一律不收，宁缺毋滥。
   ⚠️【只取本人正文】只收发言人自己打出的字。严禁把「【回复 某人：「…」】」这类被引用的原文写进 content；清掉 [CQ:...] 与 [图片] 等占位符。
   ⚠️【合并同人连发】同一个人连续 2-3 条消息如果合起来才成立（铺垫 + 抖包袱），合并成一条，content 用 \n 保留原貌。
   ⚠️【防拆分】每个 `<msg id="...">` 是一条完整发言，不得按空行拆成多条；sender 必须是真实昵称。
3. 群友头衔：%s。user 必须填群友真实昵称。
4. 质量锐评与人设点评：%s。

## 返回 JSON 数据结构规范（严禁包含 markdown 代码块包裹之外的杂质，必须是合法 JSON）：
```json
{
  "topics": [
    {
      "title": "话题标题（不超过 20 字）",
      "summary": "150-300 字叙事：起因、谁怎么说、交锋焦点、结论或笑点，点名发言人昵称",
      "participants": "主要讨论者（使用真实昵称，逗号分隔）"
    }
  ],
  "golden_quotes": [
    {
      "msg_id": 1,
      "sender": "发言人真实昵称",
      "content": "金句原文：逐字完整引用本人正文，保留原有换行；严禁省略、缩写、只留开头结尾或用省略号代替中间内容。不含被引用内容与 CQ 码；同人连发用换行串联",
      "reason": "入选理由（具体说明其逆天逻辑/神人反差/笑点）"
    }
  ],
  "user_titles": [
    {
      "user": "群友真实昵称",
      "title": "幽默专属头衔",
      "description": "获此头衔的行为特征点评"
    }
  ],
  "critique": {
    "dimensions": [
      {
        "name": "抽象维度名称（如职业焦虑/技术交锋/深夜水群）",
        "percentage": 30,
        "comment": "深度还原你人设口吻的犀利点评"
      }
    ],
    "overall_summary": "以你的人设口吻给出的全天群聊综合表现霸气金句总结"
  }
}
```

## 群聊记录数据流（共 %d 条）：
%s
]], persona_prompt, topics_rule, quotes_rule, titles_rule, critique_rule, stats.total_count, chat_stream)

    return prompt
end

-- ============================================================================
-- 8. JSON 解析与健壮清洗 (消除循环 sub 造成的 registry overflow)
-- ============================================================================
local function escape_json_string_controls(src)
    if not src or src == "" then return src end
    local out, in_str, esc = {}, false, false
    for i = 1, #src do
        local c = src:sub(i, i)
        if in_str then
            if esc then
                out[#out + 1] = c
                esc = false
            elseif c == "\\" then
                out[#out + 1] = c
                esc = true
            elseif c == '"' then
                out[#out + 1] = c
                in_str = false
            elseif c == "\n" then
                out[#out + 1] = "\\n"
            elseif c == "\r" then
                out[#out + 1] = "\\r"
            elseif c == "\t" then
                out[#out + 1] = "\\t"
            elseif c == "\b" then
                out[#out + 1] = "\\b"
            elseif c == "\f" then
                out[#out + 1] = "\\f"
            elseif c:byte() < 32 then
                out[#out + 1] = string.format("\\u%04x", c:byte())
            else
                out[#out + 1] = c
            end
        else
            out[#out + 1] = c
            if c == '"' then
                in_str = true
                esc = false
            end
        end
    end
    return table.concat(out)
end

local function parse_llm_json(raw)
    if not raw or raw == "" then return nil end
    local json_str = raw:match("```json%s*(.-)%s*```") or raw:match("```%s*(.-)%s*```") or raw

    local function try_decode(src)
        if not src or src == "" then return nil, "empty" end
        local fixed = escape_json_string_controls(src)
        local ok, res = pcall(jn.json.decode, fixed)
        if ok and type(res) == "table" then return res end
        return nil, res
    end

    -- 1. 优先直接解码；2. 统一转义字符串内的裸控制字符后再解码
    local res, err = try_decode(json_str)
    if res then return res end

    -- 3. 截取首个 { 到最后一个 }，兼容模型在 JSON 前后加说明文字
    local s = json_str:find("{", 1, true)
    local e = json_str:match(".*()}")
    if s and e and e > s then
        res, err = try_decode(json_str:sub(s, e))
        if res then return res end
    end

    jn.log.warn("[daily_analysis] LLM JSON 解析失败: " .. tostring(err)
        .. " head=" .. json_str:sub(1, 300):gsub("\n", "\\n"))
    return nil
end


-- ============================================================================
-- 9. 来源采集：仓库 / 公众号文章 / 橘鸦早报
-- ----------------------------------------------------------------------------
-- 水印与 repo-intro / wechat-article-summary 同一套编码：带水印的消息是本机
-- 输出，从中摘出「标题 + 已生成总结」直接复用，不再重复调 LLM。
-- ============================================================================
local WM_TEXT = "Generated by JuanNiang Neo"
local WM_HEAD = "\239\187\191"
local WM_ZERO = "\226\128\139"
local WM_ONE = "\226\128\140"
local WM_LEGACY = "\226\128\139\226\128\140\226\128\141\239\187\191"

-- 解出前若干字节，判断是否为本机输出（新编码前缀匹配，或旧 4 字符标记）
is_bot_output = function(raw)
    if not raw or raw == "" then return false end
    if raw:find(WM_LEGACY, 1, true) then return true end
    local p = raw:find(WM_HEAD, 1, true)
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
    return #got >= 8 and WM_TEXT:sub(1, #got) == got
end

-- 去掉零宽字符（水印会粘在 📦 行/链接尾部，影响 key 匹配）
local function strip_wm(s)
    s = tostring(s or "")
    s = s:gsub("\226\128\139", ""):gsub("\226\128\140", "")
         :gsub("\226\128\141", ""):gsub("\239\187\191", "")
    return s
end

-- 金句清洗：剔除被引用原文、CQ 码与占位符，只留发言人本人的正文
local function clean_quote_text(s)
    s = tostring(s or "")
    s = s:gsub("【回复.-」】", "")
    s = s:gsub("%[CQ:[^%]]*%]", "")
    s = s:gsub("%[图片[^%]]*%]", "")
    s = s:gsub("\r", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
    return s
end

local function normalize_url(u)
    u = tostring(u or ""):gsub("&amp;", "&")
    return (u:gsub("[%)%,%.%!%?%;:]+$", ""))
end

-- CQ 参数里的 HTML 转义（卡片图 url 的 & 会写成 &amp;，直接发会 404）
local function cq_unescape(s)
    s = tostring(s or "")
    s = s:gsub("&amp;", "&")
    s = s:gsub("&#44;", ",")
    s = s:gsub("&#91;", "[")
    s = s:gsub("&#93;", "]")
    return s
end

local IMG_CQ_PREFIX = "[CQ:image,"
-- 按出现顺序摘出一行里的图片 URL（优先 url=，其次 file= 里的 http 地址）
local function collect_cq_images(line, images)
    local pos = 1
    while true do
        local s = line:find(IMG_CQ_PREFIX, pos, true)
        if not s then break end
        local e = line:find("]", s + 1, true)
        if not e then break end
        local body = line:sub(s + #IMG_CQ_PREFIX, e - 1)
        local url = body:match("url=(https?://[^,%s]+)")
        if not url then url = body:match("file=(https?://[^,%s]+)") end
        if url and url ~= "" then images[#images + 1] = cq_unescape(url) end
        pos = e + 1
    end
end

-- 从本机输出里按 📦/📰 分块：正文按原样保留（去水印/去 CQ 码），
-- 图片按消息内的段序挂到最近的上一个块上（repo-intro 的段序是 text1,img1,text2,img2）
local function parse_bot_blocks(text)
    local blocks, cur = {}, nil
    local function flush()
        if not cur then return end
        local clean = {}
        for i, l in ipairs(cur.lines) do
            local line = tostring(l)
            line = line:gsub("%[CQ:[^%]]*%]", ""):gsub("\r", "")
            line = strip_wm(line)
            if i == 1 then line = line:gsub("^%s+", "") end
            clean[#clean + 1] = line:gsub("%s+$", "")
        end
        -- 段间空行会留在上一块尾部，剪掉
        while #clean > 0 and clean[#clean] == "" do clean[#clean] = nil end

        local title, summary = "", ""
        local anchor
        for i, l in ipairs(clean) do
            if l:find("📝", 1, true) or l:find("📰", 1, true) then anchor = i; break end
        end
        if anchor then
            local l = clean[anchor]
            local p1 = l:find("📝", 1, true)
            local p2 = l:find("📰", 1, true)
            local p, mlen = p1, #"📝"
            if not p or (p2 and p2 < p) then p, mlen = p2, #"📰" end
            if p then title = l:sub(p + mlen):gsub("^%s+", ""):gsub("%s+$", "") end
            for i = anchor + 1, #clean do
                local seg = clean[i]
                -- 跳过公众号名（📖）与原文链接（🔗）行，摘要是正文那句
                local skip = seg:find("📖", 1, true) or seg:find("🔗", 1, true)
                if seg ~= "" and not skip and not seg:find("^https?://") then summary = seg; break end
            end
        end
        blocks[#blocks + 1] = { kind = cur.kind, name = cur.name, url = cur.url,
                                title = title, summary = summary,
                                text = table.concat(clean, "\n"), images = cur.images }
        cur = nil
    end

    -- 逐行扫描（不用 gmatch/表达式上直接调方法：gopher-lua 在临时字符串上
    -- 调用字符串方法会触发 nil pointer panic）
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
                    -- 卡片图常以 [CQ:image,…] 紧跟链接，URL 要截到第一个 '[' 之前
                    u = u:match("^([^%[]*)") or u
                    cur.url = normalize_url(strip_wm(u))
                end
            end
        end
    end
    flush()
    return blocks
end

-- 扫描消息：projects 只取 repo-intro 的本机输出（水印校验），原样复制正文与卡片图；
-- articles 取公众号总结（标题/摘要仍供新闻事件合并复用）
local function collect_sources(messages)
    local projects, pindex = {}, {}
    local projects_on = da_bool("enable_projects", true)
    local bot_article = {}
    local bot_raw = {}   -- raw_message -> true，第二轮回链时跳过 bot 消息
    local img_total = 0
    for _, m in ipairs(messages) do
        local raw = m.raw_message or ""
        local text = m.content or ""
        local is_bot = is_bot_output(raw) or is_bot_output(text)
        -- 公众号总结走合并转发：raw 只有 [CQ:forward,id=…]，正文在节点里
        if not is_bot and raw:find("[CQ:forward,", 1, true)
            and not (text:find("📰", 1, true) or text:find("📦", 1, true)) then
            local fid = raw:match("%[CQ:forward,id=([^,%]]+)%]")
            if fid then
                local ex = da_forward_text(fid, true)
                if is_bot_output(ex) then
                    is_bot = true
                    text = ex
                end
            end
        end
        if is_bot then
            bot_raw[raw] = true
            -- 卡片图只在 raw_message 的 CQ 码里；仓库块只在原文里，所以优先扫原始消息。
            -- 一条消息可以塞多个仓库：段序 text1,img1,text2,img2 → 每个 📦 各成一块。
            local src = raw
            if not src:find("📦", 1, true) then src = text end
            for _, b in ipairs(parse_bot_blocks(src)) do
                if projects_on and b.kind == "repo" and b.name ~= "" then
                    local key = b.name:lower()
                    img_total = img_total + #b.images
                    if pindex[key] then
                        -- 同一仓库被多次介绍：保留最新一份（卡片图 url 带 rkey，有时效）
                        projects[pindex[key]] = b
                    else
                        pindex[key] = #projects + 1
                        projects[#projects + 1] = b
                    end
                elseif b.kind == "article" and b.url and b.url ~= "" then
                    bot_article[normalize_url(b.url)] = b
                end
            end
        end
    end

    -- 用户直接分享、但 repo-intro 没介绍过的仓库：仍要进列表，稍后用官方 API 补真实简介
    local repo_seen = {}
    for k in pairs(pindex) do repo_seen[k] = true end
    local function add_repo(kind, name, url)
        if not projects_on then return end
        local key = name:lower()
        if repo_seen[key] then return end
        repo_seen[key] = true
        projects[#projects + 1] = { key = key, kind = kind, name = name, url = url }
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
            -- 扫展开后的正文：合并转发、图片描述里的链接才不会漏
            local scan = m.content or ""
            if scan == "" then scan = raw end
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
    jn.log.info(string.format("[%s] 项目复制：%d 个（带图 %d 张）", PLUGIN_NAME, #projects, img_total))
    jn.log.info(string.format("[%s] 来源采集：公众号 %d（已有标题 %d）", PLUGIN_NAME, #articles, with_title))
    return projects, articles
end

local function cfg_news_merge_enabled()
    local v = jn.config.get("news_event_merge")
    if v == nil then return true end
    return v ~= false and v ~= "false" and v ~= "0"
end

-- LLM 辅助：要求严格 JSON 输出
local function llm_json(system, user)
    if not (jn.llm and jn.llm.chat) then return nil, "无 LLM" end
    local resp, err = jn.llm.chat({
        { role = "system", content = system },
        { role = "user", content = user },
    })
    if err or not resp or resp == "" then return nil, tostring(err or "空响应") end
    local cleaned = resp:gsub("```[%w]*\n?", ""):gsub("```", "")
    local ok, obj = pcall(jn.json.decode, cleaned)
    if not ok or type(obj) ~= "table" then return nil, "JSON 解析失败" end
    return obj, nil
end

-- 新闻：公众号文章 + 橘鸦早报 → LLM 按事件合并，保留全部来源链接
local function merge_news(articles, juya_items, max_items)
    local wechat, juya = {}, {}
    local dropped = 0
    for i, a in ipairs(articles) do
        if i > 40 then break end
        -- 标题与摘要都拿不到的裸链接不进新闻正文（否则只能编成「未识别公众号分享 N」）
        if (a.title or "") ~= "" or (a.summary or "") ~= "" then
            wechat[#wechat + 1] = { i = i, title = a.title or "", summary = a.summary or "",
                                    url = a.url, count = a.count }
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        jn.log.info(string.format("[%s] 新闻过滤：%d 条无标题链接未进正文", PLUGIN_NAME, dropped))
    end
    local jidx = 0
    for _, it in ipairs(juya_items) do
        if jidx >= math.min(max_items * 2, 80) then break end
        jidx = jidx + 1
        local links = {}
        for _, l in ipairs(it.links) do links[#links + 1] = l.url end
        juya[#juya + 1] = { i = 100 + jidx, title = it.title, summary = it.summary,
                            category = it.category, links = links }
    end
    if #wechat == 0 and #juya == 0 then return {} end

    if not cfg_news_merge_enabled() then
        -- 关闭合并：各自成条
        local out = {}
        for _, a in ipairs(wechat) do
            out[#out + 1] = { title = a.title ~= "" and a.title or "公众号文章",
                              summary = a.summary, links = { a.url } }
        end
        for _, j in ipairs(juya) do
            out[#out + 1] = { title = j.title, summary = j.summary, links = j.links }
        end
        return out
    end

    local payload = jn.json.encode({ wechat = wechat, juya = juya })
    local system = string.format([[
你在整理今日 AI 新闻。输入含两类条目：
- wechat：群里分享的微信公众号文章（title/summary 可能是我们此前的总结，也可能为空；url 为原文链接，count 为分享次数）
- juya：橘鸦 AI 早报的当日条目（title/summary 附带，links 为该事件的多个来源链接）

请把描述同一事件的条目合并成一条新闻，严格输出 JSON：
{"events":[{"title":"标题","summary":"不超过 80 字的简体中文摘要","links":["来源链接"]}]}

规则：
1. links 必须收录该事件的全部来源链接（公众号原文 + 早报来源），不得遗漏、不得编造；
2. 无法判断为同一事件的，各自独立成条；
3. 最多 %d 条，按重要性排序；
4. 标题不得与摘要重复套话，不要输出除 JSON 以外的任何内容。]], max_items)
    local obj, err = llm_json(system, payload)
    if not obj or type(obj.events) ~= "table" then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 新闻合并失败，降级为顺序罗列: " .. tostring(err))
        local out = {}
        for _, j in ipairs(juya) do
            out[#out + 1] = { title = j.title, summary = j.summary, links = j.links }
        end
        for _, a in ipairs(wechat) do
            out[#out + 1] = { title = a.title ~= "" and a.title or "公众号文章",
                              summary = a.summary, links = { a.url } }
        end
        return out
    end
    local out = {}
    for _, e in ipairs(obj.events) do
        if type(e) == "table" and e.title then
            local links = {}
            if type(e.links) == "table" then
                for _, u in ipairs(e.links) do
                    local s = tostring(u)
                    if s:find("^https?://") then links[#links + 1] = s end
                end
            end
            out[#out + 1] = { title = tostring(e.title), summary = tostring(e.summary or ""), links = links }
        end
    end
    return out
end

-- ============================================================================
-- 10. 板块组装与发送（per_item / per_section / forward 三种模式）
-- ============================================================================
local SECTION_DEF = {
    overview = "📊 群聊概况",
    top = "🔥 发言主力军",
    topics = "🔥 今日核心话题",
    quotes = "📖 群圣经 / 高光发言",
    titles = "👑 群友特色头衔 / 画像",
    critique = "🎭 聊天质量分析与人设点评",
    projects = "🧪 开源项目列表",
    news = "📰 今日新闻",
    stats = "📈 本次分析统计",
}

parse_sections_config = function()
    local list = jn.config.get("sections")
    if type(list) ~= "table" or #list == 0 then
        list = { "overview||1", "top||1", "topics||-1", "quotes||-1", "titles||6",
                 "critique||4", "projects||20", "news||70", "stats||1" }
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

-- @@enrich_begin
-- 开源项目简介补全：repo-intro 没介绍过的仓库，优先复用 repo-intro 缓存，再退回官方 API
-- HuggingFace 在容器内需要宿主机 socks5；GitHub 直连即可
local HF_PROXY = "socks5://172.27.0.1:20170"
local INTRO_CACHE = "http://172.27.0.1:5284/repo-intro"

local function repo_intro_cache(r)
    local encoded = r.name:gsub("[^%w%-_%.]", function(c)
        return string.format("%%%02X", c:byte())
    end)
    local res = jn.http.get(INTRO_CACHE .. "?repo=" .. encoded, "")
    if not (res and res.status == 200) then return nil end
    local d = jn.json.decode(res.body)
    if type(d) == "table" and (d.summary or d.desc_cn or d.title) then return d end
    return nil
end

local function enrich_trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
end

local function enrich_fmt_k(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(n)
end

local function enrich_one(r, proxy)
    local cache_key = "repoinfo:v4:" .. r.key

    -- 1) repo-intro 已经总结过（含中文标题/简介/渲染卡片）：直接复用
    local ri = repo_intro_cache(r)
    if ri then
        r.ri = ri
        r.summary = enrich_trim(ri.summary)
        if r.summary == "" then r.summary = enrich_trim(ri.desc_cn) end
        jn.cache.set(cache_key, { summary = r.summary, ri = ri }, 604800)
        return
    end

    local cached = jn.cache.get(cache_key)
    if type(cached) == "table" and (cached.summary ~= nil or cached.invalid) then
        if cached.invalid then r.invalid = true end
        if cached.ri then r.ri = cached.ri end
        if cached.summary and cached.summary ~= "" then r.summary = cached.summary end
        return
    end

    local summary = ""
    if r.kind == "github" then
        -- GitHub 在容器内可直连；代理只给 HuggingFace 用（容器里 127.0.0.1 不是宿主机）
        local res, herr = jn.http.get("https://api.github.com/repos/" .. r.name, "")
        if res and res.status == 404 then
            r.invalid = true   -- 仓库不存在/链接错误：直接从日报剔除
            jn.log.warn(string.format("[%s] GitHub 仓库 404，已剔除 %s", PLUGIN_NAME, r.name))
        elseif not (res and res.status == 200) then
            jn.log.warn(string.format("[%s] GitHub 简介获取失败 %s status=%s err=%s",
                PLUGIN_NAME, r.name, tostring(res and res.status), tostring(herr)))
        end
        if res and res.status == 200 then
            local d = jn.json.decode(res.body)
            if type(d) == "table" then
                local desc = enrich_trim(d.description)
                local meta = {}
                if enrich_trim(d.language) ~= "" then meta[#meta + 1] = d.language end
                if tonumber(d.stargazers_count) then meta[#meta + 1] = "⭐ " .. enrich_fmt_k(d.stargazers_count) end
                summary = desc
                if #meta > 0 then
                    summary = (summary ~= "" and (summary .. " ") or "") .. "（" .. table.concat(meta, " · ") .. "）"
                end
                if summary == "" and type(d.topics) == "table" then
                    local tags = {}
                    for i = 1, math.min(4, #d.topics) do tags[#tags + 1] = tostring(d.topics[i]) end
                    if #tags > 0 then summary = "标签：" .. table.concat(tags, ", ") end
                end
            end
        end
    elseif r.kind == "hf" then
        local api = r.url:find("/datasets/", 1, true)
            and ("https://huggingface.co/api/datasets/" .. r.name)
            or ("https://huggingface.co/api/models/" .. r.name)
        local res, herr = jn.http.get(api, proxy)
        if res and res.status == 404 then
            r.invalid = true
            jn.log.warn(string.format("[%s] HF 仓库 404，已剔除 %s", PLUGIN_NAME, r.name))
        elseif not (res and res.status == 200) then
            jn.log.warn(string.format("[%s] HF 简介获取失败 %s status=%s err=%s",
                PLUGIN_NAME, r.name, tostring(res and res.status), tostring(herr)))
        end
        if res and res.status == 200 then
            local d = jn.json.decode(res.body)
            if type(d) == "table" then
                local head = enrich_trim(d.pipeline_tag)
                if head == "" and type(d.tags) == "table" then
                    local tags = {}
                    for i = 1, math.min(3, #d.tags) do tags[#tags + 1] = tostring(d.tags[i]) end
                    head = table.concat(tags, ", ")
                end
                local meta = {}
                if tonumber(d.downloads) then meta[#meta + 1] = "⬇ " .. enrich_fmt_k(d.downloads) end
                if tonumber(d.likes) then meta[#meta + 1] = "♥ " .. enrich_fmt_k(d.likes) end
                summary = head
                if #meta > 0 then
                    summary = (summary ~= "" and (summary .. " · ") or "") .. table.concat(meta, " · ")
                end
            end
        end
    end

    local ttl = (summary ~= "" or r.invalid) and 604800 or 86400
    jn.cache.set(cache_key, { summary = summary, invalid = r.invalid or false }, ttl)
    if summary ~= "" then r.summary = summary end
end

local function enrich_repos(repos)
    if #repos == 0 then return end
    for _, r in ipairs(repos) do
        if not r.text and (r.summary or "") == "" then
            pcall(enrich_one, r, HF_PROXY)
        end
    end
end
-- @@enrich_end

-- 组装各板块条目（每条是纯文本，或 {text=…, images={…}} 的项目卡片）
-- 金句回填：按 <msg id> 取原始消息完整正文（合并转发则展开全文），不再信任模型复述的长度
local function quote_source_text(messages, msg_id)
    local idx = tonumber(msg_id)
    if not idx then return nil end
    local m = messages[idx]
    if type(m) ~= "table" then return nil end
    local raw = tostring(m.raw_message or "")
    local fid = raw:match("%[CQ:forward,id=([^,%]]+)%]")
        or tostring(m.content or ""):match("%[CQ:forward,id=([^,%]]+)%]")
    if fid then
        raw = da_forward_text(fid, true)
    else
        raw = tostring(m.content or "")
    end
    local text = clean_quote_text(raw)
    if text == "" then return nil end
    return text
end

local function build_sections(stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, messages, chat_messages)
    local projects, articles = collect_sources(messages or {})
    if da_bool("enable_projects", true) then enrich_repos(projects) end
    local juya_items = {}
    local news_on = false
    for _, s in ipairs(parse_sections_config()) do
        if s.key == "news" and s.cap ~= 0 then news_on = true end
    end
    if news_on then
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
        local ok, url, html, source, ferr = false, nil, nil, nil, "juya 模块未加载"
        if juya then
            ok, url, html, source, ferr = pcall(function()
                return juya.fetch_issue(feeds, os.date("%Y-%m-%d"))
            end)
        end
        if ok and html then
            juya_items = juya.flatten(juya.parse_issue(html))
            jn.log.info(string.format("[%s] 橘鸦早报抓取成功: %s（%d 条）", PLUGIN_NAME, tostring(url), #juya_items))
        else
            jn.log.warn("[" .. PLUGIN_NAME .. "] 橘鸦早报抓取失败: " .. tostring(ok and ferr or url))
        end
    end

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

    for _, s in ipairs(parse_sections_config()) do
        local items = {}
        if s.key == "overview" then
            items[1] = string.format("🏢 分析群聊: %s (%d)\n📅 统计时间: %s\n💬 消息总量: %d 条\n👥 参与人数: %d 人\n⏰ 最活跃时段: %s",
                group_name, group_id, os.date("%Y年%m月%d日"), stats.total_count, stats.user_count, stats.peak_period)
        elseif s.key == "top" then
            if stats.top_users and #stats.top_users > 0 then
                local lines = {}
                for idx = 1, math.min(3, #stats.top_users) do
                    local u = stats.top_users[idx]
                    lines[#lines + 1] = string.format("👑 Top%d: %s (%d条)", idx, u.name, u.count)
                end
                items[1] = table.concat(lines, "\n")
            end
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
                local content = clean_quote_text(q.content)
                -- 金句以原消息为准：模型偶尔会省略中间内容或只留头尾，直接回填完整原文
                local src = quote_source_text(chat_messages or messages, q.msg_id)
                if src and #src > #content and #src >= 4 then content = src end
                local dedup = content:gsub("%s+", "")
                -- 清洗后过短（纯表情/占位符/空行）的不入典
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
            -- repo-intro 介绍过的：原样复制正文+卡片图；没介绍过的：保留名称+API 简介+链接
            for _, p in ipairs(projects) do
                if not p.invalid then
                    if p.text and p.text ~= "" then
                        items[#items + 1] = { text = p.text, images = p.images }
                    else
                        local lines = { "📦 " .. p.name }
                        if p.ri then
                            if p.ri.title and p.ri.title ~= "" then lines[#lines + 1] = "📝 " .. p.ri.title end
                            local body = p.summary
                            if (not body or body == "") and p.ri.desc_cn then body = p.ri.desc_cn end
                            if body and body ~= "" then lines[#lines + 1] = body end
                        elseif p.summary and p.summary ~= "" then
                            lines[#lines + 1] = p.summary
                        end
                        lines[#lines + 1] = p.url
                        items[#items + 1] = table.concat(lines, "\n")
                    end
                end
            end
            if #items == 0 then
                items[1] = "今日没有检测到开源项目 / 模型仓库链接"
            end
        elseif s.key == "news" then
            local lim = (s.cap > 0) and s.cap or ((s.cap == -1) and 200 or 70)
            local n = 0
            for _, e in ipairs(merge_news(articles, juya_items, lim)) do
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

-- 板块条目：纯文本，或 {text=…, images={…}}（开源项目卡片图）
local function item_text(item)
    if type(item) == "table" then return tostring(item.text or "") end
    return tostring(item or "")
end

local function item_images(item)
    if type(item) == "table" and type(item.images) == "table" then return item.images end
    return nil
end

-- 合并转发节点 / 普通消息的 content：有图就发 [文本, 图片…] 段数组，否则继续用纯文本
local function node_payload(text, images)
    if not images or #images == 0 then return text end
    local segs = { { type = "text", data = { text = text } } }
    for _, u in ipairs(images) do
        segs[#segs + 1] = { type = "image", data = { file = u } }
    end
    return segs
end

local function send_report(sections, target_type, target_id)
    if #sections == 0 then return 0, 0 end
    local mode = tostring(jn.config.get("report_mode") or "forward")

    local function send_msg(payload)
        if target_type == "group" then
            return jn.onebot11.send_group_msg(target_id, payload)
        end
        return jn.onebot11.send_private_msg(target_id, payload)
    end

    -- 兜底：把节点拼成少量文本再发。绝不逐节点发送——那会把日报拆成几十条消息。
    -- 段数组节点只取文本段（降级路径丢图是已知代价，至少不丢正文）
    local function send_nodes_as_text(nodes)
        local parts = {}
        for _, n in ipairs(nodes) do
            local c = n.content
            if type(c) == "string" then
                if c ~= "" then parts[#parts + 1] = c end
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
        for _, c in ipairs(chunks) do send_msg(c) end
        return #chunks
    end

    if mode == "forward" then
        local name = jn.config.get("custom_sender_name")
        if not name or name == "" then
            -- 未配置时用机器人自己的昵称，避免多实例串名字
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
        -- 不加分割线：合并转发里每个节点已是独立气泡，--- 纯属噪音
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
        local ferr
        if target_type == "group" and jn.onebot11.send_group_forward_msg_sync then
            local _, e = jn.onebot11.send_group_forward_msg_sync(target_id, nodes)
            ferr = e
        elseif target_type ~= "group" and jn.onebot11.send_private_forward_msg_sync then
            local _, e = jn.onebot11.send_private_forward_msg_sync(target_id, nodes)
            ferr = e
        else
            jn.log.warn("[" .. PLUGIN_NAME .. "] 当前引擎无" .. (target_type == "group" and "群" or "私聊")
                .. "合并转发接口，改用合并文本发送")
            ferr = "no_forward_api"
        end
        if ferr == nil then return 1, #nodes end

        -- 带图节点可能被 QQ 拒绝（"HTTP download failed: 400"，卡片图 rkey 过期/CDN 限制）。
        -- 先退成纯文本节点保住「一条合并转发」，图片随后单独补发，而不是把日报拆成十几条文本。
        local text_nodes = {}
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
                text_nodes[#text_nodes + 1] = { user_id = uin, nickname = name, content = table.concat(parts, "\n") }
            else
                text_nodes[#text_nodes + 1] = n
            end
        end
        local ok2 = false
        if target_type == "group" and jn.onebot11.send_group_forward_msg_sync then
            local _, e2 = jn.onebot11.send_group_forward_msg_sync(target_id, text_nodes)
            ok2 = (e2 == nil)
        elseif target_type ~= "group" and jn.onebot11.send_private_forward_msg_sync then
            local _, e2 = jn.onebot11.send_private_forward_msg_sync(target_id, text_nodes)
            ok2 = (e2 == nil)
        end
        if ok2 then
            jn.log.warn("[" .. PLUGIN_NAME .. "] 合并转发带图失败，已改纯文本转发并单独补图: " .. tostring(ferr))
            local imgs = {}
            for _, s in ipairs(sections) do
                for _, item in ipairs(s.items) do
                    local im = item_images(item)
                    if im then
                        for _, u in ipairs(im) do imgs[#imgs + 1] = u end
                    end
                end
            end
            for i = 1, #imgs, 4 do
                local segs = {}
                for k = i, math.min(i + 3, #imgs) do
                    segs[#segs + 1] = { type = "image", data = { file = imgs[k] } }
                end
                send_msg(segs)
            end
            return 1, #text_nodes
        end
        jn.log.warn("[" .. PLUGIN_NAME .. "] 合并转发失败，改用合并文本: " .. tostring(ferr))
        local n = send_nodes_as_text(nodes)
        return n, #nodes
    end

    local count = 0
    for _, s in ipairs(sections) do
        local n = #s.items
        if mode == "per_section" then
            local lines, images = {}, {}
            for _, item in ipairs(s.items) do
                lines[#lines + 1] = item_text(item)
                local im = item_images(item)
                if im then
                    for _, u in ipairs(im) do images[#images + 1] = u end
                end
            end
            local chunks = chunk_text(s.title .. "\n" .. table.concat(lines, "\n\n"), 1500)
            for i, chunk in ipairs(chunks) do
                -- 图片挂在最后一段文本后面一起发（文字在前、图在后）
                if i == #chunks then
                    send_msg(node_payload(chunk, images))
                else
                    send_msg(chunk)
                end
                count = count + 1
            end
        else
            for i, item in ipairs(s.items) do
                local head = (n > 1) and string.format("%s (%d/%d)\n", s.title, i, n) or (s.title .. "\n")
                send_msg(node_payload(head .. item_text(item), item_images(item)))
                count = count + 1
            end
        end
    end
    return count, count
end

-- ============================================================================
-- 10a. 报告持久化：成功生成的日报落 Postgres，重启后可查历史
-- ============================================================================
local function persist_report(group_id, target_id, sections, mode, node_count)
    local flat = {}
    for _, sec in ipairs(sections or {}) do
        flat[#flat + 1] = "## " .. tostring(sec.title or sec.key or "")
        for _, item in ipairs(sec.items or {}) do
            -- 项目条目是 {text, images}：只把正文拼进可读文本，图片仍在 sections JSON 里
            flat[#flat + 1] = item_text(item)
        end
    end
    local content = table.concat(flat, "\n")
    local ok_enc, encoded = pcall(jn.json.encode, sections)
    if not ok_enc then encoded = "" end
    local _, err = jn.database.exec([[INSERT INTO ]] .. TABLE_REPORTS .. [[
        (group_id, target_id, report_date, mode, section_count, node_count, sections, content)
        VALUES (?, ?, CURRENT_DATE, ?, ?, ?, ?, ?)
    ]], { group_id, target_id, tostring(mode), #sections, node_count or 0,
          tostring(encoded or ""), content })
    if err then
        jn.log.error("[" .. PLUGIN_NAME .. "] 日报持久化失败: " .. tostring(err))
    else
        jn.log.info(string.format("[%s] 日报已落库 group=%d 板块=%d 字符=%d",
            PLUGIN_NAME, group_id, #sections, #content))
    end
end

-- ============================================================================
-- 11. 自动清理过期记录 (默认保留 7 天)
-- ============================================================================
function prune_expired_messages()
    local retention = tonumber(jn.config.get("retention_days") or "7") or 7
    if retention <= 0 then retention = 7 end

    local sql = [[
        DELETE FROM ]] .. TABLE_MESSAGES .. [[
        WHERE created_at < NOW() - (INTERVAL '1 day' * ?)
    ]]
    local count, err = jn.database.exec(sql, { retention })
    if err then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 清理过期消息历史失败: " .. tostring(err))
    elseif count and count > 0 then
        jn.log.info(string.format("[%s] 自动清理 %d 天前的过期消息: %d 条", PLUGIN_NAME, retention, count))
    end

    -- 报告保留更久（默认 90 天）
    local report_days = tonumber(jn.config.get("report_retention_days") or "90") or 90
    if report_days <= 0 then report_days = 90 end
    local _, rerr = jn.database.exec("DELETE FROM " .. TABLE_REPORTS ..
        " WHERE created_at < NOW() - (INTERVAL '1 day' * ?)", { report_days })
    if rerr then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 清理过期报告失败: " .. tostring(rerr))
    end
end

-- ============================================================================
-- 12. 执行分析主流程 (do_group_analysis)
-- ============================================================================
-- 智能匹配文本模型服务商 (支持服务商名称、模型名称、组合形式或 UUID)
local function match_text_provider(input_str, providers)
    if not input_str or input_str == "" then return nil end
    local s = input_str:lower():gsub("%s+", "")

    local text_providers = {}
    for _, p in ipairs(providers or {}) do
        local p_type = tostring(p.Type or p.type or "")
        if p_type == "text_model" then
            table.insert(text_providers, p)
        end
    end

    -- 1. 精确匹配：ID / 服务商名 / 模型名 / 组合 "服务商·模型"
    for _, p in ipairs(text_providers) do
        local pid = tostring(p.ID or p.id or ""):lower()
        local pname = tostring(p.Name or p.name or ""):lower():gsub("%s+", "")
        local pmodel = tostring(p.Model or p.model or ""):lower():gsub("%s+", "")
        local combo = pname .. "·" .. pmodel
        local combo_dot = pname .. "." .. pmodel
        local combo_slash = pname .. "/" .. pmodel

        if s == pid or s == pname or s == pmodel or s == combo or s == combo_dot or s == combo_slash then
            return p
        end
    end

    -- 2. 模糊包含匹配 (例如输入 "volcengine"、"deepseek"、"qianfan")
    for _, p in ipairs(text_providers) do
        local pname = tostring(p.Name or p.name or ""):lower()
        local pmodel = tostring(p.Model or p.model or ""):lower()
        if pname:find(s, 1, true) or pmodel:find(s, 1, true) or s:find(pname, 1, true) or s:find(pmodel, 1, true) then
            return p
        end
    end

    return nil
end

local function do_group_analysis(group_id, send_target_id, is_private_target, force)
    group_id = tonumber(group_id)
    if not group_id then return false, "非法群号" end

    local cur_date = os.date("%Y-%m-%d")
    local cache_key = "last_analyzed:" .. tostring(group_id)

    -- 非强制触发（自动定时器或 CronJob）时，执行防并发与防重复检查
    if not force then
        if state.is_analyzing and state.is_analyzing[group_id] then
            jn.log.warn(string.format("[%s] 群 %d 正在执行分析中，跳过并发调用", PLUGIN_NAME, group_id))
            return false, "正在执行中"
        end

        local last_date = nil
        if jn.cache and jn.cache.get then
            last_date = jn.cache.get(cache_key)
        end
        if not last_date and state.last_analyzed_date then
            last_date = state.last_analyzed_date[group_id]
        end

        if last_date == cur_date then
            jn.log.info(string.format("[%s] 群 %d 今日 (%s) 已完成过群总结报告，跳过重复执行", PLUGIN_NAME, group_id, cur_date))
            return true, "今日已完成"
        end

        -- 立即占位并落库当日标记，确保同一群同一日仅执行一次
        -- （覆盖消息不足、LLM 失败、发送失败等所有分支，彻底杜绝双触发重复推送）
        state.last_analyzed_date = state.last_analyzed_date or {}
        state.last_analyzed_date[group_id] = cur_date
        state.last_daily_date = cur_date
        if jn.cache and jn.cache.set then
            jn.cache.set(cache_key, cur_date, 86400 * 2)
        end
    end

    state.is_analyzing = state.is_analyzing or {}
    state.is_analyzing[group_id] = true

    local function run_task()
    group_id = tonumber(group_id)
    if not group_id then return false, "非法群号" end

    -- 进度提示：默认静默（enable_progress_feedback 打开才发）
    local feedback = jn.config.get("enable_progress_feedback")
    if feedback == true or feedback == "true" then
        local tip = "📊 正在提取分析近24小时群聊记录，大模型正在生成报告，请稍候..."
        if is_private_target then
            jn.onebot11.send_private_msg(send_target_id, tip)
        else
            jn.onebot11.send_group_msg(group_id, tip)
        end
    end
    local start_time = os.time()

    -- 1. 查询 24h 历史消息
    local all_messages = fetch_group_messages(group_id, 24)
    -- 带水印的是插件自动产出的卡片（仓库/文章总结），不参与聊天分析，
    -- 只用于 build_sections 里复用标题与总结
    local messages = {}
    local bot_uin = get_bot_uin()
    for _, m in ipairs(all_messages) do
        -- bot 自己发的（含水印输出、合并转发总结）一律不进聊天分析；
        -- 它们只作为 build_sections 的来源索引
        if tonumber(m.user_id) ~= bot_uin and not is_bot_output(m.raw_message) then
            messages[#messages + 1] = m
        end
    end
    if #messages < 3 then
        local msg = string.format("📊 今日群聊发言较少（当前仅 %d 条，不足 3 条），暂无足够数据生成分析报告。", #messages)
        jn.log.warn(string.format("[%s] 群 %d 消息数不足 (%d < 3)，取消生成报告", PLUGIN_NAME, group_id, #messages))
        if is_private_target then
            jn.onebot11.send_private_msg(send_target_id, msg)
        else
            jn.onebot11.send_group_msg(group_id, msg)
        end
        return false, "消息过少"
    end

    -- 2. 统计概况
    local stats = analyze_statistics(messages)

    -- 3. 构建聊天流
    -- 语料展开：转发 / 图片 / 回复 / 语音视频文件变成模型可读文本
    -- （文件和视频只留占位，正文不入库；图片描述限量，转发按条展开）
    da_vision_used = 0
    local expanded = 0
    for _, m in ipairs(messages) do
        local before = m.content or ""
        m.content = expand_cq_content(m.raw_message, before)
        if m.content ~= before then expanded = expanded + 1 end
    end
    jn.log.info(string.format("[%s] 语料展开：%d/%d 条消息含 CQ 码，图片描述 %d 张",
        PLUGIN_NAME, expanded, #messages, da_vision_used))
    local chat_stream = format_chat_stream(messages)
    -- 诊断：把展开后的转发/图片行打一条样例日志，便于核对内容是否进入语料
    for line in chat_stream:gmatch("[^\n]+") do
        if line:find("【合并转发", 1, true) or line:find("【图片：", 1, true) then
            jn.log.info("[" .. PLUGIN_NAME .. "] 展开样例: " .. da_clip(line, 400))
        end
    end
    stats.total_chars = #chat_stream

    -- 4. 组装人设与 Prompt
    local persona_prompt = get_bot_persona_prompt()
    local prompt = build_analysis_prompt(chat_stream, stats, persona_prompt)

    -- 5. 调用 LLM（支持通过服务商名称、模型名或组合指定模型，留空默认使用激活模型）
    local target_provider_str = jn.config.get("text_provider_id") or ""
    local old_provider_id = nil
    local active_model_desc = "默认主模型"

    if jn.agent and jn.agent.get_providers then
        local providers, _ = jn.agent.get_providers()
        if providers and type(providers) == "table" then
            for _, p in ipairs(providers) do
                local p_type = tostring(p.Type or p.type or "")
                local p_active = (p.IsActive == true) or (p.is_active == true) or (p.active == true)
                local p_id = tostring(p.ID or p.id or "")
                local p_name = tostring(p.Name or p.name or "")
                local p_model = tostring(p.Model or p.model or "")

                if p_active and p_type == "text_model" then
                    old_provider_id = p_id
                    active_model_desc = p_model ~= "" and p_model or p_name
                    break
                end
            end

            if target_provider_str ~= "" then
                local chosen_p = match_text_provider(target_provider_str, providers)
                if chosen_p and jn.agent.switch_provider then
                    local chosen_id = tostring(chosen_p.ID or chosen_p.id or "")
                    local chosen_name = tostring(chosen_p.Name or chosen_p.name or "")
                    local chosen_model = tostring(chosen_p.Model or chosen_p.model or "")
                    if old_provider_id ~= chosen_id then
                        jn.agent.switch_provider(chosen_id)
                        active_model_desc = chosen_model ~= "" and chosen_model or chosen_name
                        jn.log.info(string.format("[%s] 临时挂载指定总结模型: %s", PLUGIN_NAME, active_model_desc))
                    else
                        active_model_desc = chosen_model ~= "" and chosen_model or chosen_name
                    end
                elseif not chosen_p then
                    jn.log.warn(string.format("[%s] 未找到匹配的文本模型: %q，回退使用系统激活模型: %s", PLUGIN_NAME, target_provider_str, active_model_desc))
                end
            end
        end
    end

    jn.log.info(string.format("[%s] 开始调用 LLM 分析群 %d 消息 (字符数: %d, 模型: %s)...", PLUGIN_NAME, group_id, #prompt, active_model_desc))
    local resp_text, err = jn.llm.chat({
        { role = "system", content = persona_prompt },
        { role = "user", content = prompt },
    }, { timeout = 300 })

    -- 若之前临时切换了 Provider，切回原 Provider 保持全局环境纯净
    if target_provider_str ~= "" and old_provider_id and jn.agent and jn.agent.switch_provider then
        jn.agent.switch_provider(old_provider_id)
    end
    if err or not resp_text or resp_text == "" then
        jn.log.error("[" .. PLUGIN_NAME .. "] LLM 分析失败: " .. tostring(err))
        return false, "LLM 调用失败: " .. tostring(err)
    end

    -- 6. 解析结构化数据
    local analysis_data = parse_llm_json(resp_text) or {}

    -- 7. 计算耗时与 Token
    local dur_sec = os.difftime(os.time(), start_time)
    if dur_sec < 1 then dur_sec = 1 end
    local est_tokens = math.floor((#prompt + #resp_text) / 2)
    local model_name = active_model_desc
    -- 获取群信息
    local group_name = "本群"
    if jn.onebot11.get_group_info then
        local ginfo = jn.onebot11.get_group_info(group_id)
        if ginfo and ginfo.group_name and ginfo.group_name ~= "" then
            group_name = ginfo.group_name
        end
    end

    -- 8. 组装板块（概况/话题/金句/头衔/质量/项目/新闻/统计，来源见 collect_sources）
    local sections = build_sections(stats, analysis_data, group_name, group_id, dur_sec, est_tokens, model_name, all_messages, messages)

    -- 9. 按 report_mode 发送（forward 默认：一条合并转发；per_section；per_item）
    local target_type = is_private_target and "private" or "group"
    local dest_id = send_target_id or group_id
    local sent, nodes = send_report(sections, target_type, dest_id)
    if not sent or sent == 0 then
        jn.log.error(string.format("[%s] 日报发送失败或内容为空 (target=%s:%d)", PLUGIN_NAME, target_type, dest_id))
        return false, "发送失败"
    end

    local mode = tostring(jn.config.get("report_mode") or "forward")
    jn.log.info(string.format("[%s] 群 %d 日报已发送到 %s:%d（模式=%s，板块 %d 个，发送 %d 次 / 节点 %d）",
        PLUGIN_NAME, group_id, target_type, dest_id, mode, #sections, sent, nodes))

    -- 报告落库（与消息表同库，跨重启可查）
    pcall(persist_report, group_id, dest_id, sections, mode, nodes)

    -- 10. 自动清理过期历史
    prune_expired_messages()

    return true, nil
    end

    local ok, res, err_msg = pcall(run_task)
    state.is_analyzing[group_id] = nil
    if not ok then
        jn.log.error(string.format("[%s] 群 %d 总结执行异常: %s", PLUGIN_NAME, group_id, tostring(res)))
        return false, tostring(res)
    end
    return res, err_msg
end

-- ============================================================================
-- 13. 手动触发与定时检查
-- ============================================================================
function run_manual_trigger()
    if state.manual_running then return end
    state.manual_running = true

    local target_grp_str = jn.config.get("manual_target_group") or ""
    local send_target_str = jn.config.get("manual_send_target") or ""

    local target_groups = {}
    if target_grp_str ~= "" then
        for g in target_grp_str:gmatch("%d+") do
            table.insert(target_groups, tonumber(g))
        end
    end
    if #target_groups == 0 then
        local all_targets = get_target_groups()
        for gid, _ in pairs(all_targets) do
            table.insert(target_groups, gid)
        end
    end

    local send_target = tonumber(send_target_str)
    local is_private = false
    if send_target and send_target > 0 and send_target_str ~= "" then
        -- 目标类型以「机器人实际所在群列表」为准，别再靠长度/是否在 target_groups 猜
        local is_group_target = false
        if jn.onebot11.get_group_list then
            local groups = jn.onebot11.get_group_list()
            if type(groups) == "table" then
                for _, g in ipairs(groups) do
                    if tonumber(g.group_id or g.groupId or 0) == send_target then
                        is_group_target = true
                        break
                    end
                end
            end
        end
        if not is_group_target then
            if send_target_str:len() <= 11 then
                is_private = true
            else
                jn.log.warn(string.format("[%s] 目标 %s 既不是机器人所在群，也不像 QQ 号，放弃发送",
                    PLUGIN_NAME, send_target_str))
                return
            end
        end
    end

    for _, gid in ipairs(target_groups) do
        do_group_analysis(gid, send_target or gid, is_private, true)
    end

    state.manual_running = false
end

function check_manual_trigger()
    local trig = jn.config.get("manual_trigger")
    if (trig == true or trig == "true") and not state.manual_triggered_once then
        state.manual_triggered_once = true
        jn.log.info("[" .. PLUGIN_NAME .. "] 检测到后台手动触发开关已打开，调度群总结任务...")
        if jn.timer and jn.timer.after then
            jn.timer.after(0.5, { action = "manual_trigger" })
        else
            run_manual_trigger()
        end
    end
end
-- ============================================================================
-- 14. 异步定时器回调响应 (引擎级 on_timer_response)
-- ============================================================================
function on_timer_response(req_id, ctx, result, err)
    if err then
        jn.log.warn("[" .. PLUGIN_NAME .. "] 定时器回调发生异常: " .. tostring(err))
        return
    end
    if not ctx or type(ctx) ~= "table" then return end

    if ctx.action == "manual_trigger" then
        jn.log.info("[" .. PLUGIN_NAME .. "] 异步定时器触发手动总结任务执行...")
        run_manual_trigger()
    elseif ctx.action == "daily_check" then
        check_daily_timer()
    end
end

-- ============================================================================
-- 14. CronJob 回调与内部定时器
-- ============================================================================
function on_cronjob(event)
    jn.log.info("[" .. PLUGIN_NAME .. "] 收到 CronJob 调度触发，开始执行每日群总结...")
    local specific_group = nil
    if event then
        if event.target_id and tonumber(event.target_id) and tonumber(event.target_id) > 0 and event.message_type == "group" then
            specific_group = tonumber(event.target_id)
        elseif event.payload and type(event.payload) == "table" and event.payload.group_id then
            specific_group = tonumber(event.payload.group_id)
        end
    end

    if specific_group and specific_group > 0 then
        jn.log.info(string.format("[%s] CronJob 指定目标群 %d，执行总结...", PLUGIN_NAME, specific_group))
        do_group_analysis(specific_group, specific_group, false)
        return
    end

    local targets = get_target_groups()
    for gid, _ in pairs(targets) do
        do_group_analysis(gid, gid, false)
    end
end

function check_daily_timer()
    local now_time = os.date("*t")
    local cur_date = os.date("%Y-%m-%d")
    local cur_hm = string.format("%02d:%02d", now_time.hour, now_time.min)

    local auto_time = tostring(jn.config.get("auto_analysis_time") or "23:00")
    if auto_time:len() == 4 then auto_time = "0" .. auto_time end

    if cur_hm == auto_time and state.last_daily_date ~= cur_date then
        state.last_daily_date = cur_date
        jn.log.info(string.format("[%s] 内部定时器触发每日总结 (时间: %s)...", PLUGIN_NAME, cur_hm))
        local targets = get_target_groups()
        for gid, _ in pairs(targets) do
            do_group_analysis(gid, gid, false)
        end
    end

    check_manual_trigger()

    if jn.timer and jn.timer.after then
        state.timer_id = jn.timer.after(30, { action = "daily_check" })
    end
end

-- ============================================================================
-- 15. 启动自检
-- ============================================================================
init_db()
-- 启动时立即检查手动触发配置（用于后台保存配置后立即生效）
check_manual_trigger()




if jn.timer and jn.timer.after then
    state.timer_id = jn.timer.after(10, { action = "daily_check" })
end
