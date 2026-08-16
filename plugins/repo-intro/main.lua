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

-- 返回下一步 README 的 (url, stage)；nil 表示直接进 LLM（数据集已内嵌 README）
local function readme_url_for(e)
    if e.kind == "github" then
        -- readme API 返回 download_url，正确处理 README 大小写/非标准命名
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

local function platform_label(e)
    if e.kind == "github" then return "GitHub" end
    if e.kind == "hf" then
        local sub = e.sub or "models"
        return "Hugging Face · " .. ({ models = "模型", datasets = "数据集", spaces = "Space" })[sub]
    end
    return "ModelScope · " .. (e.sub == "datasets" and "数据集" or "模型")
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
            topics = data.topics,
        }
    elseif e.kind == "hf" then
        return {
            name = data.id or (e.owner .. "/" .. e.repo),
            pipeline = data.pipeline_tag,
            library = data.library_name,
            downloads = data.downloads,
            likes = data.likes,
            params = data.safetensors and data.safetensors.total or nil,
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
        }
    end
end

-- 每仓库 LLM 结果缓存（值：JSON {type,title,summary,install}）
local function repo_cache_key(e)
    return "intro:" .. e.key
end

local function repo_cache_get(e)
    local v = jn.cache.get(repo_cache_key(e))
    if type(v) ~= "table" then return nil end
    -- 缓存结构升级：旧版缓存无 desc_cn（GitHub 描述行中文依赖它），视为未命中
    -- 重建一次（写入新格式），避免旧缓存一直缺中文描述行
    if e.kind == "github" and v.desc_cn == nil then return nil end
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
1. 只写 README 与元数据明确给出的内容，禁止编造参数量、分数、功能、许可证、安装命令、API 价格；未写明的直接省略，禁止输出"未说明""未给出""未提及"等话术。
2. summary 一律简体中文，英文内容翻译；项目名、命令、API 名、模型名保留原文。
3. 每个仓库独立判断类型，禁止按组织/前缀归一类；同一组织不同仓库类型可能完全不同。
4. README 不一定是 README.md（可能是 README.org/.rst），别把"有文档"误判成"无文档"；多个仓库务必全部覆盖，不得遗漏。
5. desc_cn：仓库官方 description 的简体中文翻译（≤60 字），GitHub 仓库必填；无官方描述则填空字符串。

【一、GitHub 仓库类型判定与总结】
依次判定：先看是否第 1、2 类，都不是则归第 3 类。

1. MCP / Skills / Agent 插件类
证据（满足其一即倾向此类）：README 或描述含 "MCP"、"skill"、"plugin"、"插件"；README 给出面向 AI 编码工具/智能体的安装命令（如 npx skills add owner/repo、/plugin marketplace add owner/repo、/plugin install 插件名、dsh plugin add 插件名、把目录复制到 $DSH_HOME/skills/ 或 .agents/skills/）；结构含 skills/ 目录、SKILL.md、插件 manifest、MCP 配置；topics 含 claude-code、codex、agent-skills。核心特征：是"装进某个 Agent 直接用"的现成能力包，本身不是独立运行的程序。
summary 要点：产品定位一句话 + 核心能力 1~3 点 + 安装方式（必须原样写出真实命令——npx/npm 类如 npx skills add owner/repo、npm install -g 包名；插件市场类如 /plugin marketplace add owner/repo 再 /plugin install 插件名；DSH 类如 dsh plugin add 插件名；复制类写明源/目标目录；MCP 类给 claude mcp add ... -- npx -y 包名 或 mcpServers 配置块。禁止只写"需安装"不给命令）。

2. AI Agent 项目
证据：描述含 agent、智能体、自动化、workflow、一键生成、数字人、浏览器自动化；README 描述"输入→输出"流水线（如"输入主题即自动生成脚本、字幕、配乐并合成视频"）并给运行/部署说明（Docker、npm install、API Key、Web 界面）；topics 含 ai-agent、llm-agent、automation。核心特征：本身是可独立运行的程序/服务/工作流。
summary 要点：先讲"把什么变成什么"（输入→输出），再列核心能力（自动脚本/素材/字幕/配音、浏览器自动化等），最后写部署/使用方式（Docker 一键、npm install＋API Key、网页版/桌面版、本地运行）。

3. 其他类
其余全部：SDK/库与框架、API 网关/代理（把某模型封装成 OpenAI 兼容接口）、Web 应用（AI 简历编辑器、聊天前端）、数据集、论文/研究实现、学习资源（教程、awesome 精选列表）、实用小工具、整活、个人/组织主页、开源模型仓库。
summary 要点（按子类型）：SDK/库：是什么、支持什么模型/硬件、怎么装怎么调；API 网关：封装什么成什么接口、多账号/多模型、部署；Web 应用：定位、特性、部署或在线地址；数据集：规模、内容、标注、引用；论文/研究实现：论文名、方法、代码/权重地址；学习资源/awesome：范围、数量、亮点；实用工具：解决什么问题、怎么用；整活：一句话说明玩法。

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
{"repos":[{"index":1,"type":"类型中文名","title":"一句话标题（简体中文，≤30字）","summary":"详细介绍（简体中文，__MIN__~__MAX__字，突出是什么、能做什么、关键数字）","desc_cn":"官方描述中文翻译（GitHub 必填，无则空字符串）"}]}
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

-- --------------------------------------------------------------------
-- 发送 / 组装
-- --------------------------------------------------------------------
-- 组装单仓库段
local function compose_section(e)
    local lines = {}
    local name = (e.meta and e.meta.name) or (e.owner .. "/" .. e.repo)
    lines[#lines + 1] = "📦 " .. name -- 平台名不显示

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

-- 组装整条消息：段间空两行。失败条目（无 LLM 结果且有错误）直接跳过，
-- 全部失败时返回 nil 不发送（静默，不输出报错）
local function compose_message(batch)
    local sections = {}
    for _, e in ipairs(batch.entries) do
        if not e.skipped and (e.llm or not e.err) then
            sections[#sections + 1] = compose_section(e)
        end
    end
    if #sections == 0 then return nil end
    return table.concat(sections, "\n\n\n")
end

-- 发送（reply 引用 + 文本）；text 为空（全部失败）静默不发送
local function send_intro(batch, text)
    if not text or text == "" then return end
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
-- 注意：只清理本批次 own 的去重标记（e.owned_dedup）。别的消息仍在途的
-- 批次设置的去重标记不能动，否则会让同仓库并发重复抓取。
-- 全部条目被跳过（在途去重/缓存）时 compose_message 返回 nil，不发送
-- 兜底文案（避免对一条正在被处理的链接回复"整理失败"）。
local function compose_and_send(batch)
    for _, e in ipairs(batch.entries) do
        if e.owned_dedup then
            jn.cache.del("dedup:" .. e.key)
        end
    end
    local text = compose_message(batch)
    if text then
        send_intro(batch, text)
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
            local rid = jn.http.get_async(meta_api_url(e), c)
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
    local rid = jn.http.get_async(url, c)
    if not rid or rid == 0 then
        batch.pending = batch.pending - 1 -- README 拉取失败，仍继续
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
        if type(data) ~= "table" or not data.download_url then
            batch.pending = batch.pending - 1
            return
        end
        local c = copy_ctx(ctx)
        c.stage = "readme_raw"
        local rid = jn.http.get_async(data.download_url, c)
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
                }
                e.llm = content_tbl
                repo_cache_set(e, content_tbl)
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
        local ctx = { batch = batch, idx = i, stage = "meta" }
        local rid = jn.http.get_async(meta_api_url(batch.entries[i]), ctx)
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


