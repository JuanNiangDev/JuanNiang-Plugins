-- ====================================================================
-- wechat-article-summary 微信公众号文章总结插件
-- --------------------------------------------------------------------
-- 识别群聊/私聊中发送的 mp.weixin.qq.com 文章链接（短链 /s/{id} 与
-- 长链 /s?__biz=...&sn=... 均支持）。一条消息可含多篇：逐篇抓取页面
-- 提取标题/公众号/正文（异步），合并为一次 LLM 调用（按文章类型
-- 分类总结），最终一条消息输出，每篇一段、各自附上链接，段间空两行。
-- 复用主程序 LLM API（jn.llm.chat_async），全程异步不阻塞事件循环。
-- --------------------------------------------------------------------
-- 抓取要点：微信对默认 UA 风控（返回"环境异常"验证页），必须带浏览器
-- User-Agent + Referer（引擎 http.get_async 支持可选 headers 表）。
-- 正文从 id="js_content" 容器按 div 深度配对提取，转纯文本。
-- --------------------------------------------------------------------
-- 异步流水线（引擎级异步注册表，回调串行派发）：
--   on_message               → 解析全部链接，未命中缓存者逐个 http.get_async(文章页)
--   on_http_response(article) → 提取标题/公众号/正文，全部就绪后 llm.chat_async(一次调用)
--   on_chat_response         → 逐篇缓存 LLM 结果 → 组装消息段发送
-- 每篇的 LLM 结果独立缓存（jn.cache，按 TTL 过期），后续再遇到
-- 同链接直接复用，跳过抓取与 LLM。
-- ====================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

-- --------------------------------------------------------------------
-- 运行时配置读取（改 config.yaml / Web 面板后即时生效）
-- --------------------------------------------------------------------
local function cfg_bool(key, default)
    local v = jn.config.get(key)
    if v == nil then return default end
    return v ~= false and v ~= "false" and v ~= "0"
end

local function cfg_num(key, default)
    local v = jn.config.get(key)
    if v == nil or v == "" then return default end
    local n = tonumber(v)
    if n == nil then return default end
    return n
end

local function cfg_string(key, default)
    local v = jn.config.get(key)
    if v == nil or v == "" then return default end
    return tostring(v)
end

-- --------------------------------------------------------------------
-- URL 解析（提取一条消息中的全部公众号文章链接）
-- --------------------------------------------------------------------
-- 短链：https://mp.weixin.qq.com/s/{id}，id 由字母数字与 - _ 组成
-- 长链：https://mp.weixin.qq.com/s?__biz=...&mid=...&idx=...&sn=...
-- 校验 host 前一个字符不是字母/数字，避免误匹配 xxxmp.weixin.qq.com
local function parse_urls(raw)
    if not raw or raw == "" then return {} end
    local seen, entries = {}, {}

    -- 短链
    local needle = "mp.weixin.qq.com/s/"
    local s = raw:find(needle, 1, true)
    while s do
        local c = raw:sub(s - 1, s - 1)
        if c == "" or not c:match("%w") then
            local id = raw:sub(s + #needle):match("^([%w%-_]+)")
            if id and not seen["wx:" .. id] then
                seen["wx:" .. id] = true
                entries[#entries + 1] = {
                    kind = "article", key = "wx:" .. id,
                    url = "https://mp.weixin.qq.com/s/" .. id,
                }
            end
        end
        s = raw:find(needle, s + 1, true)
    end

    -- 长链（query 含 __biz / mid / idx / sn，取到空白或非 URL 字符为止）
    local lneedle = "mp.weixin.qq.com/s?"
    s = raw:find(lneedle, 1, true)
    while s do
        local c = raw:sub(s - 1, s - 1)
        if c == "" or not c:match("%w") then
            local q = raw:sub(s + #lneedle):match("^([%w%+%/%_%%%&%.%-=]+)")
            if q and q:find("__biz", 1, true) then
                local key = "wx?" .. q
                if not seen[key] then
                    seen[key] = true
                    entries[#entries + 1] = {
                        kind = "article", key = key,
                        url = "https://mp.weixin.qq.com/s?" .. q,
                    }
                end
            end
        end
        s = raw:find(lneedle, s + 1, true)
    end

    return entries
end

-- --------------------------------------------------------------------
-- 抓取请求头（微信风控必须的浏览器 UA + Referer）
-- --------------------------------------------------------------------
local function fetch_headers()
    return {
        ["User-Agent"] = cfg_string("ua", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
        ["Referer"] = "https://mp.weixin.qq.com/",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "zh-CN,zh;q=0.9",
    }
end

-- --------------------------------------------------------------------
-- 工具函数
-- --------------------------------------------------------------------
local function copy_ctx(ctx)
    local c = {}
    for k, v in pairs(ctx) do c[k] = v end
    return c
end

local function truncate(str)
    local max = cfg_num("max_content_chars", 10000)
    if #str > max then return str:sub(1, max) end
    return str
end

-- --------------------------------------------------------------------
-- HTML 解析（微信文章页）
-- --------------------------------------------------------------------
-- 提取 meta 信息：og:title / og:description / 公众号名（var nickname，作者 js_author_name 不用）
local function extract_meta(html)
    local title = html:match('property="og:title" content="([^"]*)"') or ""
    local desc = html:match('property="og:description" content="([^"]*)"') or ""
    local account = html:match('var nickname = htmlDecode%("([^"]*)"%)')
        or html:match('var nickname = "([^"]*)"')
        or ""
    account = account:gsub("^%s+", ""):gsub("%s+$", "")
    return title, desc, account
end

-- 提取正文容器：id="js_content" 开标签之后到其配对 </div>（div 深度计数，
-- 正确处理正文内嵌套 div 的图文混排，避免首个 </div> 提前截断）
local function extract_body(html)
    local start = html:find('id="js_content"', 1, true)
    if not start then return "" end
    local open = html:find(">", start, true)
    if not open then return "" end
    local depth, pos = 0, open + 1
    while true do
        local lt = html:find("<", pos)
        if not lt then break end
        local tag = html:match("^([%a!/]+)", lt)
        local gt = html:find(">", lt)
        if not gt then break end
        if tag == "div" then
            if html:sub(gt - 1, gt - 1) ~= "/" then -- 排除自闭合 <div/>
                depth = depth + 1
            end
        elseif tag == "/div" then
            depth = depth - 1
            if depth <= 0 then
                return html:sub(open + 1, lt - 1)
            end
        end
        pos = gt + 1
    end
    return html:sub(open + 1)
end

-- HTML 片段 → 纯文本（去脚本/样式/标签/实体，压缩空白）
local function html_to_text(html)
    local text = html
    text = text:gsub("<script[^>]*>.-</script>", " ")
    text = text:gsub("<style[^>]*>.-</style>", " ")
    text = text:gsub("<[^>]+>", " ")
    text = text:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    text = text:gsub("&#39;", "'"):gsub("&quot;", '"')
    text = text:gsub("%s+", " ")
    return text:gsub("^%s+", ""):gsub("%s+$", "")
end

-- 解析文章页：成功返回 meta 表，失败返回 nil + 错误文案
local function parse_article(body)
    if not body or body == "" then return nil, "抓取失败：空响应" end
    -- 风控验证页：无正文容器且含"环境异常"
    if not body:find('id="js_content"', 1, true) then
        if body:find("环境异常", 1, true) then
            return nil, "微信风控拦截，请稍后再试"
        end
        return nil, "文章内容解析失败"
    end
    local title, desc, account = extract_meta(body)
    local content = html_to_text(extract_body(body))
    if content == "" then
        return nil, "文章内容为空"
    end
    return {
        title = title,
        desc = desc,
        account = account,
        content = truncate(content),
    }, nil
end

-- 每篇 LLM 结果缓存（值：JSON {type,title,summary}）
local function article_cache_key(e)
    return "article:" .. e.key
end

local function article_cache_get(e)
    local v = jn.cache.get(article_cache_key(e))
    if type(v) ~= "table" then return nil end
    if not v.summary then return nil end
    -- 缓存结构升级：旧缓存无 account（曾存文章作者名），视为未命中重建，
    -- 避免显示作者名而非公众号名
    if not v.account then return nil end
    -- 恢复抓取期 meta（标题/公众号名），缓存命中时输出段完整
    if (v.title or "") ~= "" or (v.account or "") ~= "" then
        e.meta = { title = v.title or "", account = v.account or "", desc = "" }
    end
    return v
end

local function article_cache_set(e, content)
    if type(content) ~= "table" then return end
    jn.cache.set(article_cache_key(e), content, cfg_num("cache_ttl", 604800))
end

-- --------------------------------------------------------------------
-- LLM 提示词（按文章类型分类总结，多篇同一提示词）
-- --------------------------------------------------------------------
local function llm_system_prompt()
    return [[你是中文公众号文章总结助手。用户会给你一篇或多篇微信公众号文章的标题、公众号名与正文内容，请对每篇文章独立判定类型、总结核心内容，最后按指定 JSON 输出。

【零、通用铁律（所有文章必做）】
1. 只总结正文明确给出的内容，禁止编造文章未提及的时间、事件、人物、数据、功能；未写明写"未提及"或省略。
2. summary 一律简体中文，保留专有名词、机构名、产品名原文。
3. 每篇独立判定类型，禁止按公众号或标题前缀归一类。
4. 多篇文章务必全部覆盖，不得遗漏。

【一、文章类型判定与总结要点】
1. 项目/模型/产品介绍类（含开源项目发布、模型发布、工具推介）
   总结：是什么（一句话定位）+ 核心特性与功能 + 关键参数/数据（参数量、性能指标等，只写正文明确的）+ 如何使用或获取 + 适用场景。
2. 新闻/资讯类（行业动态、公司事件、政策发布、人事变动）
   总结：事件发生的时间 + 事件本身（发生了什么）+ 涉及的人物（含身份/头衔）+ 起因经过结果 + 影响或意义。
3. 观点/评论类（作者立场鲜明的分析、评论、预测）
   总结：作者的核心观点是什么 + 论述过程（主要论据与论证逻辑）+ 作者对反方观点的回应（如有）+ 结论或展望。
4. 教程/指南类（操作步骤、学习路线、避坑指南）
   总结：教的是什么/解决什么问题 + 前置要求 + 主要流程或步骤 + 关键注意事项/易错点。
5. 早报/每日新闻/新闻汇总类（标题或正文含"早报""日报""每日新闻""新闻汇总""要闻盘点"等）
   不要写长总结：只列出前 5 条新闻的标题（保留原文，逐条"1. 标题"换行，第 6 条及以后一律不要列出），最后一行写"共 X 条"（X 为正文统计的新闻总数，正文未明确给出则写"共多条"）；正文新闻不足 5 条则全部列出，不要在每条后加说明文字。
6. 其他（通知、活动、盘点、访谈、随笔等）
   总结：核心内容，突出最有信息量的部分。

【二、输出格式】严格只输出如下 JSON（不要输出 JSON 以外的任何内容，不要用代码块包裹）：
{"articles":[{"index":1,"type":"类型中文名","title":"一句话标题（简体中文，≤30字）","summary":"核心内容总结（简体中文，200~350字；早报/新闻汇总类按上述第 5 类格式列出标题与总数）"}]}
index 与输入文章编号一一对应（从 1 开始）。]]
end

-- 组装单篇送 LLM 的用户输入
local function article_input_for_llm(e, idx)
    local m = e.meta or {}
    local s = "【文章 " .. idx .. "】"
    if m.title and m.title ~= "" then s = s .. "\n标题：" .. m.title end
    if m.account and m.account ~= "" then s = s .. "\n公众号：" .. m.account end
    if m.desc and m.desc ~= "" then s = s .. "\n简介：" .. m.desc end
    s = s .. "\n链接：" .. e.url
    if m.content and m.content ~= "" then
        s = s .. "\n正文内容：\n" .. m.content
    end
    return s
end

-- --------------------------------------------------------------------
-- 发送 / 组装
-- --------------------------------------------------------------------
-- 组装单篇段
local function compose_section(e)
    local lines = {}
    if e.meta and e.meta.title and e.meta.title ~= "" then
        lines[#lines + 1] = "📰 " .. e.meta.title
    else
        lines[#lines + 1] = "📰 微信公众号文章"
    end
    -- 公众号名（来自 var nickname），抓不到则不显示该行
    if e.meta and e.meta.account and e.meta.account ~= "" then
        lines[#lines + 1] = "📖 " .. e.meta.account
    end

    local llm = e.llm
    local summary = (llm and llm.summary) or ""
    if summary ~= "" then
        lines[#lines + 1] = summary
    end
    if e.err and not llm then
        lines[#lines + 1] = "⚠️ " .. e.err
    end
    lines[#lines + 1] = "🔗 " .. e.url
    return table.concat(lines, "\n")
end

-- 组装整条消息：段间空两行
local function compose_message(batch)
    local sections = {}
    for _, e in ipairs(batch.entries) do
        if not e.skipped then
            sections[#sections + 1] = compose_section(e)
        end
    end
    if #sections == 0 then return nil end
    return table.concat(sections, "\n\n\n")
end

-- 发送（reply 引用 + 文本）
local function send_summary(batch, text)
    if not text or text == "" then text = "文章总结失败，请稍后再试～" end
    local segments
    local t = batch.target
    if t.reply_quote and t.message_id ~= nil and tostring(t.message_id) ~= "" then
        segments = {
            { type = "reply", data = { id = tostring(t.message_id) } },
            { type = "text", data = { text = text } },
        }
    else
        segments = { { type = "text", data = { text = text } } }
    end
    if t.message_type == "group" then
        jn.onebot11.send_group_msg(t.target_id, segments)
    else
        jn.onebot11.send_private_msg(t.target_id, segments)
    end
end

-- 流水线终点：发送 + 清理本批次设置的在途去重标记
local function compose_and_send(batch)
    for _, e in ipairs(batch.entries) do
        if e.owned_dedup then
            jn.cache.del("dedup:" .. e.key)
        end
    end
    local text = compose_message(batch)
    if text then
        send_summary(batch, text)
    end
end

-- --------------------------------------------------------------------
-- 异步流水线
-- --------------------------------------------------------------------

-- LLM 上下文表：req_id → batch（llm.chat_async 回调不带 ctx）
local llm_ctx = {}

-- 全部文章抓取就绪 → 单次 LLM 调用（防重复触发）
local function start_llm(batch)
    if batch.llm_started then return end
    batch.llm_started = true
    local usable = {}
    for _, i in ipairs(batch.uncached) do
        local e = batch.entries[i]
        if not e.err and e.meta then
            usable[#usable + 1] = e
        end
    end
    if #usable == 0 or not cfg_bool("enable_summary", true) or not jn.llm or not jn.llm.available() then
        compose_and_send(batch)
        return
    end

    local parts = {}
    for idx, e in ipairs(usable) do
        parts[#parts + 1] = article_input_for_llm(e, idx)
    end
    local messages = {
        { role = "system", content = llm_system_prompt() },
        { role = "user", content = table.concat(parts, "\n\n") },
    }
    batch.llm_messages = messages -- 失败重试复用
    local rid = jn.llm.chat_async(messages, { timeout = cfg_num("llm_timeout", 60) })
    if not rid or rid == 0 then
        jn.log.warn("[wechat-article-summary] llm.chat_async 提交失败，降级为无摘要发送")
        compose_and_send(batch)
        return
    end
    batch.llm_usable = usable
    llm_ctx[rid] = batch
end

-- 全部抓取处理完毕时的检查点
local function check_batch(batch)
    if batch.pending <= 0 then
        start_llm(batch)
    end
end

-- article 阶段：解析文章页（网络错误/超时重试一次——微信对高频请求会瞬时挂起）
local function handle_article(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    local status = result and result.status or 0
    if err then
        local attempt = (ctx.fetch_attempt or 0) + 1
        if attempt <= 1 then
            local c = copy_ctx(ctx)
            c.fetch_attempt = attempt
            local rid = jn.http.get_async(e.url, c, fetch_headers())
            if rid and rid ~= 0 then return end -- 重试已提交，等待回调
        end
        e.err = "请求失败：" .. tostring(err)
    elseif status == 403 or status == 429 then
        e.err = "微信风控拦截，请稍后再试"
    elseif status == 404 then
        e.err = "文章不存在或已删除"
    elseif status < 200 or status >= 300 then
        e.err = "抓取失败（HTTP " .. status .. "）"
    else
        local meta, perr = parse_article(result.body or "")
        if meta then
            e.meta = meta
        else
            e.err = perr or "文章内容解析失败"
        end
    end
    batch.pending = batch.pending - 1
end

-- HTTP 异步回调（引擎级异步注册表 kind "http"）
function on_http_response(req_id, ctx, result, err)
    if not ctx or not ctx.batch or not ctx.stage then return end
    if ctx.stage == "article" then
        handle_article(ctx, result, err)
    end
    check_batch(ctx.batch)
end

-- LLM 异步回调（引擎级异步注册表 kind "chat"）
function on_chat_response(req_id, content, err)
    local batch = llm_ctx[req_id]
    if not batch then return end
    llm_ctx[req_id] = nil

    local usable = batch.llm_usable or {}
    if err and err ~= "" then
        -- Provider 瞬时失败（如网关 connection reset）重试一次
        if not batch.llm_retried and batch.llm_messages then
            batch.llm_retried = true
            local rid = jn.llm.chat_async(batch.llm_messages, { timeout = cfg_num("llm_timeout", 60) })
            if rid and rid ~= 0 then
                jn.log.warn("[wechat-article-summary] LLM 失败重试: " .. tostring(err))
                llm_ctx[rid] = batch
                return
            end
        end
        jn.log.warn("[wechat-article-summary] LLM 总结失败: " .. tostring(err))
        compose_and_send(batch)
        return
    end

    local cleaned = (content or ""):gsub("```[%w]*\n?", ""):gsub("```", "")
    local parsed = jn.json.decode(cleaned)
    local results = {}
    if type(parsed) == "table" and type(parsed.articles) == "table" then
        results = parsed.articles
    end

    -- 按 index 回填到对应的未缓存文章
    local used = {}
    for _, r in ipairs(results) do
        if type(r) == "table" and r.index then
            local e = usable[tonumber(r.index)]
            if e then
                local content_tbl = {
                    type = r.type and tostring(r.type) or "",
                    title = (e.meta and e.meta.title) or (r.title and tostring(r.title)) or "",
                    account = (e.meta and e.meta.account) or "",
                    summary = r.summary and tostring(r.summary) or "",
                }
                e.llm = content_tbl
                article_cache_set(e, content_tbl)
                used[tonumber(r.index)] = true
            end
        end
    end
    -- 未回填的文章：无摘要
    for idx, e in ipairs(usable) do
        if not used[idx] then
            e.llm = nil
        end
    end

    compose_and_send(batch)
end

-- --------------------------------------------------------------------
-- 消息入口
-- --------------------------------------------------------------------
local bot_qq_cache
local function is_self(event)
    if bot_qq_cache == nil then
        local info = jn.onebot11.get_login_info()
        if info and info.user_id then bot_qq_cache = tostring(info.user_id) end
    end
    return bot_qq_cache ~= nil and tostring(event.user_id) == bot_qq_cache
end

-- 构建批次：过滤开关/缓存/在途去重，返回 entries 与需抓取的 index 列表
local function build_batch(event)
    local all = parse_urls(event.raw_message or "")
    local max = cfg_num("max_articles", 5)
    local entries, uncached = {}, {}
    for _, e in ipairs(all) do
        if #entries >= max then
            jn.log.info("[wechat-article-summary] 单条链接数超过 " .. max .. "，忽略后续")
            break
        end
        local cached = article_cache_get(e)
        if cached then
            e.llm = cached
            e.done = true
        else
            local dedup = jn.cache.get("dedup:" .. e.key)
            if dedup and (os.time() - tonumber(dedup) < 60) then
                e.done = true
                e.skipped = true -- 正在被其他消息处理，跳过
            else
                jn.cache.set("dedup:" .. e.key, os.time(), 60)
                e.owned_dedup = true -- 本批次自己设置的去重标记，完成后只清自己的
                uncached[#uncached + 1] = #entries + 1
            end
        end
        entries[#entries + 1] = e
    end
    return entries, uncached
end

function on_message(event)
    if not event then return false, false end
    -- 机器人自己的消息不处理（防止自触发循环）
    if is_self(event) then return false, false end
    local raw = event.raw_message or ""
    -- 命令不处理
    if raw:sub(1, 1) == "/" then return false, false end
    if not cfg_bool("enabled", true) then return false, false end
    if cfg_bool("group_only", false) and event.message_type ~= "group" then return false, false end

    local entries, uncached = build_batch(event)
    if #entries == 0 then return false, false end

    local batch = {
        entries = entries,
        uncached = uncached,
        pending = #uncached,
        target = {
            message_type = event.message_type,
            target_id = (event.group_id ~= 0 and event.group_id) or event.user_id,
            message_id = event.message_id,
            reply_quote = cfg_bool("reply_quote", true),
        },
    }

    if batch.pending == 0 then
        compose_and_send(batch) -- 全部来自缓存/在途
        return true, false
    end

    for _, i in ipairs(uncached) do
        local ctx = { batch = batch, idx = i, stage = "article" }
        local rid = jn.http.get_async(batch.entries[i].url, ctx, fetch_headers())
        if not rid or rid == 0 then
            batch.entries[i].err = "请求提交失败"
            batch.pending = batch.pending - 1
        end
    end
    if batch.pending <= 0 and not batch.llm_started then
        compose_and_send(batch) -- 全部提交失败
        return true, false
    end
    jn.log.info("[wechat-article-summary] 批量处理 " .. #uncached .. " 篇公众号文章")
    return true, false -- 消费：不进 Agent
end

jn.log.info("[wechat-article-summary] 公众号文章总结插件已加载")
