-- ====================================================================
-- repo-intro 仓库介绍插件
-- --------------------------------------------------------------------
-- 识别群聊/私聊中发送的 GitHub / Hugging Face / ModelScope 仓库链接。
-- 一条消息可含多个链接：逐仓库拉取元数据 + README（异步），合并为
-- 一次 LLM 调用（三个平台同一个提示词），由 LLM 判定每个仓库的类型并
-- 总结，最终一条消息输出，每个仓库一段、各自附上链接，段间空两行。
-- 复用主程序 LLM API（jn.llm.chat_async），全程异步不阻塞事件循环。
-- --------------------------------------------------------------------
-- 异步流水线（引擎级异步注册表，回调串行派发）：
--   on_message            → 解析全部链接，未命中缓存者逐个 http.get_async(元数据)
--   on_http_response(meta) → 逐个 http.get_async(README)
--   on_http_response(readme) → 全部就绪后 llm.chat_async(一次调用)
--   on_chat_response      → 逐仓库缓存 LLM 结果 → 组装消息段发送
-- 每个仓库的 LLM 结果独立缓存（jn.cache，按 TTL 过期），后续再遇到
-- 同仓库直接复用，跳过 HTTP 与 LLM。
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
-- 水印：零宽字符标记机器人输出（ZWSP+ZWNJ+ZWJ+BOM，不可见但可检测）。
-- 他人转发本机总结时，raw 里含该水印 → on_message 忽略，避免二次总结循环。
-- --------------------------------------------------------------------
local WATERMARK = "\226\128\139\226\128\140\226\128\141\239\187\191"

-- --------------------------------------------------------------------
-- URL 解析（提取一条消息中的全部仓库链接）
-- --------------------------------------------------------------------
-- 在 raw 中定位 host 之后的两段路径（owner/repo），返回全部命中。
-- 校验 host 前一个字符不是字母/数字/点，避免误匹配 api.github.com 等
-- 子域；允许前导 "www."。
local function match_host_all(raw, host)
    local out = {}
    local escaped = host:gsub("%.", "%%.")
    local needle = escaped .. "/"
    local hostlen = #host -- 原始 host 字节长度（escaped 含转义 %，长度不同）
    local s = raw:find(needle, 1)
    while s do
        local c = raw:sub(s - 1, s - 1)
        local ok = true
        if c ~= "" and c:match("%w") then
            ok = false -- 前一个字符是字母/数字：xxxgithub.com
        elseif c == "." then
            if s >= 5 and raw:sub(s - 4, s - 2) == "www" then
                ok = true
            else
                ok = false
            end
        end
        if ok then
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

-- 带子路径的版本（Hugging Face / ModelScope：models|datasets|spaces）
local function match_host_sub_all(raw, host, allowed)
    local out = {}
    local escaped = host:gsub("%.", "%%.")
    local needle = escaped .. "/"
    local hostlen = #host
    local s = raw:find(needle, 1)
    while s do
        local c = raw:sub(s - 1, s - 1)
        local ok = true
        if c ~= "" and c:match("%w") then
            ok = false
        elseif c == "." then
            if s >= 5 and raw:sub(s - 4, s - 2) == "www" then
                ok = true
            else
                ok = false
            end
        end
        if ok then
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

-- 解析全部仓库链接 → 去重后的 entries 列表
-- entry: {kind, sub, owner, repo, url, key}
-- kind: "github" | "hf" | "ms"
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
    -- HF 模型链接可省略 models/ 前缀：huggingface.co/{owner}/{repo}
    -- 排除 api/、models|datasets|spaces（已被子路径版命中）、collections 页面
    for _, m in ipairs(match_host_all(raw, "huggingface.co")) do
        if m.owner ~= "api" and m.owner ~= "models" and m.owner ~= "datasets"
            and m.owner ~= "spaces" and m.repo ~= "collections" then
            add("hf", "models", m.owner, m.repo, "https://huggingface.co/" .. m.owner .. "/" .. m.repo)
        end
    end

    -- ModelScope 支持 cn / ai 两个域名
    for _, host in ipairs({ "modelscope.cn", "modelscope.ai" }) do
        for _, m in ipairs(match_host_sub_all(raw, host, { "models", "datasets" })) do
            add("ms", m.sub, m.owner, m.repo, "https://" .. host .. "/" .. m.sub .. "/" .. m.owner .. "/" .. m.repo)
        end
    end

    return entries
end

-- --------------------------------------------------------------------
-- 元数据 / README URL
-- --------------------------------------------------------------------
-- HF 镜像 host：国内部署 huggingface.co 常直连不通（DNS/连接黑洞，30s
-- 超时），hf-mirror.com 镜像 API 与 raw 均兼容；配置 hf_mirror 可切回直连。
local function hf_host()
    if cfg_bool("hf_mirror", true) then return "hf-mirror.com" end
    return "huggingface.co"
end

local function meta_api_url(e)
    if e.kind == "github" then
        return "https://api.github.com/repos/" .. e.owner .. "/" .. e.repo
    elseif e.kind == "hf" then
        return "https://" .. hf_host() .. "/api/" .. (e.sub or "models") .. "/" .. e.owner .. "/" .. e.repo
    elseif e.kind == "ms" then
        return "https://modelscope.cn/api/v1/" .. (e.sub or "models") .. "/" .. e.owner .. "/" .. e.repo
    end
end

-- GitHub API 请求头：配置 github_token 时带 Bearer 认证（限流 60→5000 次/小时，
-- 且可访问私有仓库）；留空走匿名免费层级（60 次/小时，按容器 IP）。
-- UA 与 API 版本头必带；仅用于 github 类请求，避免把 token 泄漏给 HF/MS。
local function gh_headers()
    local h = {
        ["User-Agent"] = "JuanNiang-Neo-repo-intro/1.0",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }
    local token = cfg_string("github_token", "")
    if token ~= "" then
        h["Authorization"] = "Bearer " .. token
    end
    return h
end

-- 返回下一步 README 的 (url, stage)；nil 表示直接进 LLM（数据集已内嵌 README）
local function readme_url_for(e)
    if e.kind == "github" then
        -- readme API 返回 base64 content（可直接解码）+ download_url；正确处理
        -- README 大小写/非标准命名。国内部署优先解码 content（与元数据同源
        -- api.github.com，可达），避免走 download_url 指向的 raw.githubusercontent.com
        return "https://api.github.com/repos/" .. e.owner .. "/" .. e.repo .. "/readme", "readme"
    elseif e.kind == "hf" then
        return "https://" .. hf_host() .. "/" .. e.owner .. "/" .. e.repo .. "/raw/main/README.md", "readme"
    elseif e.kind == "ms" then
        if e.sub == "datasets" and e.meta and e.meta.readme_content and e.meta.readme_content ~= "" then
            return nil, nil -- 数据集元数据已内嵌 ReadmeContent
        end
        return "https://modelscope.cn/api/v1/" .. (e.sub or "models") .. "/" .. e.owner .. "/" .. e.repo
            .. "/repo?Revision=master&FilePath=README.md", "readme"
    end
    return nil, nil
end

-- --------------------------------------------------------------------
-- 工具函数
-- --------------------------------------------------------------------
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

local function truncate(str)
    local max = cfg_num("max_readme_chars", 10000)
    if #str > max then return str:sub(1, max) end
    return str
end

-- --------------------------------------------------------------------
-- base64 解码（gopher-lua 无标准库；逐 4 字符解码，避免大数溢出）
-- --------------------------------------------------------------------
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_MAP = {}
for i = 1, #B64_CHARS do B64_MAP[B64_CHARS:sub(i, i)] = i - 1 end

-- 解码失败返回 nil（由调用方回退 download_url）；空输入返回 ""。
local function b64_decode(s)
    if not s or s == "" then return "" end
    s = s:gsub("%s", ""):gsub("=+$", "") -- GitHub content 按 60 字符换行并带 '=' 填充
    local acc = ""
    local out = {}
    local n = #s
    local i = 1
    -- gopher-lua 的 table.concat 会把表内全部元素（含分隔符）压栈，而插件栈
    -- 固定 5120；README 较大时单次 concat 会触发 registry overflow，因此每块
    -- 累计 FLUSH 条输出就 flush 一次，再拼进 acc（2*FLUSH 需远小于 5120）。
    local FLUSH = 1024
    while i <= n do
        local c1 = B64_MAP[s:sub(i, i)]; i = i + 1
        local c2 = B64_MAP[s:sub(i, i)]; i = i + 1
        if not c1 or not c2 then return nil end -- 含非 base64 字符
        local c3 = (i <= n) and B64_MAP[s:sub(i, i)] or nil
        if c3 then i = i + 1 end
        local c4 = (i <= n) and B64_MAP[s:sub(i, i)] or nil
        if c4 then i = i + 1 end
        out[#out + 1] = string.char(c1 * 4 + math.floor(c2 / 16))
        if c3 then
            out[#out + 1] = string.char((c2 % 16) * 16 + math.floor(c3 / 4))
            if c4 then
                out[#out + 1] = string.char((c3 % 4) * 64 + c4)
            end
        end
        if #out >= FLUSH then
            acc = acc .. table.concat(out)
            out = {}
        end
    end
    if #out > 0 then
        acc = acc .. table.concat(out)
    end
    return acc
end

-- --------------------------------------------------------------------
-- 附带文本提取：剥掉链接/URL，保留分享者随链接发来的说明文字
-- --------------------------------------------------------------------
-- 移除 markdown 链接 [text](url) 与裸 URL（含 t.co 短链），压缩空白。
-- 结果作为"附带文本"送 LLM（可能是推文/推荐语，也可能纯噪声，由 LLM 甄别）。
local function extract_context_text(raw)
    if not raw or raw == "" then return "" end
    local s = raw
    s = s:gsub("%[[^%]]*%]%(%s*[^%)]*%s*%)", " ") -- 剥掉 [text](url)
    s = s:gsub("https?://[^%s%)%]%>]+", " ")       -- 剥掉裸 URL
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- 附带文本是否值得送 LLM：太短视为残留噪声（仅链接/一两个字），上限 2000 字符。
local function context_text_for(raw)
    if not cfg_bool("use_context_text", true) then return "" end
    local t = extract_context_text(raw)
    if #t < 9 then return "" end -- 短于 3 个汉字视为纯语气/碎片回复，不送
    local max = 2000
    if #t > max then return t:sub(1, max) end
    return t
end

-- 解析元数据 JSON → 精简字段表
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
        return {
            name = data.id or (e.owner .. "/" .. e.repo),
            pipeline = data.pipeline_tag,
            library = data.library_name,
            downloads = data.downloads,
            likes = data.likes,
            params = data.safetensors and data.safetensors.total or nil,
            -- HF 头像在 avatar 阶段抓 org 页提取 cdn-avatars（og:image 是横幅大图，非头像），
            -- 这里不设静态头像；fetch 失败时模板灰圆兜底
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
            readme_content = d.ReadmeContent,
            avatar = (d.Avatar ~= nil and d.Avatar ~= "") and d.Avatar or nil,
        }
    end
end

-- 每仓库 LLM 结果缓存（值：JSON {type,title,summary,install,card_url}）
local function repo_cache_key(e)
    -- v2：README 改为直解 base64 + 附带文本 + 反套话规则，旧缓存摘要质量差，
    -- 升级 key 强制全部重建一次，避免 7 天 TTL 内继续命中旧的空话摘要。
    return "intro:v2:" .. e.key
end

local function repo_cache_get(e)
    local v = jn.cache.get(repo_cache_key(e))
    if type(v) ~= "table" then return nil end
    -- 缓存结构升级：旧版缓存无 desc_cn（GitHub 描述行中文依赖它）或无 card_url（卡片图），
    -- 视为未命中重建一次（写入新格式），避免旧缓存一直缺描述行/卡片
    if e.kind == "github" and v.desc_cn == nil then return nil end
    if cfg_bool("card_enabled", true) and v.card_url == nil then return nil end
    return v
end

local function repo_cache_set(e, content)
    if type(content) ~= "table" then return end
    jn.cache.set(repo_cache_key(e), content, cfg_num("cache_ttl", 604800))
end

-- --------------------------------------------------------------------
-- LLM 提示词（统一：GitHub / Hugging Face / ModelScope 同一提示词）
-- 内容由 8 个子智能体对 80+ 示例仓库逐仓抓取 README/元数据后校准
-- --------------------------------------------------------------------
local function llm_system_prompt()
    local min_c = tostring(cfg_num("summary_min_chars", 50))
    local max_c = tostring(cfg_num("summary_max_chars", 150))
    local p = [[你是中文仓库介绍助手。用户会给你若干仓库（GitHub / Hugging Face / ModelScope）的元数据与 README 内容，请对每个仓库独立判定类型、写出简体中文介绍，最后按指定 JSON 输出。

【零、通用铁律（所有仓库必做）】
1. 只写 README、元数据与【附带文本】中明确给出的内容，禁止编造参数量、分数、功能、许可证、安装命令、API 价格、Star 数；未写明的直接省略。
2. summary 一律简体中文，英文内容翻译；项目名、命令、API 名、模型名保留原文。
3. 每个仓库独立判断类型，禁止按组织/前缀归一类；同一组织不同仓库类型可能完全不同。
4. README 不一定是 README.md（可能是 README.org/.rst），别把"有文档"误判成"无文档"；多个仓库务必全部覆盖，不得遗漏。
5. desc_cn：仓库官方 description 的简体中文翻译（≤60 字），GitHub 仓库必填；无官方描述则填空字符串。
6. 【附带文本】是分享者随链接发来的消息片段（推文/推荐语等），不是仓库官方文档。仅当它确实描述了某个仓库的用途、功能、安装或使用方式时，才把它作为该仓库的补充信息并入 summary（例如补充了 README 没有的一句话定位或安装命令）；它与 README 冲突时以 README 为准。若是与仓库无关的闲聊、个人情绪、晒 Star、祝贺、转发语、感谢、广告等噪声，一律忽略，禁止写入任何字段；不要把某个仓库的附带文本安到别的仓库头上。
7. 严禁输出空话套话与"元信息旁白"，包括但不限于："推测与XX相关""具体内容/用途需查阅仓库代码与文档""具体功能详见仓库文档""未提供详细文档，待作者补充""当前元数据未包含功能描述，以仓库内容为准""仓库未提供进一步功能说明与文档""README 未说明""暂无描述""未说明/未给出/未提及"等。README 内容少或被截断时，也要从已有的标题、一句话描述、元数据里提炼可写的信息；实在没有，summary 输出空字符串（绝不硬凑），title 可只写仓库名。宁可少说，不可说废话。
8. 严禁大段罗列与流水账：任何清单——智能体、平台、设备、模型、技术栈、语言——**一律最多列 2 个，其余用"等"带过，宁少勿多**（如"支持 Claude Code 等主流编码 Agent"；"iOS 与 Web 端"而非"iOS/Android App、Web 与桌面端"）。禁止完整罗列（如 Claude Code、Codex、Cursor、Grok Build、OpenCode 全写出来）；安装/部署最多给一条最简命令（如 npx skills add owner/repo、npm install -g 包名），多平台（Windows/macOS/Arch）、Node 版本要求、完整 clone+install 步骤、配置文件路径、目录结构等细节一律省略或一句话带过；技术栈/语言最多提 1 个（如"React 编写"）或省略。summary 精炼，突出"是什么、能做什么、关键数字"，一般一两句话、不超过 __MAX__ 字。
9. summary 不得重复官方 description/desc_cn 已展示过的原文——描述行之外才写 summary，内容应是描述没有的实质信息（能力、用途、规模、一条最简安装命令）。
10. summary 中任何并列清单（智能体/平台/设备/模型/语言等）**具名项只允许 1~2 个**：写 2 个用"A、B 等"，写 1 个用"A 等"。3 个具名项即违规。判例："支持 Claude Code、Codex 等"✓；"Claude Code、Codex、Cursor 等"✗；"iOS、Android、Web 等端"✗；"iOS、Android 与 Web 端"✗（应写作"iOS 与 Web 端"）。安装/部署命令整条 summary 最多 1 条。跨平台/多端类仓库直接概括为"跨平台"或"iOS、Android 等主流端"（≤2），禁止点齐所有平台。

【一、GitHub 仓库类型判定与总结】
依次判定：先看是否第 1、2 类，都不是则归第 3 类。

1. MCP / Skills / Agent 插件类
证据（满足其一即倾向此类）：README 或描述含 "MCP"、"skill"、"plugin"、"插件"；README 给出面向 AI 编码工具/智能体的安装命令（如 npx skills add owner/repo、/plugin marketplace add owner/repo、/plugin install 插件名、dsh plugin add 插件名、把目录复制到 $DSH_HOME/skills/ 或 .agents/skills/）；结构含 skills/ 目录、SKILL.md、插件 manifest、MCP 配置；topics 含 claude-code、codex、agent-skills。核心特征：是"装进某个 Agent 直接用"的现成能力包，本身不是独立运行的程序。
summary 要点：产品定位一句话 + 核心能力 1~2 点 + 安装一条最简命令（如 npx skills add owner/repo、/plugin install 插件名、dsh plugin add 插件名、claude mcp add ... -- npx -y 包名；复制类一句"复制到 skills 目录"即可，不给完整路径步骤）。禁止罗列多平台/多步骤安装、禁止写"需安装"却无命令。

2. AI Agent 项目
证据：描述含 agent、智能体、自动化、workflow、一键生成、数字人、浏览器自动化；README 描述"输入→输出"流水线（如"输入主题即自动生成脚本、字幕、配乐并合成视频"）并给运行/部署说明（Docker、npm install、API Key、Web 界面）；topics 含 ai-agent、llm-agent、automation。核心特征：本身是可独立运行的程序/服务/工作流。
summary 要点：先讲"把什么变成什么"（输入→输出），再讲核心能力与亮点（概括，不逐个枚举功能），部署/使用一句话（如"Docker 一键部署"、"npm install 后填 API Key"）。禁止罗列多平台部署步骤。

3. 其他类
其余全部：SDK/库与框架、API 网关/代理（把某模型封装成 OpenAI 兼容接口）、Web 应用（AI 简历编辑器、聊天前端）、数据集、论文/研究实现、学习资源（教程、awesome 精选列表）、实用小工具、整活、个人/组织主页、开源模型仓库。
summary 要点（按子类型，均遵守零.8 反罗列、精炼）：SDK/库：是什么、支持什么模型/硬件、怎么装怎么调；API 网关：封装什么成什么接口、多账号/多模型、部署；Web 应用：定位、特性、部署或在线地址；数据集：规模、内容、标注、引用；论文/研究实现：论文名、方法、代码/权重地址；学习资源/awesome：范围、数量、亮点；实用工具：解决什么问题、怎么用；整活：一句话说明玩法。

模型仓库（GitHub 上发布权重的仓库）归第 3 类，但必须写：模型定位与能力（如"手机端可运行的图文理解模型"）；参数量/权重规格（如 0.1B、4B，或"1 分钟音频即可训练"）；部署方式（HuggingFace 权重下载、本地/手机运行、在线 Demo、Colab 训练）；有论文或基准可补一句。

【二、Hugging Face / ModelScope 模型类型判定与总结】
依次检查 pipeline_tag 与 README frontmatter 的 pipeline_tag/tasks 字段、tags 列表、仓库路由与名字特征：
- text-generation / conversational → 文本对话·推理；若名字含 R1、Reasoning、Thinking 或 README 提到思维链、推理模式，类别标注"推理增强"
- image-text-to-text → 多模态 VLM；若 tags/README 含 ocr、document-parse、layout、table、formula 或库名含 ocr → OCR·文档理解（OCR 是生成式模型，输出文字，不是检测框，不可归 object-detection）
- any-to-any 或 README 写明 Omni、支持音频输入输出 → Omni 全模态；仅文本+图像/视频输入而无音频 → 多模态，勿误标 Omni（如 MiniMax-M3 支持图与视频但不含音频）
- tags 含 robotics 或名字含 Robot、VLA、Embodied、World Model → 机器人·具身，即使 pipeline 是 any-to-any 或 tags 含 image-generation（如 Xiaomi-Robotics-U0）也不是文生图模型
- sentence-similarity / feature-extraction → 嵌入；text-reranking / cross-encoder / 库名含 reranker → 重排序，二者是两类，勿混
- text-to-image 或 tags 含 image-generation（无 robotics）或名字含 Image、T2I → 图像生成
- text-to-video / video-generation / 名字含 T2V、Video、CogVideo → 视频生成
- text-to-speech / tts / voice-cloning / 名字含 CosyVoice、TTS → TTS；automatic-speech-recognition / Whisper / SenseVoice → ASR
- 路由 /datasets/ 或 MS 数据集接口 → 数据集；/spaces/ 或 studios → Space 应用（看 sdk：gradio/streamlit 判断功能）
- 名字后缀 -Instruct/-Chat/-Base 是变体：指令微调/对话/基座，总结中注明
易错点：能看图≠能生图；名字日期后缀（0813、2512）是版本快照不是参数量；A3B/A14B 是 MoE 激活参；FP8/BF16/FP4 是精度；Turbo/Flash/Pro 是系列变体（Turbo 常为蒸馏加速版）；MS 元数据 Pipeline/Task 常为 null、Tags 常为空，必须读 README frontmatter 才能定类型。

文本对话/推理模型总结重点：架构（MoE 稀疏或稠密）、上下文长度、参数（MoE 必写"总参 X / 激活 Y"，如"总参 428B / 激活 23B"；稠密直接给）、精度（FP8/BF16/FP4）、多模态支持（纯文本或可视觉输入，写清输入模态）、专长（只写 README 明确的 benchmark 类别：长文本推理、agent、编码、数学推理、中文等）、工具调用/函数调用、许可协议、部署（vLLM/transformers/Ollama）。

其他模型类别要点：
- 多模态：输入模态（图像/视频/音频）、图像分辨率、视频理解与 OCR 能力、参数量、上下文长度
- 图像生成：文生/图生、分辨率（1K/2K/4K）、架构（DiT/扩散）、是否加速版（Turbo）、library（diffusers/ComfyUI）
- 视频生成：文生/图生视频、时长与分辨率、帧率、是否 MoE、是否单文件
- TTS：是否 zero-shot 克隆、语种、情感与语速控制、参数量、采样率与输出格式、推理 VRAM
- ASR：语种、是否流式、词错误率
- 嵌入：维度、最大长度、语言数、稠密/稀疏/多向量混合检索、MTEB、用途（RAG）
- 重排序：cross-encoder/LLM reranker、输入输出形式
- OCR·文档理解：语言、版面/表格/公式能力、是否端到端
- 机器人·具身：VLA/世界模型、输入输出模态、参数量
- Omni：输入输出模态、是否流式语音、语种数、实时交互
- 数据集：规模、语言、领域、任务类型
- Space：SDK、功能、能否在线使用

【三、输出格式】严格只输出如下 JSON（不要输出 JSON 以外的任何内容，不要用代码块包裹）：
{"repos":[{"index":1,"type":"类型中文名","title":"一句话标题（简体中文，≤30字，无信息时可用仓库名，禁止套话）","summary":"精炼介绍（简体中文，通常 __MIN__~__MAX__字；内容充分时写足、内容稀少时写短或留空；突出是什么、能做什么、关键数字；严禁空话套话旁白与罗列；不得重复 desc_cn）","desc_cn":"官方描述中文翻译（GitHub 必填，无则空字符串）"}]}
index 与输入仓库编号一一对应（从 1 开始）。]]
    return p:gsub("__MIN__", min_c):gsub("__MAX__", max_c)
end

-- 组装单仓库送 LLM 的用户输入
local function repo_input_for_llm(e, idx)
    local m = e.meta or {}
    local t = { index = idx, platform = platform_label(e), url = e.url }
    if e.kind == "github" then
        t.name = m.name; t.description = m.desc; t.language = m.lang
        t.stars = m.stars; t.forks = m.forks; t.topics = m.topics
    elseif e.kind == "hf" then
        t.name = m.name; t.pipeline = m.pipeline; t.library = m.library
        t.downloads = m.downloads; t.likes = m.likes; t.params = m.params
    elseif e.kind == "ms" then
        t.name = m.name; t.description = m.desc; t.chinese_name = m.chinese_name
        t.downloads = m.downloads; t.likes = m.likes
    end
    local s = "【仓库 " .. idx .. "】" .. jn.json.encode(t)
    if e.readme and e.readme ~= "" then
        s = s .. "\nREADME 内容（" .. e.owner .. "/" .. e.repo .. "）：\n" .. e.readme
    end
    return s
end

-- 模型信息库（modeldb.json）：参数量 / 上下文 / 输入类型 / 定价
-- 由 data/rebuild-modeldb.py 从 llmrates + models.dev + newapiratio + openrouter 生成
-- --------------------------------------------------------------------
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

-- 按 HF/MS 模型 id 渐进查找（精确别名 → 补/去常见后缀）
local function modeldb_find(hf_id)
    local db = modeldb_load()
    if not db or not db.alias then return nil end
    local nk = norm_key(hf_id)
    local key = db.alias[nk]
    if not key then
        local suffixes = { "instruct", "chat", "base", "it", "latest", "free", "v1", "v2", "v3" }
        for _, sfx in ipairs(suffixes) do
            local k2 = db.alias[nk .. sfx]
            if k2 then key = k2 break end
            if nk:sub(-#sfx) == sfx then
                k2 = db.alias[nk:sub(1, -#sfx - 1)]
                if k2 then key = k2 break end
            end
        end
    end
    if not key or not db.models then return nil end
    return db.models[key]
end

-- 参数量：HF meta safetensors.total(字节) 优先，modeldb 兜底，否则 闭源
local function fmt_params_bytes(n)
    n = tonumber(n)
    if not n or n <= 0 then return nil end
    local b = n / 1e9
    if b >= 1000 then
        return (string.format("%.1f", b / 1000):gsub("%.?0+$", "")) .. "T"
    end
    if b >= 10 then return string.format("%.0fB", b) end
    return (string.format("%.1f", b):gsub("%.?0+$", "")) .. "B"
end

local function model_params(e, mi)
    local total = nil
    local p = e.meta and e.meta.params
    if p and tonumber(p) then
        total = fmt_params_bytes(p)
    end
    if not total then
        local mp = mi and mi.params
        if mp and mp ~= "" then
            -- 护栏：模型库异常大值（>10T）视为数据污染，按缺失处理（HF meta 更可靠）
            local num = tonumber(mp:match("^([%d%.]+)"))
            if not (mp:match("T$") and num and num > 10) then
                total = tostring(mp)
            end
        end
    end
    if not total then return "闭源" end
    -- 激活参数（MoE）：从模型名/repo 提取 A\d+B，如 Hunyuan-A13B / 122B-A10B / 30B-A3B
    local name = (e.meta and e.meta.name) or (e.owner .. "/" .. e.repo)
    local act = name:match("A(%d+%.?%d*)B")
    if act then
        local a = act:gsub("%.0+$", "") -- 仅剥小数尾零，保留整数尾零（10→10，10.0→10）
        if a == "" then a = act end
        return total .. "(A" .. a .. "B)"
    end
    return total
end

-- 上下文：1M / 256k / 32k（1024 取整，贴合厂商口径 32k/128k/256k）
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

-- 输入类型 icons
local MOD_ICONS = {
    text   = { '<svg class="ico" viewBox="0 0 16 16"><path d="M2 1h7l4 4v10H2V1zm2 2v2h5V3H4zm0 4v1h8V7H4zm0 3v1h8v-1H4z"/></svg>', "文本" },
    image  = { '<svg class="ico" viewBox="0 0 16 16"><path d="M2 2h12v12H2V2zm1 1v6l3-3 2 2 2-2 3 3V3H3zm2 2a1 1 0 1 0 0-2 1 1 0 0 0 0 2z"/></svg>', "图片" },
    audio  = { '<svg class="ico" viewBox="0 0 16 16"><path d="M11 1.5v9a2.5 2.5 0 1 1-1-2.03V5.1L5 6.3v6.2a2.5 2.5 0 1 1-1-2.03V5.1L11 1.5z"/></svg>', "音频" },
    video  = { '<svg class="ico" viewBox="0 0 16 16"><path d="M0 3h16v10H0V3zm2 2v6h12V5H2zm3 1.5v3L9 8 5 6.5z"/></svg>', "视频" },
    pdf    = { '<svg class="ico" viewBox="0 0 16 16"><path d="M2 1h8l4 4v10H2V1zm4 3v1h4V4H6zm0 3v1h6V7H6zm0 3v1h6v-1H6z"/></svg>', "PDF" },
    tool   = { '<svg class="ico" viewBox="0 0 16 16"><path d="M7 1h2v3h3v2H9v3H7V6H4V4h3V1zM4 9h2v2H4V9zm8 0h2v2h-2V9zm-8 4h2v2H4v-2zm8 0h2v2h-2v-2z"/></svg>', "工具" },
}
local function model_modality_html(e, mi)
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

-- 价格块：币种(国产¥/国外$)、输入/输出/思考/缓存、闲时、上下文分段
-- 国产模型判定：modeldb cn 标记 / provider_local / 厂商名启发式
local CN_PROVIDERS = { deepseek=true, qwen=true, alibaba=true, zhipu=true, chatglm=true, glm=true,
    kimi=true, moonshot=true, doubao=true, volc=true, volcengine=true, baidu=true, hunyuan=true,
    tencent=true, minimax=true, bytedance=true, iflytek=true, xfyun=true, stepfun=true, ernie=true,
    spark=true, ["01ai"]=true, minimaxai=true }
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
    if #pr == 0 then return "" end
    local cn = is_cn_model(e, mi)
    local sym, cur = "¥", "CNY"
    if not cn then sym, cur = "$", "USD" end
    -- 国产模型但库内无 CNY 档：把 USD 档按 7.2 汇率换算成 CNY 展示
    local USD_RATE = 7.2
    local function conv(v)
        if not v then return nil end
        return math.floor(v * USD_RATE * 100 + 0.5) / 100
    end
    local std, off, tiers = {}, {}, {}
    local function collect(p)
        if p.cur == cur then
            if p.tier == "off_peak" then
                off[#off + 1] = p
            elseif (p.min ~= nil and p.min ~= 0) or p.max ~= nil then
                tiers[#tiers + 1] = p
            else
                std[#std + 1] = p
            end
        end
    end
    for _, p in ipairs(pr) do
        collect(p)
    end
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
    -- 有上下文分段时只用分段（flat 标准行会与分段重复）
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
            if cc then
                kv[#kv + 1] = '缓存 <b>' .. sym .. cc .. '</b>'
            end
            if #kv > 0 then
                rows[#rows + 1] = '<div class="price-row">' .. table.concat(kv, ' · ') .. '</div>'
            end
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
        local tkv = {}
        local seen = {}
        for _, t in ipairs(tiers) do
            local ii, oo = fmt_price(t.input), fmt_price(t.output)
            if ii and oo then
                -- 开区间（max 缺失）显示 >min ctx；有界显示 ≤max ctx
                local rng
                if t.max == nil or t.max == 0 then
                    rng = '>' .. fmt_context(t.min) .. ' ctx'
                else
                    rng = '≤' .. fmt_context(t.max) .. ' ctx'
                end
                -- 去重：同价格只留第一个分段（避免 ≤256k 与 >128k 同价重复展示）
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

-- 组装 HF/MS 模型卡片 HTML（复用 card-6.html 占位符）
local GRAY_AVATAR = "data:image/svg+xml;charset=utf-8,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='140'%20height='140'%3E%3Ccircle%20cx='70'%20cy='70'%20r='70'%20fill='%23d0d7de'/%3E%3C/svg%3E"
local function fill_model_template(tpl, e)
    local m = e.meta or {}
    local mi = modeldb_find(m.name or (e.owner .. "/" .. e.repo))
    local data = {
        OWNER = e.owner,
        REPO = e.repo,
        -- HF：org 页提取的组织头像 cdn-avatars 走 wsrv.nl 代理（t2i 无法直连 HF CDN）
        -- MS：直连 resouces.modelscope.cn
        AVATAR = (e.kind == "hf" and m.avatar_src ~= nil and m.avatar_src ~= "")
            and ("https://wsrv.nl/?url=" .. m.avatar_src .. "&w=280&h=280&fit=cover")
            or ((m.avatar ~= nil and m.avatar ~= "") and m.avatar or GRAY_AVATAR),
        PARAMS_CHIP = '<span class="chip"><span class="lbl">参数量</span><span class="val">'
            .. model_params(e, mi) .. '</span></span>',
        CONTEXT_CHIP = '<span class="chip"><span class="lbl">上下文</span><span class="val">'
            .. fmt_context(mi and mi.ctx) .. '</span></span>',
        MODALITY_HTML = model_modality_html(e, mi),
        PRICING_HTML = model_pricing_html(e, mi),
    }
    local out = tpl
    for k, v in pairs(data) do
        out = out:gsub("{{" .. k .. "}}", function() return tostring(v) end)
    end
    return out
end

-- 仓库卡片图（T2I：HTML 模板渲染，模板在 templates/ 目录，占位符 {{KEY}}）
-- --------------------------------------------------------------------
-- T2I 回调上下文表：req_id → batch（on_t2i_response 回调不带 batch）。
-- 注意：必须在 start_cards 之前声明（local 词法作用域），否则闭包引用全局 nil
local card_ctx_batch_tbl = {}
local function card_ctx_batch(req_id)
    local b = card_ctx_batch_tbl[req_id]
    card_ctx_batch_tbl[req_id] = nil
    return b
end

-- 前向声明：finish_cards（卡片段）调用发送段末尾定义的 compose_and_send
local compose_and_send

-- 加载模板；prefer 指定编号时直接读该模板（HF/MS 模型卡固定用 card-6），
-- 否则读配置 card_template（可为 random）。
local function load_template(prefer)
    local n = prefer or cfg_string("card_template", "5")
    local tpl, err
    if not prefer and n == "random" then
        n = tostring(math.random(1, 5)) -- 每次渲染随机选一个
        tpl = jn.file.read("templates/card-" .. n .. ".html")
        if tpl then return tpl end -- 随机命中即用，不再重复读取
        n = "5" -- 随机到的模板不存在时回退默认
    end
    tpl, err = jn.file.read("templates/card-" .. n .. ".html")
    if not tpl then
        jn.log.warn("[repo-intro] 卡片模板读取失败 templates/card-" .. n .. ".html err=" .. tostring(err))
        return nil
    end
    return tpl
end

-- 数字格式化：≥1000 → k（与原版 hello_github_card 一致）
local function fmt_count(n)
    n = tonumber(n)
    if not n or n < 0 then return "0" end
    if n >= 1000 then
        local k = n / 1000
        if k >= 10 then
            return string.format("%.0fk", k)
        end
        return string.format("%.1fk", k)
    end
    return tostring(n)
end

-- 填充模板：GitHub 用 card-N（STARS/FORKS/ISSUES/LANG_NAME），HF/MS 走模型卡（card-6）
local function fill_template(tpl, e)
    if e.kind ~= "github" then
        return fill_model_template(tpl, e)
    end
    local m = e.meta or {}
    local llm = e.llm or {}
    local desc = (llm.desc_cn ~= nil and llm.desc_cn ~= "") and llm.desc_cn
        or (llm.desc ~= nil and llm.desc ~= "") and llm.desc
        or (m.desc or "")
    local data = {
        OWNER = e.owner,
        REPO = e.repo,
        DESC = desc,
        URL = e.url or "",
        STARS = fmt_count(m.stars),
        FORKS = fmt_count(m.forks),
        ISSUES = fmt_count(m.issues),
        LANG_NAME = (m.lang and m.lang ~= "") and m.lang or "Other",
        -- MS/HF 元数据无头像字段；空 src 会让 Chromium 在 file:// 页面请求文档自身，
        -- 渲染服务行为不可控。用 data URI 灰圆占位（与模板灰圆底色一致），避免任何资源请求。
        AVATAR = (m.avatar ~= nil and m.avatar ~= "") and m.avatar
            or "data:image/svg+xml;charset=utf-8,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='140'%20height='140'%3E%3Ccircle%20cx='70'%20cy='70'%20r='70'%20fill='%23d0d7de'/%3E%3C/svg%3E",
    }
    local out = tpl
    for k, v in pairs(data) do
        -- 替换函数而非字符串：值含 % 时不会被当作替换模式（gsub 的替换串中 % 有特殊含义）
        out = out:gsub("{{" .. k .. "}}", function() return tostring(v) end)
    end
    return out
end

-- 卡片渲染完成后：写缓存（含 card_url）并发送
local function finish_cards(batch)
    for idx, ct in pairs(batch.pending_content or {}) do
        local e = batch.llm_usable and batch.llm_usable[idx]
        if e then
            ct.card_url = e.card_url or ""
            repo_cache_set(e, ct)
        end
    end
    compose_and_send(batch)
end

-- 触发卡片渲染（每仓库一张；全部完成后 finish_cards）
local function start_cards(batch)
    local usable = batch.llm_usable or {}
    -- 批次全为 HF/MS 时用 card-6 做启用判定（card-5 可能未随附）；否则用配置模板
    local all_model = #usable > 0
    for _, e in ipairs(usable) do
        if e.kind == "github" then all_model = false break end
    end
    local tpl = all_model and load_template("6") or load_template()
    local enabled = cfg_bool("card_enabled", true)
        and tpl ~= nil and jn.t2i ~= nil and jn.t2i.is_active() and jn.t2i.generate_url_async ~= nil
    if not enabled then
        finish_cards(batch)
        return
    end
    local pending = 0
    for idx, e in ipairs(usable) do
        -- 非模型的 HF/MS 仓库（数据集/Space 等路由）不渲染卡片图，只发文本
        if e.kind ~= "github" and e.sub ~= "models" then
            e.card_url = ""
        elseif not e.card_url or e.card_url == "" then
            -- HF/MS 模型卡固定用 card-6，GitHub 用配置模板
            local etpl = tpl
            if e.kind ~= "github" then
                etpl = load_template("6") or tpl
            end
            local html = fill_template(etpl, e)
            pending = pending + 1
            -- 注意：不传 timeout。SDK 文档约定单位为秒，但 Go SDK 原样透传、
            -- T2I 服务端按 Playwright 毫秒处理，传 60 会被当成 60ms，渲染必失败（500）。
            -- 不传则服务端用默认 30s，本地 file:// 渲染绰绰有余。
            local rid = jn.t2i.generate_url_async(html, {
                viewport_width = cfg_num("card_width", 900),
                viewport_height = cfg_num("card_height", 450),
            }, { idx = idx })
            if not rid or rid == 0 then
                pending = pending - 1
                e.card_url = nil
            else
                card_ctx_batch_tbl[rid] = batch
            end
        end
    end
    batch.card_pending = pending
    if pending == 0 then
        finish_cards(batch)
    end
end

-- T2I 异步回调（引擎级异步注册表 kind "t2i"）
function on_t2i_response(req_id, ctx, result, err)
    local batch = card_ctx_batch(req_id)
    if not batch then return end
    local idx = ctx and ctx.idx
    local e = batch.llm_usable and idx and batch.llm_usable[idx]
    if err or not result or result == "" then
        jn.log.warn("[repo-intro] 卡片渲染失败 idx=" .. tostring(idx) .. " err=" .. tostring(err))
        if e then e.card_url = nil end
    elseif e then
        e.card_url = result
    end
    if batch.card_pending then
        batch.card_pending = batch.card_pending - 1
        if batch.card_pending <= 0 then
            finish_cards(batch)
        end
    end
end

-- --------------------------------------------------------------------
-- 发送 / 组装
-- --------------------------------------------------------------------
-- 组装单仓库段
local function compose_section(e)
    local lines = {}
    local name = (e.meta and e.meta.name) or (e.owner .. "/" .. e.repo)
    lines[#lines + 1] = "📦 " .. name .. WATERMARK -- 标题尾部加水印（零宽不可见）

    local llm = e.llm
    -- GitHub：模型名：官方描述（desc_cn 中文优先）；无官方描述时用 LLM 一句话标题。
    -- HF/MS：仅 LLM 一句话标题。统一以 📝 前缀展示。
    local desc_line = nil
    if e.kind == "github" then
        local desc = (llm and llm.desc_cn) or (llm and llm.desc) or (e.meta and e.meta.desc)
        if desc and desc ~= "" then
            desc_line = e.repo .. "：" .. desc
        elseif llm and llm.title and llm.title ~= "" then
            desc_line = llm.title
        end
    elseif llm and llm.title and llm.title ~= "" then
        desc_line = llm.title
    end
    if desc_line then
        lines[#lines + 1] = "📝 " .. desc_line
    end
    local summary = llm and llm.summary or (e.meta and e.meta.desc) or ""
    if summary ~= "" then
        lines[#lines + 1] = summary
    end
    lines[#lines + 1] = e.url or ""
    return table.concat(lines, "\n")
end

-- 组装整条消息的 segment 数组：每仓库一段文本 + 卡片图（🔗 后）。
-- 失败条目（无 LLM 结果且有错误）直接跳过，全部失败时返回 nil 不发送（静默）
local function compose_segments(batch)
    local segs = {}
    local send_card = cfg_bool("card_enabled", true)
    local first = true
    for _, e in ipairs(batch.entries) do
        if not e.skipped and (e.llm or not e.err) then
            local text = compose_section(e)
            if not first then
                text = "\n\n" .. text -- 段间空两行（QQ 多 segment 拼接显示）
            end
            first = false
            segs[#segs + 1] = { type = "text", data = { text = text } }
            if send_card and e.card_url and e.card_url ~= "" then
                segs[#segs + 1] = { type = "image", data = { file = e.card_url } }
            end
        end
    end
    if #segs == 0 then return nil end
    return segs
end

-- 发送（reply 引用 + segments）；segments 为空（全部失败）静默不发送
local function send_intro(batch, segments)
    if not segments or #segments == 0 then return end
    local t = batch.target
    if t.reply_quote and t.message_id ~= nil and tostring(t.message_id) ~= "" then
        table.insert(segments, 1, { type = "reply", data = { id = tostring(t.message_id) } })
    end
    if t.message_type == "group" then
        jn.onebot11.send_group_msg(t.target_id, segments)
    else
        jn.onebot11.send_private_msg(t.target_id, segments)
    end
end

-- 流水线终点：发送 + 清理本批次设置的在途去重标记
compose_and_send = function(batch)
    for _, e in ipairs(batch.entries) do
        if e.owned_dedup then
            jn.cache.del("dedup:" .. e.key)
        end
    end
    local segments = compose_segments(batch)
    if segments then
        send_intro(batch, segments)
    end
end

-- --------------------------------------------------------------------
-- 异步流水线
-- --------------------------------------------------------------------

-- LLM 上下文表：req_id → batch（llm.chat_async 回调不带 ctx）
local llm_ctx = {}

-- 全部元数据/README 就绪 → 单次 LLM 调用（防重复触发）
local function start_llm(batch)
    if batch.llm_started then return end
    batch.llm_started = true
    -- 汇总未命中缓存且元数据可用的仓库
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
        parts[#parts + 1] = repo_input_for_llm(e, idx)
    end
    local messages = {
        { role = "system", content = llm_system_prompt() },
        { role = "user", content = table.concat(parts, "\n\n") },
    }
    -- 附带文本（分享者消息中除链接外的说明，可能是推文/推荐语，也可能是噪声）：
    -- 一并送 LLM 作为补充信息，由提示词规则甄别是否采用。
    if batch.context_text and batch.context_text ~= "" then
        messages[2].content = messages[2].content
            .. "\n\n【附带文本（分享者随链接发来的消息，非仓库官方文档，与仓库无关的噪声请忽略）】\n"
            .. batch.context_text
    end
    batch.llm_messages = messages -- 失败重试复用
    local rid = jn.llm.chat_async(messages, { timeout = cfg_num("llm_timeout", 60) })
    if not rid or rid == 0 then
        jn.log.warn("[repo-intro] llm.chat_async 提交失败，降级为无摘要发送")
        compose_and_send(batch)
        return
    end
    batch.llm_usable = usable
    llm_ctx[rid] = batch
end

-- 所有仓库元数据/README 处理完毕时的检查点
local function check_batch(batch)
    if batch.pending <= 0 then
        start_llm(batch)
    end
end

-- meta 阶段（网络错误/超时重试一次——容器出口对高频请求偶发瞬时挂起）
local function handle_meta(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    local status = result and result.status or 0
    if err then
        local attempt = (ctx.fetch_attempt or 0) + 1
        if attempt <= 1 then
            local c = copy_ctx(ctx)
            c.fetch_attempt = attempt
            local rid = jn.http.get_async(meta_api_url(e), c, e.kind == "github" and gh_headers() or nil)
            if rid and rid ~= 0 then return end -- 重试已提交，等待回调
        end
        e.err = "请求失败：" .. tostring(err)
        jn.log.warn("[repo-intro] 仓库元数据获取失败 url=" .. (e.url or "") .. " err=" .. tostring(err))
        batch.pending = batch.pending - 1
        return
    end
    if status == 403 or status == 429 then
        -- GitHub API 未认证限流 60 次/小时（按容器 IP）；区分于仓库不存在
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

    local url, stage = readme_url_for(e)
    if not url then
        batch.pending = batch.pending - 1 -- 无需 README（如数据集内嵌）
        return
    end
    local c = copy_ctx(ctx)
    c.stage = stage
    local rid = jn.http.get_async(url, c, e.kind == "github" and gh_headers() or nil)
    if not rid or rid == 0 then
        batch.pending = batch.pending - 1 -- README 拉取失败，仍继续
    end
    -- HF 组织头像：抓 org 页提取 cdn-avatars（og:image 是横幅大图，非头像）
    if e.kind == "hf" then
        batch.pending = batch.pending + 1
        local ca = copy_ctx(ctx)
        ca.stage = "avatar"
        local rid2 = jn.http.get_async("https://" .. hf_host() .. "/" .. e.owner, ca)
        if not rid2 or rid2 == 0 then
            batch.pending = batch.pending - 1
        end
    end
end

-- readme 阶段
local function handle_readme(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    if e.kind == "github" then
        if err or not result or result.status < 200 or result.status >= 300 then
            batch.pending = batch.pending - 1 -- 无 README
            return
        end
        local data = jn.json.decode(result.body or "")
        if type(data) ~= "table" then
            batch.pending = batch.pending - 1
            return
        end
        -- readme API 自带 base64 content，与元数据同源（api.github.com，国内可达）；
        -- 优先解码直接得到 README，避免下载 download_url 指向的 raw.githubusercontent.com
        -- （国内常被墙/超时，导致 README 缺失、LLM 只能写"无 README/详见文档"套话）。
        local decoded = b64_decode(data.content)
        if decoded and decoded ~= "" then
            e.readme = truncate(decoded)
            batch.pending = batch.pending - 1
            return
        end
        -- content 缺失/解码失败：回退 download_url 拉取原文
        if not data.download_url then
            batch.pending = batch.pending - 1
            return
        end
        local c = copy_ctx(ctx)
        c.stage = "readme_raw"
        local rid = jn.http.get_async(data.download_url, c, e.kind == "github" and gh_headers() or nil)
        if not rid or rid == 0 then batch.pending = batch.pending - 1 end
        return
    end

    -- HF：main 404 则重试 master 分支
    if e.kind == "hf" then
        if not err and result and result.status == 200 and result.body and result.body ~= "" then
            e.readme = truncate(result.body)
            batch.pending = batch.pending - 1
            return
        end
        local attempt = (ctx.readme_attempt or 0) + 1
        -- 初始 main 失败后仅重试一次 master（老仓库默认分支），不重复 main
        if attempt <= 1 then
            local rev = "master"
            local c = copy_ctx(ctx)
            c.stage = "readme"
            c.readme_attempt = attempt
            local url = "https://" .. hf_host() .. "/" .. e.owner .. "/" .. e.repo .. "/raw/" .. rev .. "/README.md"
            local rid = jn.http.get_async(url, c)
            if not rid or rid == 0 then batch.pending = batch.pending - 1 end
            return
        end
        batch.pending = batch.pending - 1
        return
    end

    -- MS：成功则取内容
    if not err and result and result.status == 200 and result.body and result.body ~= "" then
        e.readme = truncate(result.body)
    end
    batch.pending = batch.pending - 1
end

-- avatar 阶段（HF org 页提取组织头像 cdn-avatars URL）
local function handle_avatar(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    if not err and result and result.status == 200 and result.body and e.meta then
        local src = result.body:match("https://cdn%-avatars%.huggingface%.co/v1/production/uploads/[%w%-%._/]+")
        if src then
            e.meta.avatar_src = src
        end
    end
    batch.pending = batch.pending - 1
end

-- readme_raw 阶段（github download_url 内容）
local function handle_readme_raw(ctx, result, err)
    local batch = ctx.batch
    local e = batch.entries[ctx.idx]
    if not err and result and result.status == 200 and result.body and result.body ~= "" then
        e.readme = truncate(result.body)
    end
    batch.pending = batch.pending - 1
end

-- HTTP 异步回调（引擎级异步注册表 kind "http"）
function on_http_response(req_id, ctx, result, err)
    if not ctx or not ctx.batch or not ctx.stage then return end
    if ctx.stage == "meta" then
        handle_meta(ctx, result, err)
    elseif ctx.stage == "readme" then
        handle_readme(ctx, result, err)
    elseif ctx.stage == "readme_raw" then
        handle_readme_raw(ctx, result, err)
    elseif ctx.stage == "avatar" then
        handle_avatar(ctx, result, err)
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
        -- Provider 瞬时失败（如网关 connection reset）重试最多 2 次
        local tries = (batch.llm_retries or 0) + 1
        if tries <= 2 and batch.llm_messages then
            batch.llm_retries = tries
            local rid = jn.llm.chat_async(batch.llm_messages, { timeout = cfg_num("llm_timeout", 60) })
            if rid and rid ~= 0 then
                jn.log.warn("[repo-intro] LLM 失败重试(" .. tries .. "/2): " .. tostring(err))
                llm_ctx[rid] = batch
                return
            end
        end
        jn.log.warn("[repo-intro] LLM 总结失败: " .. tostring(err))
        compose_and_send(batch)
        return
    end

    local cleaned = (content or ""):gsub("```[%w]*\n?", ""):gsub("```", "")
    local parsed = jn.json.decode(cleaned)
    local results = {}
    if type(parsed) == "table" and type(parsed.repos) == "table" then
        results = parsed.repos
    end

    -- 按 index 回填到对应的未缓存仓库
    local used = {}
    local pending_content = batch.pending_content or {}
    for _, r in ipairs(results) do
        if type(r) == "table" and r.index then
            local e = usable[tonumber(r.index)]
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
                pending_content[tonumber(r.index)] = content_tbl
                used[tonumber(r.index)] = true
            end
        end
    end
    -- 未回填的仓库：仅用元数据简介
    for idx, e in ipairs(usable) do
        if not used[idx] then
            e.llm = nil
        end
    end

    batch.pending_content = pending_content
    start_cards(batch) -- 渲染卡片（若启用）→ 写缓存（含 card_url）→ 发送
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
                    e.skipped = true -- 正在被其他消息处理，跳过
                else
                    jn.cache.set("dedup:" .. e.key, os.time(), 60)
                    e.owned_dedup = true -- 本批次自己设置的去重标记，完成后只清自己的
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
    -- 机器人自己的消息不处理（防止自触发生成包含链接的介绍造成循环）
    if is_self(event) then return false, false end
    local raw = event.raw_message or ""
    -- 命令不处理
    if raw:sub(1, 1) == "/" then return false, false end
    -- 识别到本机水印（他人转发本机输出）→ 忽略，避免二次总结
    if raw:find(WATERMARK, 1, true) then return true, false end
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
        compose_and_send(batch) -- 全部来自缓存/在途
        return true, false
    end

    for _, i in ipairs(uncached) do
        local ctx = { batch = batch, idx = i, stage = "meta" }
        local rid = jn.http.get_async(meta_api_url(batch.entries[i]), ctx, batch.entries[i].kind == "github" and gh_headers() or nil)
        if not rid or rid == 0 then
            batch.entries[i].err = "请求提交失败"
            batch.pending = batch.pending - 1
        end
    end
    if batch.pending <= 0 and not batch.llm_started then
        compose_and_send(batch) -- 全部提交失败
        return true, false
    end
    jn.log.info("[repo-intro] 批量处理 " .. #uncached .. " 个仓库链接")
    return true, false -- 消费：不进 Agent
end

jn.log.info("[repo-intro] 仓库介绍插件已加载")


