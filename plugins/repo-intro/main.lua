-- ====================================================================
-- repo-intro 仓库介绍插件
-- --------------------------------------------------------------------
-- 识别群聊/私聊中发送的 GitHub / Hugging Face / ModelScope 仓库链接。
-- 异步拉取元数据 + README，经串行节流队列调用 LLM 总结并渲染 T2I 卡片，
-- 仅在拿到有效总结时附带零宽水印与写入缓存。
-- ====================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

local function load_module(name, ...)
    local fname = name .. ".lua"
    local factory
    if type(jn.file) == "table" and type(jn.file.read) == "function" then
        local src, err = jn.file.read(fname)
        if not src then error(fname .. " 读取失败: " .. tostring(err)) end
        local chunk, lerr = loadstring(src, fname)
        if not chunk then error(fname .. " 语法错误: " .. tostring(lerr)) end
        local ok, f = pcall(chunk)
        if not ok or type(f) ~= "function" then error(fname .. " 初始化失败") end
        factory = f
    else
        local old_path = package and package.path
        if package then package.path = "data/pluggins/repo-intro/?.lua;" .. tostring(old_path or "") end
        local ok, f = pcall(require, name)
        if package then package.path = old_path or "" end
        if not ok or type(f) ~= "function" then error(fname .. " 读取失败: " .. tostring(f)) end
        factory = f
    end
    local ok2, mod = pcall(factory, jn, ...)
    if not ok2 or type(mod) ~= "table" then error(fname .. " 执行失败: " .. tostring(mod)) end
    return mod
end

local common = load_module("common")
local modeldb = load_module("modeldb")

local cfg_bool = common.cfg_bool
local cfg_num = common.cfg_num
local cfg_string = common.cfg_string
local is_model_entry = common.is_model_entry
local truncate = common.truncate
local url_encode = common.url_encode
local wm_own = common.wm_own
local b64_decode = common.b64_decode
local has_valid_llm = common.has_valid_llm

-- --------------------------------------------------------------------
-- URL 解析（提取一条消息中的全部仓库链接）
-- --------------------------------------------------------------------
local function host_boundary_ok(raw, s)
    local c = raw:sub(s - 1, s - 1)
    if c ~= "" and c:match("%w") then return false end
    if c == "." then
        return s >= 5 and raw:sub(s - 4, s - 2) == "www"
    end
    return true
end

local function match_host_all(raw, host)
    local out = {}
    local needle = host:gsub("%.", "%%.") .. "/"
    local hostlen = #host
    local s = raw:find(needle, 1)
    while s do
        if host_boundary_ok(raw, s) then
            local rest = raw:sub(s + hostlen + 1)
            local o, r = rest:match("^([%w%.%-_]+)/([%w%.%-_]+)")
            if o and r then
                out[#out + 1] = { owner = o, repo = r }
            end
        end
        s = raw:find(needle, s + 1)
    end
    return out
end

local function match_host_sub_all(raw, host, allowed)
    local out = {}
    local needle = host:gsub("%.", "%%.") .. "/"
    local hostlen = #host
    local s = raw:find(needle, 1)
    while s do
        if host_boundary_ok(raw, s) then
            local rest = raw:sub(s + hostlen + 1)
            local sub, o, r = rest:match("^([%w%-]+)/([%w%.%-_]+)/([%w%.%-_]+)")
            if sub and o and r then
                for _, a in ipairs(allowed) do
                    if a == sub then
                        out[#out + 1] = { sub = sub, owner = o, repo = r }
                        break
                    end
                end
            end
        end
        s = raw:find(needle, s + 1)
    end
    return out
end

local function parse_urls(raw)
    if not raw or raw == "" then return {} end
    local seen, entries = {}, {}
    local function add(kind, sub, owner, repo, url)
        local key = kind .. ":" .. (sub or "-") .. ":" .. owner .. "/" .. repo
        if seen[key] then return end
        seen[key] = true
        entries[#entries + 1] = { kind = kind, sub = sub, owner = owner, repo = repo, url = url, key = key }
    end

    for _, m in ipairs(match_host_all(raw, "github.com")) do
        add("github", nil, m.owner, m.repo, "https://github.com/" .. m.owner .. "/" .. m.repo)
    end
    for _, m in ipairs(match_host_sub_all(raw, "huggingface.co", { "models", "datasets", "spaces" })) do
        add("hf", m.sub, m.owner, m.repo, "https://huggingface.co/" .. m.sub .. "/" .. m.owner .. "/" .. m.repo)
    end
    for _, m in ipairs(match_host_all(raw, "huggingface.co")) do
        if m.owner ~= "api" and m.owner ~= "models" and m.owner ~= "datasets"
            and m.owner ~= "spaces" and m.repo ~= "collections" then
            add("hf", "models", m.owner, m.repo, "https://huggingface.co/" .. m.owner .. "/" .. m.repo)
        end
    end
    for _, host in ipairs({ "modelscope.cn", "modelscope.ai" }) do
        for _, m in ipairs(match_host_sub_all(raw, host, { "models", "datasets" })) do
            add("ms", m.sub, m.owner, m.repo, "https://" .. host .. "/" .. m.sub .. "/" .. m.owner .. "/" .. m.repo)
        end
    end
    return entries
end

-- --------------------------------------------------------------------
-- 元数据 / README URL 与工具
-- --------------------------------------------------------------------
local HF_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

local function meta_api_url(e)
    if e.kind == "github" then
        return "https://api.github.com/repos/" .. e.owner .. "/" .. e.repo
    elseif e.kind == "hf" then
        return "https://huggingface.co/api/" .. (e.sub or "models") .. "/" .. e.owner .. "/" .. e.repo
    elseif e.kind == "ms" then
        return "https://modelscope.cn/api/v1/" .. (e.sub or "models") .. "/" .. e.owner .. "/" .. e.repo
    end
end

local function gh_headers()
    local h = {
        ["User-Agent"] = "JuanNiang-Neo-repo-intro/1.0",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }
    local token = cfg_string("github_token", "")
    if token ~= "" then h["Authorization"] = "Bearer " .. token end
    return h
end

local function dataset_tree_url(e)
    if e.sub ~= "datasets" then return nil end
    if e.kind == "hf" then
        return "https://huggingface.co/api/datasets/" .. e.owner .. "/" .. e.repo .. "/tree/main"
    elseif e.kind == "ms" then
        return "https://modelscope.cn/api/v1/datasets/" .. e.owner .. "/" .. e.repo .. "/repo/tree?Revision=master"
    end
    return nil
end

local function readme_url_for(e)
    if e.kind == "github" then
        return "https://api.github.com/repos/" .. e.owner .. "/" .. e.repo .. "/readme", "readme"
    elseif e.kind == "hf" then
        return "https://huggingface.co/" .. e.owner .. "/" .. e.repo .. "/raw/main/README.md", "readme"
    elseif e.kind == "ms" then
        if e.sub == "datasets" and e.meta and e.meta.readme_content and e.meta.readme_content ~= "" then
            return nil, nil
        end
        return "https://modelscope.cn/api/v1/" .. (e.sub or "models") .. "/" .. e.owner .. "/" .. e.repo
            .. "/repo?Revision=master&FilePath=README.md", "readme"
    end
    return nil, nil
end

local function platform_label(e)
    if e.kind == "github" then return "GitHub" end
    if e.kind == "hf" then
        local sub = e.sub or "models"
        return "Hugging Face · " .. ({ models = "模型", datasets = "数据集", spaces = "Space" })[sub]
    end
    return "ModelScope · " .. (e.sub == "datasets" and "数据集" or "模型")
end

local function copy_ctx(ctx)
    local c = {}
    for k, v in pairs(ctx) do c[k] = v end
    return c
end

local function proxy_for(e)
    if e and (e.kind == "hf" or e.kind == "github") then
        return cfg_string("proxy", "")
    end
    return ""
end

local function http_get_for(e, url, ctx, headers)
    local p = proxy_for(e)
    local h = headers and copy_ctx(headers) or {}
    if e and e.kind == "hf" and not h["User-Agent"] then
        h["User-Agent"] = HF_UA
    end
    if p ~= "" then
        return jn.http.get_async(url, ctx, h, p)
    end
    if next(h) ~= nil then
        return jn.http.get_async(url, ctx, h)
    end
    return jn.http.get_async(url, ctx)
end

-- --------------------------------------------------------------------
-- 关键图提取（HF/MS 模型页 README + 引用博客）
-- --------------------------------------------------------------------
local function image_base_for(e)
    if e.kind == "hf" then
        return "https://huggingface.co/" .. e.owner .. "/" .. e.repo .. "/resolve/main/"
    elseif e.kind == "ms" then
        return "https://modelscope.cn/models/" .. e.owner .. "/" .. e.repo .. "/resolve/master/"
    end
    return ""
end

local function scan_images(blob, base, out, seen, cap)
    if not blob or blob == "" then return end
    local function add(u)
        if not u or u == "" or #out >= cap then return end
        u = u:gsub("&amp;", "&")
        local low = u:lower()
        if low:match("^data:") or low:find("shields%.io", 1, true)
            or low:find("badge", 1, true) or low:find("avatar", 1, true)
            or low:match("%.svg$") then return end
        if not u:match("^https?://") then u = base .. u:gsub("^/", "") end
        if not seen[u] then seen[u] = true; out[#out + 1] = u end
    end
    for u in blob:gmatch('<img%s[^>]-src%s*=%s*"([^"]+)"') do add(u) end
    for u in blob:gmatch("<img%s[^>]-src%s*=%s*'([^']+)'") do add(u) end
    for u in blob:gmatch('!%[%[^%]]*%]%(([^%s%)]+)') do add(u) end
end

local function collect_readme_images(e)
    if not is_model_entry(e) or not e.readme or e.readme == "" then return {} end
    local limit = cfg_num("key_image_count", 2)
    if limit <= 0 then return {} end
    local proxy = cfg_string("key_image_proxy", "https://wsrv.nl/?url=")
    local http_proxy = cfg_string("proxy", "")
    local candidates, seen = {}, {}
    scan_images(e.readme, image_base_for(e), candidates, seen, 8)

    local pseen, pages = {}, 0
    for raw_u in e.readme:gmatch('https?://[%w%-%._/%?=&#]+') do
        local u = raw_u:gsub("&amp;", "&")
        if (u:find("/blog/", 1, true) or u:find("/news/", 1, true)
                or u:find("arxiv.org/abs/", 1, true) or u:find("model%-card", 1, true))
            and not pseen[u] and pages < 2 then
            pseen[u] = true
            pages = pages + 1
            local fetch_url = u:gsub("^https://hf%.co", "https://huggingface.co")
            local ok, res = pcall(function()
                if http_proxy ~= "" and not fetch_url:find("modelscope%.cn", 1) then
                    return jn.http.get(fetch_url, http_proxy)
                end
                return jn.http.get(fetch_url)
            end)
            if ok and res and res.body and res.body ~= "" then
                scan_images(res.body, fetch_url .. "/", candidates, seen, 8)
            end
        end
    end

    local chosen = {}
    for _, u in ipairs(candidates) do
        if #chosen >= limit then break end
        local desc
        local ok, v = pcall(function()
            return jn.llm.vision_url("", u,
                "这张图是模型架构图、结构图、流程图或 benchmark/性能对比图表吗？只回答：是/否 + 一句话说明。")
        end)
        if ok then desc = v end
        local low = tostring(desc or ""):lower()
        local relevant = low:find("架构", 1, true) or low:find("结构", 1, true)
            or low:find("流程", 1, true) or low:find("benchmark", 1, true)
            or low:find("基准", 1, true) or low:find("性能", 1, true)
            or low:find("图表", 1, true) or low:find("architect", 1, true)
            or low:find("diagram", 1, true) or low:find("chart", 1, true)
            or low:find("performance", 1, true)
        local is_logo = low:find("logo", 1, true) or low:find("标志", 1, true)
            or low:find("商标", 1, true)
        if relevant and not is_logo then chosen[#chosen + 1] = u end
    end

    if #chosen == 0 then
        for _, u in ipairs(candidates) do
            local low = u:lower()
            if low:find("bench", 1, true) or low:find("arch", 1, true)
                or low:find("figure", 1, true) or low:find("eval", 1, true) then
                chosen[#chosen + 1] = u
                if #chosen >= limit then break end
            end
        end
    end

    local out = {}
    for _, u in ipairs(chosen) do
        out[#out + 1] = proxy ~= "" and (proxy .. url_encode(u)) or u
    end
    return out
end

-- --------------------------------------------------------------------
-- 附带文本与元数据提取
-- --------------------------------------------------------------------
local function context_text_for(raw)
    if not cfg_bool("use_context_text", true) or not raw or raw == "" then return "" end
    local s = raw:gsub("%[[^%]]*%]%(%s*[^%)]*%s*%)", " "):gsub("https?://[^%s%)%]%>]+", " ")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #s < 9 then return "" end
    if #s > 2000 then return s:sub(1, 2000) end
    return s
end

local function extract_meta(e, data)
    if e.kind == "github" then
        return {
            name = data.full_name or (e.owner .. "/" .. e.repo),
            desc = data.description,
            lang = data.language,
            stars = data.stargazers_count,
            forks = data.forks_count,
            issues = data.open_issues_count,
            topics = data.topics,
            avatar = data.owner and data.owner.avatar_url,
        }
    elseif e.kind == "hf" then
        local st = data.safetensors
        local param_count = nil
        if type(st) == "table" then
            if type(st.parameters) == "table" then
                local sum = 0
                for _, v in pairs(st.parameters) do sum = sum + (tonumber(v) or 0) end
                if sum > 0 then param_count = sum end
            end
            if not param_count then param_count = tonumber(st.total) or nil end
        end
        local ds_files, ds_configs = nil, nil
        if e.sub == "datasets" then
            if type(data.siblings) == "table" then ds_files = #data.siblings end
            local cd = data.cardData
            if type(cd) == "table" and type(cd.configs) == "table" then
                ds_configs = {}
                for i, c in ipairs(cd.configs) do
                    if i > 6 then break end
                    local files = {}
                    for _, f in ipairs(c.data_files or {}) do files[#files + 1] = tostring(f.path or "") end
                    ds_configs[#ds_configs + 1] = {
                        name = tostring(c.config_name or ""),
                        splits = #(c.data_files or {}),
                        files = files,
                    }
                end
            end
        end
        return {
            name = data.id or (e.owner .. "/" .. e.repo),
            pipeline = data.pipeline_tag,
            library = data.library_name,
            downloads = data.downloads,
            likes = data.likes,
            tags = data.tags,
            files_count = ds_files,
            configs = ds_configs,
            params = param_count,
            avatar = nil,
        }
    elseif e.kind == "ms" then
        local d = data.Data or data
        return {
            name = e.owner .. "/" .. e.repo,
            desc = d.Description,
            chinese_name = d.ChineseName,
            downloads = d.Downloads,
            likes = d.Likes,
            size = d.Size,
            license = d.License,
            readme_content = d.ReadmeContent,
            avatar = (d.Avatar ~= nil and d.Avatar ~= "") and d.Avatar or nil,
        }
    end
end

-- --------------------------------------------------------------------
-- 缓存读写
-- --------------------------------------------------------------------
local function repo_cache_key(e)
    return "intro:v6:" .. e.key
end

local function repo_cache_get(e)
    local v = jn.cache.get(repo_cache_key(e))
    if type(v) ~= "table" then return nil end
    if e.kind == "github" and v.desc_cn == nil then return nil end
    if cfg_bool("card_enabled", true) and v.card_url == nil then return nil end
    if (v.title == nil or v.title == "") and (v.summary == nil or v.summary == "") then return nil end
    return v
end

local function repo_cache_set(e, content)
    if type(content) ~= "table" then return end
    if (content.title == nil or content.title == "") and (content.summary == nil or content.summary == "") then
        return
    end
    jn.cache.set(repo_cache_key(e), content, cfg_num("cache_ttl", 604800))
end

local card = load_module("card", common, modeldb, {
    collect_readme_images = collect_readme_images,
    repo_cache_set = repo_cache_set,
})

-- --------------------------------------------------------------------
-- LLM 提示词与输入构造
-- --------------------------------------------------------------------
local function llm_system_prompt()
    local min_c = tostring(cfg_num("summary_min_chars", 50))
    local max_c = tostring(cfg_num("summary_max_chars", 500))
    local max_n = tonumber(max_c) or 500
    local gh_max_n = math.min(500, max_n)
    local gh_min_n = math.min(150, gh_max_n)
    local gh_min, gh_max = tostring(gh_min_n), tostring(gh_max_n)
    local p = [[你是中文仓库介绍助手。用户会给你若干仓库（GitHub / Hugging Face / ModelScope）的元数据与 README 内容，请对每个仓库独立判定类型、写出简体中文介绍，最后按指定 JSON 输出。

【零、通用铁律（所有仓库必做）】
1. 只写 README、元数据与【附带文本】中明确给出的内容，禁止编造参数量、分数、功能、许可证、安装命令、API 价格、Star 数；未写明的直接省略。
2. summary 一律简体中文，英文内容翻译；项目名、命令、API 名、模型名保留原文。
3. 每个仓库独立判断类型，禁止按组织/前缀归一类；同一组织不同仓库类型可能完全不同。
4. README 不一定是 README.md（可能是 README.org/.rst），别把"有文档"误判成"无文档"；多个仓库务必全部覆盖，不得遗漏。
5. desc_cn：仓库官方 description 的简体中文翻译（≤60 字），GitHub 仓库必填；无官方描述则填空字符串。
6. 【附带文本】是分享者随链接发来的消息片段（推文/推荐语等），不是仓库官方文档。仅当它确实描述了某个仓库的用途、功能、安装或使用方式时，才把它作为该仓库的补充信息并入 summary（例如补充了 README 没有的一句话定位或安装命令）；它与 README 冲突时以 README 为准。若是与仓库无关的闲聊、个人情绪、晒 Star、祝贺、转发语、感谢、广告等噪声，一律忽略，禁止写入任何字段；不要把某个仓库的附带文本安到别的仓库头上。
7. 严禁输出空话套话与"元信息旁白"，包括但不限于："推测与XX相关""具体内容/用途需查阅仓库代码与文档""具体功能详见仓库文档""未提供详细文档，待作者补充""当前元数据未包含功能描述，以仓库内容为准""仓库未提供进一步功能说明与文档""README 未说明""暂无描述""未说明/未给出/未提及"等。README 内容少或被截断时，也要从已有的标题、一句话描述、元数据里提炼可写的信息；实在没有，summary 输出空字符串（绝不硬凑），title 可只写仓库名。宁可少说，不可说废话。
8. 严禁大段罗列与流水账：任何清单——智能体、平台、设备、模型、技术栈、语言——**一律最多列 2 个，其余用"等"带过，宁少勿多**（如"支持 Claude Code 等主流编码 Agent"；"iOS 与 Web 端"而非"iOS/Android App、Web 与桌面端"）。禁止完整罗列（如 Claude Code、Codex、Cursor、Grok Build、OpenCode 全写出来）；安装/部署最多给一条极短命令（如 npx skills add owner/repo、npm install -g 包名），超过约 80 字符或需要完整 URL/API Key/多步骤时改用文字说明；MCP/Skills/插件类优先写支持哪些 Agent（最多 2 个具名，如"支持 Claude Code、Codex 等"），不要写长命令。多平台（Windows/macOS/Arch）、Node 版本要求、完整 clone+install 步骤、配置文件路径、目录结构等细节一律省略或一句话带过；技术栈/语言最多提 1 个（如"React 编写"）或省略。summary 精炼，突出"是什么、能做什么、关键数字"，一般一两句话、不超过 __MAX__ 字。
9. summary 不得重复官方 description/desc_cn 已展示过的原文——描述行之外才写 summary，内容应是描述没有的实质信息（能力、用途、规模、一条极短命令或支持哪些 Agent）。
10. summary 中任何并列清单（智能体/平台/设备/模型/语言等）**具名项只允许 1~2 个**：写 2 个用"A、B 等"，写 1 个用"A 等"。3 个具名项即违规。安装/部署命令整条 summary 最多 1 条且不超过约 80 字符；能写"支持哪些 Agent"就不写命令，禁止贴完整 URL、API Key、查询参数或多步骤。跨平台/多端类仓库直接概括为"跨平台"或"iOS、Android 等主流端"（≤2），禁止点齐所有平台。
11. **有权重可下载的模型（HF/MS 模型页、GitHub 发布权重的仓库）禁止写"闭源"**：这是开源权重，写"闭源"属事实错误。许可证未标注就写"许可未标注"或干脆不提。
12. 参数量取数优先级：元数据精确计数 > README 明写 > 模型名里的规模（如 65B、27B、24.7M）。模型名含 A13B/A3B 的是 MoE 激活参数，总参须另找；名字里没有、README 也没写就给空，禁止用 0B、≈、约等占位。
13. type 必填（即使 summary 留空）：用最短中文类型名，如"文本对话""多模态""TTS""ASR""图像生成""视频生成""3D生成""时序预测""嵌入""重排序""工作流""数据集""Space""MCP 插件""Agent 项目""工具库"。

【一、GitHub 仓库类型判定与总结】
1. MCP / Skills / Agent 插件类：核心特征是"装进某个 Agent 直接用"的能力包。summary 写产品定位一句话 + 核心能力 1~2 点 + 支持哪些 Agent（≤2 具名），不写长安装命令。
2. AI Agent 项目：核心特征是可独立运行的程序/工作流。summary 写输入→输出、核心能力与部署方式。
3. 其他类（SDK/网关/Web 应用/数据集/论文实现/教程/工具/模型仓库等）：按【一·A】写清定位、机制、能力与用法。

【一·A、GitHub 项目总结范式（代码仓库，不要套用模型卡范式）】
目标：读者不点开 README 也能知道这个项目做什么、怎么运转、有什么具体能力、怎么跑起来。README 内容充分时写 2~3 段、约 __GH_MIN__~__GH_MAX__ 字；内容稀少时写短，但至少要有"定位 + 一个具体信息点"。
1. 定位：不要重复 desc_cn 的官方描述原文，要补充"具体做什么"。
2. 工作方式：输入→输出、核心流程、关键机制/协议/架构。
3. 具体能力：2~3 个可验证的能力点，尽量带对象/格式/平台/数量/性能数字。
4. 使用/部署：优先写支持哪些 Agent/客户端或运行方式；命令只给一条极短命令（≤80 字符）。
5. 适用场景/限制、技术栈（最多提 1 个）：可选，简洁带过。
硬性要求：至少包含 2 个实质信息点；不写"详见文档/需查阅代码/未提供说明"等元信息旁白；具名清单最多 2 个。

【二、Hugging Face / ModelScope 模型类型判定与总结】
按 pipeline_tag、README frontmatter、tags、路由与名字区分：文本对话/推理、多模态 VLM、OCR·文档理解、Omni 全模态、机器人·具身、嵌入、重排序、图像生成、视频生成、TTS、ASR、数据集、Space。
【二·A、HF/MS 模型卡片总结范式（模型页字数上限 __MAX__）】
以技术底层为主，内容充分时写成 1~4 段、最多 __MAX__ 字：1. 定位与架构；2. 参数与计算口径（总参/激活参）；3. 核心特色与能力；4. 最多 3 个代表性 Benchmark；5. 工程信息（精度/量化/推理框架）；6. 最多 3 条官方链接（须包含输入 url）。禁止估算或写"约/≈"。
- 数据集：根据 file_list、configs、tags 与 README 写清数据内容、文件组织、规模、语言与格式。
- Space：写清 SDK、功能、能否在线使用。

【三、输出格式】严格只输出如下 JSON（不要输出 JSON 以外的任何内容，不要用代码块包裹）：
{"repos":[{"index":1,"type":"类型中文名","title":"一句话标题（简体中文，≤30字，无信息时可用仓库名，禁止套话）","summary":"精炼介绍（简体中文；GitHub 按【一·A】写 __GH_MIN__~__GH_MAX__ 字，HF/MS 模型页按【二·A】写；内容稀少时写短或留空；突出是什么、怎么运转、能做什么、关键数字；严禁空话套话旁白；不得重复 desc_cn）","desc_cn":"官方描述中文翻译（GitHub 必填，无则空字符串）"}]}
index 与输入仓库编号一一对应（从 1 开始）。]]
    p = p:gsub("__MIN__", min_c):gsub("__MAX__", max_c)
    return p:gsub("__GH_MIN__", gh_min):gsub("__GH_MAX__", gh_max)
end

local function repo_input_for_llm(e, idx)
    local m = e.meta or {}
    local t = { index = idx, platform = platform_label(e), url = e.url }
    if e.kind == "github" then
        t.name = m.name; t.description = m.desc; t.language = m.lang
        t.stars = m.stars; t.forks = m.forks; t.topics = m.topics
    elseif e.kind == "hf" then
        t.name = m.name; t.pipeline = m.pipeline; t.library = m.library
        t.downloads = m.downloads; t.likes = m.likes; t.params = m.params
        if e.sub == "datasets" then
            t.kind = "dataset"; t.tags = m.tags; t.files_count = m.files_count
            t.configs = m.configs; t.file_list = e.file_list; t.sample = e.sample
        end
    elseif e.kind == "ms" then
        t.name = m.name; t.description = m.desc; t.chinese_name = m.chinese_name
        t.downloads = m.downloads; t.likes = m.likes
        if e.sub == "datasets" then
            t.kind = "dataset"; t.size = m.size; t.license = m.license
            t.file_list = e.file_list; t.sample = e.sample
        end
    end
    local s = "【仓库 " .. idx .. "】" .. jn.json.encode(t)
    if e.readme and e.readme ~= "" then
        s = s .. "\nREADME 内容（" .. e.owner .. "/" .. e.repo .. "）：\n" .. e.readme
    end
    return s
end

-- --------------------------------------------------------------------
-- 异步流水线：LLM 串行节流队列 + 退避重试
-- --------------------------------------------------------------------
local llm_ctx = {}
local llm_queue = {}
local llm_inflight = false
local llm_last_dispatch = 0
local llm_last_done = 0
local llm_pump_scheduled = false

local function schedule_llm_pump(delay)
    if llm_pump_scheduled then return end
    if jn.timer and jn.timer.after then
        llm_pump_scheduled = true
        jn.timer.after(math.max(0.1, delay), { action = "llm_pump" })
    end
end

local function pump_llm_queue()
    if llm_inflight then return end
    local task = llm_queue[1]
    if not task then return end
    local min_gap = math.max(0, cfg_num("llm_min_interval", 3))
    local last_ts = math.max(llm_last_dispatch, llm_last_done)
    local elapsed = os.time() - last_ts
    if last_ts > 0 and elapsed < min_gap and jn.timer and jn.timer.after then
        schedule_llm_pump(min_gap - elapsed)
        return
    end
    table.remove(llm_queue, 1)
    llm_inflight = true
    llm_last_dispatch = os.time()
    local rid = jn.llm.chat_async(task.batch.llm_messages, { timeout = cfg_num("llm_timeout", 60) })
    if not rid or rid == 0 then
        llm_inflight = false
        jn.log.warn("[repo-intro] llm.chat_async 提交失败，降级为无摘要发送")
        card.compose_and_send(task.batch)
        schedule_llm_pump(min_gap)
        return
    end
    llm_ctx[rid] = task
end

local function start_llm(batch)
    if batch.llm_started then return end
    batch.llm_started = true
    local usable = {}
    for _, i in ipairs(batch.uncached) do
        local e = batch.entries[i]
        if not e.err and e.meta then usable[#usable + 1] = e end
    end
    if #usable == 0 or not cfg_bool("enable_summary", true) or not jn.llm or not jn.llm.available() then
        card.compose_and_send(batch)
        return
    end

    local parts = {}
    for idx, e in ipairs(usable) do parts[#parts + 1] = repo_input_for_llm(e, idx) end
    local messages = {
        { role = "system", content = llm_system_prompt() },
        { role = "user", content = table.concat(parts, "\n\n") },
    }
    if batch.context_text and batch.context_text ~= "" then
        messages[2].content = messages[2].content
            .. "\n\n【附带文本（分享者随链接发来的消息，非仓库官方文档，与仓库无关的噪声请忽略）】\n"
            .. batch.context_text
    end
    batch.llm_messages = messages
    batch.llm_usable = usable
    llm_queue[#llm_queue + 1] = { batch = batch, retry = 0 }
    pump_llm_queue()
end

local function check_batch(batch)
    if batch.pending <= 0 then start_llm(batch) end
end

-- --------------------------------------------------------------------
-- HTTP 阶段回调
-- --------------------------------------------------------------------
local function handle_meta(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    local status = result and result.status or 0
    if err then
        local attempt = (ctx.fetch_attempt or 0) + 1
        if attempt <= 1 then
            local c = copy_ctx(ctx)
            c.fetch_attempt = attempt
            local rid = http_get_for(e, meta_api_url(e), c, e.kind == "github" and gh_headers() or nil)
            if rid and rid ~= 0 then return end
        end
        e.err = "请求失败：" .. tostring(err)
        jn.log.warn("[repo-intro] 仓库元数据获取失败 url=" .. (e.url or "") .. " err=" .. tostring(err))
        batch.pending = batch.pending - 1
        return
    end
    if status == 403 or status == 429 then
        e.err = e.kind == "github" and ("GitHub API 限流，请稍后再试（" .. e.owner .. "/" .. e.repo .. "）")
            or ("接口限流，请稍后再试（" .. e.owner .. "/" .. e.repo .. "）")
        jn.log.warn("[repo-intro] 仓库接口限流 url=" .. (e.url or "") .. " status=" .. status)
        batch.pending = batch.pending - 1
        return
    end
    if status < 200 or status >= 300 then
        e.err = "未找到仓库 " .. e.owner .. "/" .. e.repo
        jn.log.warn("[repo-intro] 仓库不存在或不可访问 url=" .. (e.url or "") .. " status=" .. status)
        batch.pending = batch.pending - 1
        return
    end
    local data = jn.json.decode(result.body or "")
    if type(data) ~= "table" then
        e.err = "未找到仓库 " .. e.owner .. "/" .. e.repo
        jn.log.warn("[repo-intro] 仓库元数据解析失败 url=" .. (e.url or "") .. " status=" .. status)
        batch.pending = batch.pending - 1
        return
    end
    e.meta = extract_meta(e, data)

    local dturl = dataset_tree_url(e)
    if dturl then
        batch.pending = batch.pending + 1
        local ct = copy_ctx(ctx)
        ct.stage = "dataset_tree"
        local drid = http_get_for(e, dturl, ct)
        if not drid or drid == 0 then batch.pending = batch.pending - 1 end
    end
    local url, stage = readme_url_for(e)
    if not url then
        batch.pending = batch.pending - 1
        return
    end
    local c = copy_ctx(ctx)
    c.stage = stage
    local rid = http_get_for(e, url, c, e.kind == "github" and gh_headers() or nil)
    if not rid or rid == 0 then batch.pending = batch.pending - 1 end

    if e.kind == "hf" or e.kind == "ms" then
        batch.pending = batch.pending + 1
        local ca = copy_ctx(ctx)
        ca.stage = "avatar"
        local page = (e.kind == "hf") and ("https://huggingface.co/" .. e.owner)
            or ("https://modelscope.cn/" .. (e.sub == "datasets" and "datasets" or "models")
                .. "/" .. e.owner .. "/" .. e.repo)
        local rid2 = http_get_for(e, page, ca)
        if not rid2 or rid2 == 0 then batch.pending = batch.pending - 1 end
    end
end

local function dataset_sample_url(e, files)
    if not files then return nil end
    local pick = nil
    for _, pat in ipairs({ "%.csv$", "%.jsonl$", "%.json$" }) do
        for _, f in ipairs(files) do
            if f:sub(-1) ~= "/" and f:lower():match(pat) then pick = f; break end
        end
        if pick then break end
    end
    if not pick then return nil end
    if e.kind == "hf" then
        return "https://huggingface.co/datasets/" .. e.owner .. "/" .. e.repo .. "/resolve/main/" .. pick
    elseif e.kind == "ms" then
        return "https://modelscope.cn/api/v1/datasets/" .. e.owner .. "/" .. e.repo
            .. "/repo?Revision=master&FilePath=" .. pick
    end
    return nil
end

local function sample_fields(body)
    if not body or body == "" then return nil end
    local head = body:sub(1, 2000)
    local first_line = head:match("^([^\n]+)")
    if not first_line or first_line == "" then return nil end
    if first_line:find(",", 1, true) and not first_line:find("{", 1, true) then
        local cols = {}
        for c in first_line:gmatch("([^,]+)") do
            c = c:gsub('^%s*"?', ""):gsub('"%s*$', ""):gsub("%s+$", "")
            if c ~= "" then cols[#cols + 1] = c end
            if #cols >= 20 then break end
        end
        if #cols > 1 then return table.concat(cols, ", ") end
        return nil
    end
    local obj = first_line:match("^{.*}") or head:match("(%b{})")
    if obj then
        local keys = {}
        for k in obj:gmatch('"([%w_%-%./ ]+)"%s*:') do
            keys[#keys + 1] = k
            if #keys >= 20 then break end
        end
        if #keys > 0 then return table.concat(keys, ", ") end
    end
    return nil
end

local function handle_dataset_tree(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    if not err and result and result.status == 200 and result.body and result.body ~= "" then
        local d = jn.json.decode(result.body)
        local list = {}
        if e.kind == "hf" and type(d) == "table" then
            for _, x in ipairs(d) do
                if type(x) == "table" then
                    local p = tostring(x.path or "")
                    if x.type == "directory" then p = p .. "/" end
                    list[#list + 1] = p
                end
            end
        elseif e.kind == "ms" and type(d) == "table" then
            local dd = d.Data or d
            for _, x in ipairs(dd.Files or {}) do
                if type(x) == "table" then list[#list + 1] = tostring(x.Path or x.Name or "") end
            end
        end
        if #list > 0 then
            local full = list
            if #list > 40 then
                local cut = {}
                for i = 1, 40 do cut[i] = full[i] end
                cut[#cut + 1] = "…(共 " .. #full .. " 项)"
                list = cut
            end
            e.file_list = list
            local surl = dataset_sample_url(e, full)
            if surl then
                batch.pending = batch.pending + 1
                local cs = copy_ctx(ctx)
                cs.stage = "dataset_sample"
                local srid = http_get_for(e, surl, cs, { ["Range"] = "bytes=0-2047" })
                if not srid or srid == 0 then batch.pending = batch.pending - 1 end
            end
        end
    end
    batch.pending = batch.pending - 1
end

local function handle_dataset_sample(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    if not err and result and result.status and result.status < 400 and result.body then
        local fields = sample_fields(result.body)
        if fields then e.sample = fields end
    end
    batch.pending = batch.pending - 1
end

local function handle_readme(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    if e.kind == "github" then
        if err or not result or result.status < 200 or result.status >= 300 then
            batch.pending = batch.pending - 1
            return
        end
        local data = jn.json.decode(result.body or "")
        if type(data) ~= "table" then
            batch.pending = batch.pending - 1
            return
        end
        local decoded = b64_decode(data.content)
        if decoded and decoded ~= "" then
            e.readme = truncate(decoded, e)
            batch.pending = batch.pending - 1
            return
        end
        if not data.download_url then
            batch.pending = batch.pending - 1
            return
        end
        local c = copy_ctx(ctx)
        c.stage = "readme_raw"
        local rid = http_get_for(e, data.download_url, c, gh_headers())
        if not rid or rid == 0 then batch.pending = batch.pending - 1 end
        return
    end

    if e.kind == "hf" then
        if not err and result and result.status == 200 and result.body and result.body ~= "" then
            e.readme = truncate(result.body, e)
            e.key_images = collect_readme_images(e)
            batch.pending = batch.pending - 1
            return
        end
        local attempt = (ctx.readme_attempt or 0) + 1
        if attempt <= 1 then
            local c = copy_ctx(ctx)
            c.stage = "readme"
            c.readme_attempt = attempt
            local url = "https://huggingface.co/" .. e.owner .. "/" .. e.repo .. "/raw/master/README.md"
            local rid = http_get_for(e, url, c)
            if rid and rid ~= 0 then return end
        end
        batch.pending = batch.pending - 1
        return
    end

    if not err and result and result.status == 200 and result.body and result.body ~= "" then
        e.readme = truncate(result.body, e)
        e.key_images = collect_readme_images(e)
    end
    batch.pending = batch.pending - 1
end

local function handle_avatar(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    if not err and result and result.status == 200 and result.body and e.meta then
        local src = result.body:match("https://cdn%-avatars%.huggingface%.co/v1/production/uploads/[%w%-%._/]+")
            or result.body:match("https://resouces%.modelscope%.cn/avatar/[%w%-%.]+%.%a+")
        if src then e.meta.avatar_src = src end
    end
    batch.pending = batch.pending - 1
end

local function handle_readme_raw(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    if not err and result and result.status == 200 and result.body and result.body ~= "" then
        e.readme = truncate(result.body, e)
    end
    batch.pending = batch.pending - 1
end

-- --------------------------------------------------------------------
-- 引擎回调入口
-- --------------------------------------------------------------------
function on_http_response(req_id, ctx, result, err)
    if not ctx or not ctx.batch or not ctx.stage then return end
    if ctx.stage == "meta" then
        handle_meta(ctx, result, err)
    elseif ctx.stage == "readme" then
        handle_readme(ctx, result, err)
    elseif ctx.stage == "readme_raw" then
        handle_readme_raw(ctx, result, err)
    elseif ctx.stage == "dataset_tree" then
        handle_dataset_tree(ctx, result, err)
    elseif ctx.stage == "dataset_sample" then
        handle_dataset_sample(ctx, result, err)
    elseif ctx.stage == "avatar" then
        handle_avatar(ctx, result, err)
    end
    check_batch(ctx.batch)
end

function on_t2i_response(req_id, ctx, result, err)
    card.on_t2i_response(req_id, ctx, result, err)
end

function on_chat_response(req_id, content, err)
    local task = llm_ctx[req_id]
    if not task then return end
    llm_ctx[req_id] = nil
    llm_inflight = false
    llm_last_done = os.time()

    local batch = task.batch
    local usable = batch.llm_usable or {}
    local min_gap = math.max(0, cfg_num("llm_min_interval", 3))
    local max_retries = math.max(0, cfg_num("llm_max_retries", 3))

    local results = nil
    if not (err and err ~= "") then
        local cleaned = (content or ""):gsub("```[%w]*\n?", ""):gsub("```", "")
        local ok, obj = pcall(jn.json.decode, cleaned)
        if not ok or type(obj) ~= "table" then
            local s = cleaned:find("{", 1, true)
            local epos = cleaned:match(".*()}")
            if s and epos and epos > s then
                ok, obj = pcall(jn.json.decode, cleaned:sub(s, epos))
            end
        end
        if ok and type(obj) == "table" and type(obj.repos) == "table" and #obj.repos > 0 then
            results = obj.repos
        end
    end

    if (err and err ~= "") or not results then
        local tries = (task.retry or 0) + 1
        local reason = (err and err ~= "") and tostring(err) or "返回非有效 JSON/空 repos"
        if tries <= max_retries and batch.llm_messages then
            task.retry = tries
            local backoff = math.min(30, 4 * tries)
            jn.log.warn(string.format("[repo-intro] LLM 失败，%ds 后退避重试(%d/%d): %s",
                backoff, tries, max_retries, reason))
            if jn.timer and jn.timer.after then
                jn.timer.after(backoff, { action = "llm_retry", task = task })
                schedule_llm_pump(min_gap)
                return
            end
        end
        jn.log.warn("[repo-intro] LLM 总结失败（降级无水印、不写缓存）: " .. reason)
        for _, e in ipairs(usable) do e.llm = nil end
        card.compose_and_send(batch)
        schedule_llm_pump(min_gap)
        return
    end

    local used = {}
    local pending_content = batch.pending_content or {}
    for _, r in ipairs(results) do
        if type(r) == "table" and r.index then
            local idx = tonumber(r.index)
            local e = idx and usable[idx]
            if e then
                local content_tbl = {
                    type = r.type and tostring(r.type) or "",
                    title = r.title and tostring(r.title) or "",
                    summary = r.summary and tostring(r.summary) or "",
                    desc_cn = r.desc_cn and tostring(r.desc_cn) or "",
                    desc = (e.meta and e.meta.desc) or "",
                    card_url = (e.card_url and tostring(e.card_url)) or "",
                }
                e.llm = content_tbl
                if has_valid_llm(e) then
                    pending_content[idx] = content_tbl
                    used[idx] = true
                else
                    e.llm = nil
                end
            end
        end
    end
    for idx, e in ipairs(usable) do
        if not used[idx] then e.llm = nil end
    end

    batch.pending_content = pending_content
    schedule_llm_pump(min_gap)
    card.start_cards(batch)
end

function on_timer_response(req_id, ctx, result, err)
    if not ctx or type(ctx) ~= "table" then return end
    if ctx.action == "llm_pump" then
        llm_pump_scheduled = false
        pump_llm_queue()
    elseif ctx.action == "llm_retry" and ctx.task then
        table.insert(llm_queue, 1, ctx.task)
        pump_llm_queue()
    end
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

local function build_batch(event)
    local all = parse_urls(event.raw_message or "")
    local max = cfg_num("max_repos", 5)
    local entries, uncached = {}, {}
    for _, e in ipairs(all) do
        if #entries >= max then
            jn.log.info("[repo-intro] 单条链接数超过 " .. max .. "，忽略后续")
            break
        end
        local enabled = true
        if e.kind == "github" and not cfg_bool("enable_github", true) then enabled = false end
        if e.kind == "hf" and not cfg_bool("enable_huggingface", true) then enabled = false end
        if e.kind == "ms" and not cfg_bool("enable_modelscope", true) then enabled = false end
        if enabled then
            local cached = repo_cache_get(e)
            if cached then
                e.llm = cached
                e.card_url = cached.card_url or ""
                e.done = true
            else
                local dedup = jn.cache.get("dedup:" .. e.key)
                if dedup and (os.time() - tonumber(dedup) < 60) then
                    e.done = true
                    e.skipped = true
                else
                    jn.cache.set("dedup:" .. e.key, os.time(), 60)
                    e.owned_dedup = true
                    uncached[#uncached + 1] = #entries + 1
                end
            end
            entries[#entries + 1] = e
        end
    end
    return entries, uncached
end

function on_message(event)
    if not event then return false, false end
    if is_self(event) then return false, false end
    local raw = event.raw_message or ""
    if raw:sub(1, 1) == "/" then return false, false end
    if wm_own(raw) then return true, false end
    if cfg_bool("group_only", false) and event.message_type ~= "group" then return false, false end

    local entries, uncached = build_batch(event)
    if #entries == 0 then return false, false end

    local batch = {
        entries = entries,
        uncached = uncached,
        pending = #uncached,
        context_text = context_text_for(raw),
        target = {
            message_type = event.message_type,
            target_id = (event.group_id ~= 0 and event.group_id) or event.user_id,
            message_id = event.message_id,
            reply_quote = cfg_bool("reply_quote", true),
        },
    }

    if batch.pending == 0 then
        card.compose_and_send(batch)
        return true, false
    end

    for _, i in ipairs(uncached) do
        local ctx = { batch = batch, idx = i, stage = "meta" }
        local entry = batch.entries[i]
        local rid = http_get_for(entry, meta_api_url(entry), ctx,
            entry.kind == "github" and gh_headers() or nil)
        if not rid or rid == 0 then
            batch.entries[i].err = "请求提交失败"
            batch.pending = batch.pending - 1
        end
    end
    if batch.pending <= 0 and not batch.llm_started then
        card.compose_and_send(batch)
        return true, false
    end
    jn.log.info("[repo-intro] 批量处理 " .. #uncached .. " 个仓库链接")
    return true, false
end

jn.log.info("[repo-intro] 仓库介绍插件已加载")
