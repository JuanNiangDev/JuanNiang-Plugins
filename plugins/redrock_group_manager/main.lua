-- ====================================================================
-- redrock_group_manager
-- 红岩群管理工具
-- 图片刷屏 / +1复读 / 黑色地带直接处罚 / 灰色地带LLM审查 / 敏感违规 / 数据监控
-- ====================================================================

local jn = require("jn")

-- 随机话术种子
math.randomseed(os.time())

-- ====================================================================
-- 配置（可在 Web 面板配置）
-- ====================================================================

-- 图片刷屏：IMGP_SPAM_WINDOW 秒内 IMG_SPAM_THRESHOLD 张触发警告
local IMG_SPAM_WINDOW = tonumber(jn.config.get("img_spam_window")) or 2
local IMG_SPAM_THRESHOLD = tonumber(jn.config.get("img_spam_threshold")) or 3
local IMG_MUTE_DURATION = tonumber(jn.config.get("img_mute_duration")) or 60

-- +1 复读：COPY_THRESHOLD 人连续发相同消息触发
local COPY_THRESHOLD = tonumber(jn.config.get("copy_threshold")) or 3
local ENABLE_COPY_CHECK = jn.config.get("enable_copy_check")

-- ====================================================================
-- 违规词库（全部来自 txt 文件，无脚本内置词条）
-- 按命中方式分三类：
--   黑色地带（words/black.txt + words/cn_advertisement.txt）
--                    = 无歧义广告词（含样本提取话术） → 直接三级惩罚
--   灰色地带（words/all.txt）   = 语义模糊（校园卡/考研/群名片/加群等）
--                    → 命中后异步送 LLM 审查，按返回 JSON 裁决处罚
--   敏感    （色情/政治/脏话）  → 直接三级惩罚
-- 词库文件（相对插件目录，jn.file.read_lines 读取）：
--   黑色: words/black.txt（来源 campus-ad-detection-words/样本.md）+ words/cn_advertisement.txt
--   灰色: words/all.txt（campus-ad-detection-words，校园卡/考研/群名片等灰色词）
--   敏感: words/cn_pornographic.txt + words/cn_politics.txt + words/cn_general.txt
-- 内存策略：启动时一次性读入，跨文件去重，小写化；黑色词条从灰色集合剔除（黑色优先）
-- ====================================================================

local WORD_FILES = {
    black     = { "words/black.txt", "words/cn_advertisement.txt" },
    gray      = { "words/all.txt" },
    sensitive = { "words/cn_pornographic.txt", "words/cn_politics.txt", "words/cn_general.txt" },
}

--- 加载单个词库文件并入目标数组：去空白/去注释 → 小写 → 跨文件去重
--- 纯 ASCII 且短于 3 字符的 token（如 "av"）丢弃，防止误命中 "have/save" 等正常单词
local function load_word_file(path, words, seen)
    local lines, err = jn.file.read_lines(path)
    if not lines then
        jn.log.error("[redrock_group_manager] 词库加载失败 " .. path .. ": " .. (err or "unknown"))
        return 0
    end
    local n = 0
    for _, line in ipairs(lines) do
        local w = line:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if w ~= "" and w:sub(1, 1) ~= "#" and not seen[w] then
            if not (w:match("^[a-z0-9]+$") and #w < 3) then
                seen[w] = true
                n = n + 1
                words[#words + 1] = w
            end
        end
    end
    return n
end

--- 加载全部分类词库
local function load_word_lists()
    local result = {}
    for category, files in pairs(WORD_FILES) do
        local words, seen, total = {}, {}, 0
        for _, path in ipairs(files) do
            total = total + load_word_file(path, words, seen)
        end
        result[category] = words
        jn.log.info(string.format("[redrock_group_manager] %s 违规词库加载 %d 词", category, total))
    end
    return result
end

local WORDS = load_word_lists()

-- 黑色词条从灰色集合剔除（命中黑色直接处罚，不进入 LLM 审查）
local function subtract_black()
    local black = {}
    for _, w in ipairs(WORDS.black) do black[w] = true end
    local gray = {}
    for _, w in ipairs(WORDS.gray) do
        if not black[w] then gray[#gray + 1] = w end
    end
    WORDS.gray = gray
    jn.log.info(string.format("[redrock_group_manager] 灰色词库剔除黑色重叠后剩 %d 词", #gray))
end
subtract_black()

-- 三级惩罚：第 2 次违规的禁言时长（秒），默认 30 分钟
local VIOLATION_MUTE = tonumber(jn.config.get("violation_mute_seconds")) or 1800

-- ====================================================================
-- 灰色地带 LLM 审查（复用 Bot 自身 LLM Provider 配置，jn.llm 接口）
-- 命中灰色词（校园卡/考研/群名片/加群等）→ llm.chat_async 异步审查，
-- 不阻塞事件循环与其它插件；LLM 返回 JSON
--   {"violation": "ad"|"sensitive"|"none", "reason": "..."}
-- violation != none 时按三级惩罚处理，否则放行。
-- ====================================================================
local LLM_REVIEW_ENABLED = jn.config.get("llm_review_enabled")
if LLM_REVIEW_ENABLED == nil then LLM_REVIEW_ENABLED = true end
local LLM_TIMEOUT = 60          -- 单次审查超时（秒），与 Bot Provider 默认一致
local LLM_MAX_TEXT = 600        -- 送入 LLM 的消息最大长度（字符）
local LLM_DEDUP_WINDOW = 600    -- 同一条消息 10 分钟内不重复审查（秒）

local llm_pending = {}          -- ["群号:QQ"] = true 该用户已有在途审查
local llm_reviewed = {}         -- [message_id] = ts  消息去重
local llm_ctx = {}              -- [req_id] = {group_id, user_id, message_id, word, pk} 异步结果上下文

-- LLM 审查系统提示词：只输出 JSON
local LLM_SYSTEM_PROMPT = [[
你是一个 QQ 大学新生群（迎新群）的广告与敏感内容审查员。群内存在大量伪装成学校通知、勤工俭学、校园卡办理、学习资料分享的营销广告，需要你判断消息是否构成广告或敏感违规。

判断标准：
1. 广告违规（ad）：包含明确的营销、引流、变现意图，例如推销办卡/套餐/流量卡、贷款/提额/套现、兼职/刷单/修图结算、寄宿自习室/考研考公机构、0元购/1折/送福利、以"学校通知/勤工实践/资料分享"为幌子拉人进群、留下微信号/QQ群号/二维码引流等。
2. 敏感违规（sensitive）：色情、软色情/擦边、政治敏感、暴力、赌博、代孕/器官买卖等违法违禁内容。其中软色情/擦边是重点，指不出现露骨词但明显带性暗示、性挑逗、性化描述的内容，包括：
   - 性暗示/性挑逗：评价他人"骚""欲""够味"等性吸引力词汇；"谁来当我主人""求调教"等性支配/角色扮演语境；"有没有单身的哥哥""处对象"等带性暗示的求偶/交友；描述"撩起来""对着镜头扭"等性化动作。
   - 疑似未成年内容（最高优先级）：将学生/校园语境（校服、初中/高中课堂、新生）与性暗示、性化、擦边内容关联（如"初中课堂撩校服扭""学生妹"），即使没有露骨词也必须判 sensitive。
   - 擦边平台/账号引流：推荐或引流到以擦边内容为主的平台账号、主页（如"快手/抖音/推特/X 上全是性感内容""就她的主页能打""第一骚"），或分享此类平台擦边视频/截图。
3. 正常交流（none）：同学之间正常讨论学习、生活、社团、考试等，不含上述意图。

变体识别（重要，广告常用谐音/同音字、形近字、英文缩写、拼音替代、火星文、方言谐音、emoji 替代等绕过文字审查）：
- 判定前先把消息中的变体"还原"成正常写法，再按上述标准判断。
- 注意：下面给出的映射**只是常见示例，用于说明还原方法，绝非穷举**。广告变体千变万化（任意同音字、谐音、形近字、拼音缩写、数字替代、emoji、火星文、拆字、倒序都可能出现），不要局限于示例列表——凡能合理还原为营销词的写法都要按变体处理。
- 谐音/同音字：办卡→板卡/半卡/瓣卡；群→裙/峮；微信→薇信/威信/微芯/为信；加→伽/迦；免费→免沸/棉费；返利→反利/返莉；佣金→拥金；兼职→兼直；刷单→刷丹；优惠→优汇/幽惠。
- 形近字：群→裙（同旁）、办→板（同旁）等近似写法。
- 英文/拼音缩写：vx/v/x/wechat/weixin/薇x 表示微信；加v/私v/留v/加vx 表示加微信；加q/进q/加裙 表示加群；qq群/Q群 表示 QQ 群。
- emoji/表情替代：emoji 可承担文字语义，常见如 💳=卡（办卡/银行卡/校园卡）、📱=手机/电话、💰=钱/返利/佣金/转账、🛒=购物/下单/拼单、🔗=链接、➕=加、📮=私信/联系、🎁=福利/礼物、🧧=红包、🆓=免费；👗 在广告语境常代"群"（谐音裙）。凡 emoji 能合理还原为营销词的，一律按变体处理。
- 中文+emoji 混排：广告常写成"中文短句 + 营销 emoji"的混排（如"办卡找我📮""群里🈶福利🧧""💳💳校园卡办理"），靠 emoji 补足语义来规避文字匹配。判定时先还原 emoji 语义再看整句意图；emoji 本身不算违规（同学聊天也常用），关键看还原后是否有营销/引流/变现意图。
- 数字串/联系方式：消息中的连续数字串（如 1145140721）很可能是群号、QQ 号或微信号；"加裙+数字""裙号+数字"等组合是典型拉群引流。
- 拆分/插入符号：词中间插入空格、标点或符号（如"加 群""加 vx"）同样视为原词。
- 防屏蔽手法：擦边/色情/广告内容常用"一堆莫名其妙的表情包、数字、符号"插入来防止被平台或词库屏蔽（如"第1骚🌚""主人👑""校服💃""扭👯"）。遇到大量无意义 emoji/数字/符号夹杂的文本，先剥离干扰符号再还原语义判断，不要因为"被符号打乱了看不出露骨词"就放行。
- 还原后具有营销、引流、变现意图的（如"板卡加裙1145140721"还原为"办卡加群1145140721"）必须判 ad；若还原后仍是正常交流（如同学间"加个v"约打游戏），判 none。

判定原则：
- 只看消息本身是否构成违规。不要因为提及"校园卡""考研""兼职""加群"等灰色词就判违规，需结合上下文判断是否存在营销/引流意图。
- 群名片、联系方式等中性信息单独出现不算违规。
- 拿不准时倾向 none（宁放过，勿误杀），但明显的广告话术（含上述变体伪装）必须判 ad。
- 变体识别只用于还原真实意图，不要因为出现"裙/板/薇"等单字或单个 emoji 就判违规；变体（含 emoji 替代）+ 营销词 + 引流动作（数字串、加联系方式）同时出现才是强违规信号。
- 软色情从严：性暗示 + 学生/校园语境（校服、课堂、新生）必须判 sensitive；正常情感话题（"有没有对象""谈恋爱""处对象"单纯交友、宠物叫"主人"、普通"撩头发/撩人"玩笑）不算违规，需结合整体语境区分。

只输出 JSON，不要输出任何其它文字，格式：
{"violation":"ad|sensitive|none","reason":"一句话说明判定理由"}
]]

-- QQ 群聊推荐卡片：OneBot 11 json 消息段 data 中的 app 标识（计入广告违规）
local QQ_CARD_APPS = {
    "com.tencent.contact.lua",    -- 推荐联系人
    "com.tencent.troopsharecard", -- 推荐群聊卡片
}

-- ====================================================================
-- 辅助函数
-- ====================================================================

local function now_ts()
    return os.time()
end

-- ====================================================================
-- 存储层：内存缓存 + SQLite (表自动前缀 pluggin_redrock_group_manager_)
-- ====================================================================

-- 初始化数据库表
local function init_db()
    jn.database.exec([[
        CREATE TABLE IF NOT EXISTS pluggin_redrock_group_manager_kv (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    ]])
end
init_db()

-- 模块级内存缓存
local store = {}

local function get_kv(key)
    local v = store[key]
    if v ~= nil then return v end
    local rows, err = jn.database.query(
        "SELECT value FROM pluggin_redrock_group_manager_kv WHERE key = ?", { key })
    if rows and #rows > 0 then
        v = rows[1].value
        if v then store[key] = v end
    end
    return v
end

local function set_kv(key, val)
    store[key] = val
    local v = type(val) == "string" and val or tostring(val)
    jn.database.exec(
        "INSERT INTO pluggin_redrock_group_manager_kv (key, value) VALUES (?, ?) " ..
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        { key, v })
end

local function incr_kv(key)
    local v = tonumber(get_kv(key)) or 0
    v = v + 1
    set_kv(key, v)
    return v
end

-- ====================================================================
-- 管理数据：豁免 / 手动管理员 / 违规记录（持久化于 config.yaml）
-- 与 config.yaml 的 list 配置项双向同步：
--   面板「配置」页可增删修改（保存后插件自动重载生效）
--   插件在 /豁免 或违规变更时写回 config.yaml（插件目录内，jn.file）
-- 违规记录格式: "群号:QQ号:违规次数"（违规人及违规等级，面板可见可改）
-- ====================================================================

-- 配置 schema（与 config.yaml 保持一致；写回时整体重新生成 config.yaml）
local CONFIG_SCHEMA = {
    { key = "img_spam_window",         type = "string", label = "图片刷屏时间窗口(秒)",   description = "在该秒数内发送超过阈值的图片才会被判为刷屏（默认 2）",           def = "2" },
    { key = "img_spam_threshold",      type = "string", label = "图片刷屏阈值",           description = "时间窗口内触发警告的图片数量（默认 3）",                       def = "3" },
    { key = "img_mute_duration",       type = "string", label = "刷屏禁言时长(秒)",       description = "重复刷屏被禁言的时长（默认 60）",                             def = "60" },
    { key = "copy_threshold",          type = "string", label = "复读触发阈值",           description = "多少人连续发送相同消息判定为复读（默认 3）",                     def = "3" },
    { key = "enable_copy_check",       type = "bool",   label = "启用复读检测",           description = "是否启用 +1 复读检测",                                        def = true },
    { key = "violation_mute_seconds",  type = "string", label = "违规禁言时长(秒)",       description = "第二次违规时禁言时长，默认 1800（30 分钟）",                     def = "1800" },
    { key = "llm_review_enabled",      type = "bool",   label = "灰色地带LLM审查",       description = "命中灰色词（校园卡/考研/群名片/加群等）时送 LLM 审查；关闭则灰色词直接放行", def = true },
    { key = "exempt_users",            type = "list",   label = "豁免 QQ 列表",           description = "被豁免的 QQ 号不参与任何违规检测（/豁免 可添加，面板可增删）",   def = {} },
    { key = "admin_users",             type = "list",   label = "手动管理员 QQ 列表",     description = "群角色无法识别时手动指定的管理员账号（面板可增删）",               def = {} },
    { key = "violations",              type = "list",   label = "违规记录(群号:QQ:次数)", description = "违规人及违规等级，格式 群号:QQ号:次数；删除某行即重置该用户违规", def = {} },
}

local EXEMPT = {}  -- [qq] = true            豁免账号
local ADMIN  = {}  -- [qq] = true            手动管理员账号
local VIOL   = {}  -- ["群号:QQ"] = 次数      违规记录

--- YAML 双引号字符串转义
local function yaml_str(s)
    s = tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. s .. '"'
end

--- 表键排序后返回数组（保证 config.yaml 输出稳定）
local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

--- 当前配置值（静态项取模块加载时的值；动态项取内存状态）
local function config_value(key)
    if key == "img_spam_window" then return tostring(IMG_SPAM_WINDOW)
    elseif key == "img_spam_threshold" then return tostring(IMG_SPAM_THRESHOLD)
    elseif key == "img_mute_duration" then return tostring(IMG_MUTE_DURATION)
    elseif key == "copy_threshold" then return tostring(COPY_THRESHOLD)
    elseif key == "enable_copy_check" then return ENABLE_COPY_CHECK
    elseif key == "violation_mute_seconds" then return tostring(VIOLATION_MUTE)
    elseif key == "llm_review_enabled" then return LLM_REVIEW_ENABLED
    elseif key == "exempt_users" then
        local out = {}
        for _, qq in ipairs(sorted_keys(EXEMPT)) do out[#out + 1] = qq end
        return out
    elseif key == "admin_users" then
        local out = {}
        for _, qq in ipairs(sorted_keys(ADMIN)) do out[#out + 1] = qq end
        return out
    elseif key == "violations" then
        local out = {}
        for _, k in ipairs(sorted_keys(VIOL)) do out[#out + 1] = k .. ":" .. VIOL[k] end
        return out
    end
    return nil
end

--- 重新生成 config.yaml（面板 schema + 当前值 + 管理数据）
local function save_config()
    local out = {
        "# ====================================================================",
        "# redrock_group_manager 插件配置",
        "# ====================================================================",
        "# 本文件同时由插件维护（/豁免、违规记录变更时自动写回），",
        "# 也可在 Web 面板「插件 → 配置」页编辑，保存后自动重载生效。",
        "# ====================================================================",
        "",
        "configs:",
    }
    for _, item in ipairs(CONFIG_SCHEMA) do
        local v = config_value(item.key)
        out[#out + 1] = "  - key: " .. item.key
        out[#out + 1] = "    type: " .. item.type
        out[#out + 1] = "    label: " .. yaml_str(item.label)
        out[#out + 1] = "    description: " .. yaml_str(item.description)
        if item.type == "list" then
            out[#out + 1] = "    default: []"
        elseif item.type == "bool" then
            out[#out + 1] = "    default: " .. (item.def and "true" or "false")
        else
            out[#out + 1] = "    default: " .. yaml_str(item.def)
        end
        if v ~= nil then
            if type(v) == "table" then
                if #v == 0 then
                    out[#out + 1] = "    value: []"
                else
                    out[#out + 1] = "    value:"
                    for _, x in ipairs(v) do
                        out[#out + 1] = "      - " .. yaml_str(x)
                    end
                end
            elseif type(v) == "boolean" then
                out[#out + 1] = "    value: " .. (v and "true" or "false")
            else
                out[#out + 1] = "    value: " .. yaml_str(v)
            end
        end
    end
    local ok, err = jn.file.write("config.yaml", table.concat(out, "\n") .. "\n")
    if not ok then
        jn.log.error("[redrock_group_manager] 写回 config.yaml 失败: " .. (err or "unknown"))
    end
end

--- 迁移旧版 SQLite 违规记录（kv viol: 前缀）到 config.yaml，一次性
local function migrate_old_violations()
    if next(VIOL) then return end
    local rows, err = jn.database.query(
        "SELECT key, value FROM pluggin_redrock_group_manager_kv WHERE key LIKE '%:viol:%'")
    if not rows then return end
    local changed = false
    for _, r in ipairs(rows) do
        local g, u = tostring(r.key):match("^(%d+):viol:(%d+)$")
        if g then
            VIOL[g .. ":" .. u] = tonumber(r.value) or 1
            changed = true
        end
        store[r.key] = nil
        jn.database.exec("DELETE FROM pluggin_redrock_group_manager_kv WHERE key = ?", { r.key })
    end
    if changed then save_config() end
end

--- 从 config.yaml 载入管理数据（面板编辑保存后插件重载即生效）
local function load_state()
    for _, qq in ipairs(jn.config.get("exempt_users") or {}) do
        EXEMPT[tostring(qq)] = true
    end
    for _, qq in ipairs(jn.config.get("admin_users") or {}) do
        ADMIN[tostring(qq)] = true
    end
    for _, entry in ipairs(jn.config.get("violations") or {}) do
        local g, u, c = tostring(entry):match("^(%d+):(%d+):(%d+)$")
        if g then
            VIOL[g .. ":" .. u] = tonumber(c)
        end
    end
    migrate_old_violations()
end

load_state()

--- 是否被豁免（豁免账号不参与任何检测）
local function is_exempt(user_id)
    return EXEMPT[tostring(user_id)] == true
end

--- 构建 key（带群前缀）
local function gkey(group_id, suffix)
    return tostring(group_id) .. ":" .. suffix
end

--- 消息中是否包含图片/表情
local function has_image(raw)
    -- CQ 图片码 / 表情码 / 文本占位符
    return raw:find("%[CQ:image") ~= nil
        or raw:find("%[CQ:face") ~= nil
        or raw:find("%[CQ:mface") ~= nil
        or raw:find("%[图片%]") ~= nil
        or raw:find("%[表情%]") ~= nil
end

--- 匹配任意敏感词（先剥离 CQ 码，避免命中 json 卡片/图片等富文本 payload）
local function match_any(text, words)
    local lower = (text or ""):gsub("%[CQ:[^%]]*%]", " "):lower()
    for _, w in ipairs(words) do
        if lower:find(w, 1, true) then
            return w
        end
    end
    return nil
end

--- 判断是否为管理员：系统管理员（event.admins）或手动管理账号（面板 admin_users）
--- 不调用群角色 API，可安全用于高频路径
local function is_admin(event)
    if event.admins then
        for _, qq in ipairs(event.admins) do
            if tostring(qq) == tostring(event.user_id) then
                return true
            end
        end
    end
    if ADMIN[tostring(event.user_id)] then
        return true
    end
    return false
end

--- 私聊通知所有管理员
local function notify_admins(event, text)
    if not event.admins then return end
    local group_id = event.group_id
    local group_info, _ = jn.onebot11.get_group_info(group_id)
    local group_name = group_info and group_info.group_name or tostring(group_id)
    local msg = "【群管理通知】\n群: " .. group_name .. "\n" .. text
    for _, qq in ipairs(event.admins) do
        jn.onebot11.send_private_msg(tonumber(qq), msg)
    end
end

--- 撤回消息
local function delete_msg(event)
    if event.message_id then
        jn.onebot11.delete_msg(event.message_id)
    end
end

--- 回复（群聊 @ 发信人）
local function reply(event, text, image)
    if event.message_type ~= "group" then return end
    local segments = {
        { type = "at",   data = { qq = tostring(event.user_id) } },
        { type = "text", data = { text = " " .. text } },
    }
    if image then
        segments[#segments + 1] = { type = "image", data = { file = image } }
    end
    jn.onebot11.send_group_msg(event.group_id, segments)
end

--- 检测消息是否包含 QQ 群聊推荐卡片
--- OneBot 11 json 消息段: [CQ:json,data={"app":"com.tencent.troopsharecard",...}]
--- 部分实现（如 go-cqhttp）会对 data 做 URL 编码；app 值仅含字母数字与点号，不受编码影响
local function is_group_recommend_card(raw)
    if not raw then return false end
    local lower = raw:lower()
    local pos = 1
    while true do
        local s = lower:find("[cq:json", pos, true)
        if not s then return false end
        -- 只在该 CQ 段（到 ']' 为止）内查找，避免命中段外普通文本
        local e = lower:find("]", s + 1, true) or (#lower + 1)
        local segment = lower:sub(s, e - 1)
        for _, app in ipairs(QQ_CARD_APPS) do
            if segment:find(app, 1, true) then
                return true
            end
        end
        pos = e + 1
    end
    return false
end

--- 判断是否为管理员/群主（违规处罚、豁免命令使用）：
--- 系统/手动管理员直接放行；群角色可识别时 owner/admin 放行；
--- 群角色无法识别时（get_group_member_info 失败）退回手动管理账号判断
local function is_group_admin(event)
    if is_admin(event) then return true end
    local info, _ = jn.onebot11.get_group_member_info(event.group_id, event.user_id)
    if info and info.role then
        return info.role == "owner" or info.role == "admin"
    end
    return false
end

-- ====================================================================
-- 三级惩罚话术（每级多套随机，卷娘语气，参考群内其他插件）
-- 广告违规固定开头「打广告先交广告费」，敏感违规固定「小鬼不能碰」
-- ====================================================================

local TIER_TEMPLATES = {
    ad = {
        {
            "打广告先交广告费！卷娘记住本本上了，本次违规予以警告。再犯的话可就要禁言 30 分钟啦～",
            "打广告先交广告费！卷娘记住本本上了，本次违规予以警告。下次再发广告就是禁言 30 分钟起步哦",
            "打广告先交广告费！卷娘记住本本上了，本次违规予以警告。广告费什么时候交呀～",
        },
        {
            "打广告先交广告费！卷娘记住本本上了，本次违规予以禁言 30 分钟。再犯的话就只能请你出去啦～",
            "打广告先交广告费！卷娘记住本本上了，本次违规予以禁言 30 分钟。事不过三，第三次就走人了哦",
            "打广告先交广告费！卷娘记住本本上了，本次违规予以禁言 30 分钟。歇会儿冷静一下吧～",
        },
        {
            "打广告先交广告费！卷娘记住本本上了，本次违规予以踢出群聊。广告费没交，江湖再见啦～",
            "打广告先交广告费！卷娘记住本本上了，本次违规予以踢出群聊。想回来记得先把广告费交了哦～",
            "打广告先交广告费！卷娘记住本本上了，本次违规予以踢出群聊。三次广告，本本都写满了～",
        },
    },
    sensitive = {
        {
            "小鬼不能碰这个话题哦。卷娘记住本本上了，本次违规予以警告。再犯的话可就要禁言 30 分钟啦～",
            "小鬼不能碰这个话题哦。卷娘记住本本上了，本次违规予以警告。下次再聊就是禁言 30 分钟起步",
            "小鬼不能碰这个话题哦。卷娘记住本本上了，本次违规予以警告。这个话题就当没看见吧～",
        },
        {
            "小鬼不能碰这个话题哦。卷娘记住本本上了，本次违规予以禁言 30 分钟。再犯的话就只能请你出去啦～",
            "小鬼不能碰这个话题哦。卷娘记住本本上了，本次违规予以禁言 30 分钟。事不过三哦",
            "小鬼不能碰这个话题哦。卷娘记住本本上了，本次违规予以禁言 30 分钟。冷静一下哦～",
        },
        {
            "小鬼不能碰这个话题哦。卷娘记住本本上了，本次违规予以踢出群聊。江湖再见啦～",
            "小鬼不能碰这个话题哦。卷娘记住本本上了，本次违规予以踢出群聊。换个群好好说话哦～",
            "小鬼不能碰这个话题哦。卷娘记住本本上了，本次违规予以踢出群聊。三次了还聊，本本都写满了～",
        },
    },
}

--- 三级惩罚：命中词库 / 发送 QQ 推荐卡片的统一处理
--- 第 1 次：撤回 + 警告
--- 第 2 次：撤回 + 禁言 30 分钟
--- 第 3 次：撤回 + 踢出群聊，并重置该用户违规次数
local function handle_violation(event, reason, category)
    local group_id = event.group_id
    local user_id = event.user_id

    -- 管理员/群主豁免
    if is_group_admin(event) then return end

    -- 违规次数按 群:用户 记录（config.yaml 持久化，面板可见可改）
    local vkey = tostring(group_id) .. ":" .. tostring(user_id)
    local count = (VIOL[vkey] or 0) + 1
    VIOL[vkey] = count
    save_config()

    -- 三级惩罚：1 警告 / 2 禁言30分钟 / 3 踢出群聊（踢出后重置次数）
    local action
    if count == 1 then
        action = "撤回并警告"
        delete_msg(event)
    elseif count == 2 then
        action = "撤回并禁言30分钟"
        delete_msg(event)
        jn.onebot11.ban_group_member(group_id, user_id, VIOLATION_MUTE)
        incr_kv(gkey(group_id, "stats:mute"))
    else
        action = "撤回并踢出群聊"
        delete_msg(event)
        jn.onebot11.kick_group_member(group_id, user_id, false)
        VIOL[vkey] = nil -- 踢出后重置违规次数
        save_config()
        incr_kv(gkey(group_id, "stats:kick"))
    end
    incr_kv(gkey(group_id, "stats:" .. category))

    -- 卡片计入广告违规话术
    local msg_cat = category == "card" and "ad" or category
    local templates = TIER_TEMPLATES[msg_cat] or TIER_TEMPLATES.ad
    local bucket = templates[count] or templates[3]
    reply(event, bucket[math.random(#bucket)])

    notify_admins(event, string.format("%d %s（第 %d 次）-> %s", user_id, reason, count, action))
    jn.log.info(string.format("[group_mgr] %d %s（第 %d 次）群 %d -> %s", user_id, reason, count, group_id, action))
end

-- ====================================================================
-- 1. 图片刷屏检测
-- ====================================================================
local function check_image_spam(event)
    if not has_image(event.raw_message) then return false end

    local group_id = event.group_id
    local user_id = event.user_id
    jn.log.info(string.format("[group_mgr] 检测到图片: user=%d 群=%d", user_id, group_id))

    local key = gkey(group_id, "ims:" .. tostring(user_id))
    local warn_key = gkey(group_id, "ims_w:" .. tostring(user_id))

    -- 获取历史时间戳
    local raw_ts = get_kv(key) or ""
    local timestamps = {}
    if raw_ts ~= "" then
        for ts in raw_ts:gmatch("[^,]+") do
            timestamps[#timestamps + 1] = tonumber(ts)
        end
    end

    -- 清理过期时间戳
    local cutoff = now_ts() - IMG_SPAM_WINDOW
    local recent = {}
    for _, ts in ipairs(timestamps) do
        if ts >= cutoff then
            recent[#recent + 1] = ts
        end
    end
    -- 加上当前
    recent[#recent + 1] = now_ts()

    -- 保存
    local vals = {}
    for _, ts in ipairs(recent) do
        vals[#vals + 1] = tostring(ts)
    end
    set_kv(key, table.concat(vals, ","))

    -- 判断
    if #recent >= IMG_SPAM_THRESHOLD then
        local warned = get_kv(warn_key)
        if warned == "1" then
            -- 已经警告过，还在刷 → 禁言
            jn.onebot11.ban_group_member(group_id, user_id, IMG_MUTE_DURATION)
            incr_kv(gkey(group_id, "stats:mute"))
            jn.log.info(string.format("[group_mgr] %d 刷屏禁言 %ds 群 %d", user_id, IMG_MUTE_DURATION, group_id))
            notify_admins(event, user_id .. " 因图片刷屏被禁言 " .. IMG_MUTE_DURATION .. "s")
        else
            -- 首次警告
            set_kv(warn_key, "1")
            reply(event, "做文明群友，杜绝刷屏哦！", "img/shuaping.png")
            incr_kv(gkey(group_id, "stats:warn"))
        end
        return true
    elseif #recent == 1 then
        -- 解除警告标记（重新开始计数）
        set_kv(warn_key, "0")
    end

    return false
end

-- ====================================================================
-- 2. +1 复读检测
-- ====================================================================
local function check_copy_spam(event)
    local raw = (event.raw_message or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return false end
    -- 只检测纯文本消息
    if raw:find("%[CQ:") then return false end

    local group_id = event.group_id
    local user_id = event.user_id
    local last_key = gkey(group_id, "cp:last")
    local count_key = gkey(group_id, "cp:count")
    local users_key = gkey(group_id, "cp:users")

    -- 复读检测开关（面板修改后保存会重载插件，重新生效）
    if ENABLE_COPY_CHECK == false then return false end

    local last_msg = get_kv(last_key) or ""

    if raw == last_msg then
        -- 同一消息，检查用户是否已参与
        local users = get_kv(users_key) or ""
        if users:find(tostring(user_id)) then
            return false -- 同一用户不算复读
        end
        users = users .. "," .. tostring(user_id)
        set_kv(users_key, users)

        local count = incr_kv(count_key)

        if count >= COPY_THRESHOLD then
            jn.log.info(string.format("[group_mgr] 复读触发: count=%d 群=%d", count, group_id))
            -- 触发复读警告（仅首次）
            local triggered_key = gkey(group_id, "cp:trig")
            if get_kv(triggered_key) ~= "1" then
                jn.onebot11.send_group_msg(group_id, {
                    { type = "text", data = { text = "你们这群人机能不能别刷屏了" } },
                    { type = "image", data = { file = "img/shuaping_2.png" } },
                })
                set_kv(triggered_key, "1")
                -- 10 秒后重置触发标记
                -- (无法做延迟，用 TTL 近似：下次不同消息时重置)
                incr_kv(gkey(group_id, "stats:copy_warn"))
            end
            return true
        end
        return false
    else
        -- 不同消息，重置
        set_kv(last_key, raw)
        set_kv(count_key, "1")
        set_kv(users_key, tostring(user_id))
        set_kv(gkey(group_id, "cp:trig"), "0")
        return false
    end
end

-- ====================================================================
-- 3.5 灰色地带 LLM 审查（异步，不阻塞）
-- 命中灰色词 → jn.llm.chat_async 提交审查并立即返回 req_id；LLM 返回 JSON
-- {violation, reason} 后由引擎派发到插件入口 on_chat_response(req_id, content, err)，
-- 插件按 req_id 取回上下文，再按三级惩罚处理。审查耗时期间不阻塞
-- 消息流程，也不消费消息（先放行，违规再追罚）。
-- ====================================================================
local function llm_review_message(event, word)
    if not LLM_REVIEW_ENABLED then
        jn.log.info(string.format("[group_mgr] LLM 审查未启用，灰色词放行: user=%d 群=%d 词=%s", event.user_id, event.group_id, word))
        return
    end
    if not jn.llm or not jn.llm.available() then
        jn.log.warn(string.format("[group_mgr] 无可用 LLM Provider，灰色词放行: user=%d 群=%d 词=%s", event.user_id, event.group_id, word))
        return
    end

    -- 同一用户同一时刻只保留一个在途审查，避免刷屏打爆 LLM
    local pk = tostring(event.group_id) .. ":" .. tostring(event.user_id)
    if llm_pending[pk] then return end

    -- 同一条消息不重复审查（内存去重 + 顺带清理过期条目）
    local mid = tostring(event.message_id or "")
    local now = now_ts()
    if mid ~= "" and llm_reviewed[mid] and now - llm_reviewed[mid] < LLM_DEDUP_WINDOW then return end
    llm_pending[pk] = true
    if mid ~= "" then llm_reviewed[mid] = now end
    local expired = {}
    for k, ts in pairs(llm_reviewed) do
        if now - ts >= LLM_DEDUP_WINDOW then expired[#expired + 1] = k end
    end
    for _, k in ipairs(expired) do llm_reviewed[k] = nil end

    -- 剥离 CQ 码后截断送入 LLM
    local text = (event.raw_message or ""):gsub("%[CQ:[^%]]*%]", " "):gsub("%s+", " "):sub(1, LLM_MAX_TEXT)
    local messages = {
        { role = "system", content = LLM_SYSTEM_PROMPT },
        { role = "user", content = "待审查群消息（命中灰色词：<" .. word .. ">）：\n" .. text },
    }
    local rid = jn.llm.chat_async(messages, { timeout = LLM_TIMEOUT })
    if not rid or rid == 0 then
        llm_pending[pk] = nil
        jn.log.warn("[group_mgr] llm.chat_async 提交失败，灰色词放行")
        return
    end
    -- 记录上下文，on_chat_response 收到结果后按 req_id 取回
    llm_ctx[rid] = { group_id = event.group_id, user_id = event.user_id, message_id = mid, word = word, pk = pk }
end

-- 异步 LLM 审查结果入口（引擎异步注册表 kind "chat" 派发）：
-- on_chat_response(req_id, content, err)，err 为 nil 表示成功。
function on_chat_response(req_id, content, err)
    local ctx = llm_ctx[req_id]
    if not ctx then return end
    llm_ctx[req_id] = nil
    llm_pending[ctx.pk] = nil
    if err and err ~= "" then
        jn.log.warn(string.format("[group_mgr] LLM 审查失败: %s", tostring(err)))
        return
    end
    local verdict = jn.json.decode(content or "")
    if type(verdict) ~= "table" then
        jn.log.warn("[group_mgr] LLM 审查返回非 JSON，放行: " .. tostring(content))
        return
    end
    local violation = verdict.violation
    local reason = verdict.reason or ctx.word
    if violation == "ad" or violation == "sensitive" then
        -- 审查耗时期间可能已被豁免/成为管理员，复查后再处罚
        local event = { group_id = ctx.group_id, user_id = ctx.user_id, message_type = "group" }
        if ctx.message_id ~= "" then event.message_id = ctx.message_id end
        if is_exempt(ctx.user_id) or is_group_admin(event) then return end
        local category = violation == "sensitive" and "sensitive" or "ad"
        handle_violation(event, "LLM审查(" .. category .. ")：" .. tostring(reason), category)
    else
        jn.log.info(string.format("[group_mgr] LLM 审查放行: user=%d 群=%d 词=%s", ctx.user_id, ctx.group_id, ctx.word))
    end
end

-- ====================================================================
-- 3. 敏感/广告内容检测
-- 顺序：推荐卡片 → 敏感词库 → 黑色地带 → 灰色地带(LLM审查)
-- ====================================================================
local function check_sensitive(event)
    local raw = event.raw_message or ""

    -- 管理员豁免
    if is_admin(event) then return false end

    -- 广告违规：QQ 群聊推荐卡片
    if is_group_recommend_card(raw) then
        handle_violation(event, "广告违规：推荐群聊卡片", "card")
        return true
    end

    -- 敏感违规：色情 / 政治 / 脏话词库
    local sw = match_any(raw, WORDS.sensitive)
    if sw then
        handle_violation(event, "敏感违规：" .. sw, "sensitive")
        return true
    end

    -- 黑色地带：无歧义广告词（样本提取 + cn_advertisement）→ 直接三级惩罚
    local bw = match_any(raw, WORDS.black)
    if bw then
        handle_violation(event, "广告违规(黑名单)：" .. bw, "ad")
        return true
    end

    -- 灰色地带：语义模糊（校园卡/考研/群名片/加群等）→ 异步 LLM 审查，
    -- 不立即处罚、不消费消息；LLM 判定违规后由回调追罚
    local gw = match_any(raw, WORDS.gray)
    if gw then
        llm_review_message(event, gw)
    end

    return false
end

-- ====================================================================
-- on_message
-- ====================================================================
function on_message(event)
    if event.message_type ~= "group" then return false, nil end

    -- 豁免账号不参与任何检测
    if is_exempt(event.user_id) then return false, nil end

    -- 违规检测（广告/敏感，优先级最高）
    if check_sensitive(event) then return true end

    -- 图片刷屏
    if check_image_spam(event) then return true end

    -- +1 复读
    if check_copy_spam(event) then return true end

    return false, nil
end

-- ====================================================================
-- on_notice: 入群统计
-- ====================================================================
function on_notice(event)
    if event.notice_type ~= "group_increase" then return end
    local group_id = event.group_id
    local date = os.date("%Y-%m-%d")
    incr_kv(gkey(group_id, "stats:join:" .. date))
end

-- ====================================================================
-- 命令: /groupstats —— 管理员查看统计
-- ====================================================================
jn.command.register("groupstats", function(args, event)
    if not is_admin(event) then
        reply(event, "只有管理员可以查看统计数据哦～")
        return true
    end

    local group_id = event.group_id
    local date = os.date("%Y-%m-%d")

    local joins = tonumber(get_kv(gkey(group_id, "stats:join:" .. date)) or "0")
    local warns = tonumber(get_kv(gkey(group_id, "stats:warn")) or "0")
    local mutes = tonumber(get_kv(gkey(group_id, "stats:mute")) or "0")
    local copy_warn = tonumber(get_kv(gkey(group_id, "stats:copy_warn")) or "0")
    local ad = tonumber(get_kv(gkey(group_id, "stats:ad")) or "0")
    local card = tonumber(get_kv(gkey(group_id, "stats:card")) or "0")
    local sensitive = tonumber(get_kv(gkey(group_id, "stats:sensitive")) or "0")
    local kicks = tonumber(get_kv(gkey(group_id, "stats:kick")) or "0")

    local text = string.format([[
📊 群管理统计 (%s)
────────────────
今日入群: %d 人
刷屏警告: %d 次
刷屏禁言: %d 次
复读警告: %d 次
广告违规: %d 次
敏感违规: %d 次
踢出群聊: %d 次]],
        date, joins, warns, mutes, copy_warn, ad + card, sensitive, kicks)

    reply(event, text)
    return true
end, {
    description = "查看群管理统计数据（管理员）",
    usage = "/groupstats",
})

-- ====================================================================
-- 命令: /豁免 —— 管理员豁免某用户（不再检测，清除其违规记录）
-- ====================================================================

-- 豁免话术（多套随机）
local EXEMPT_TEMPLATES = {
    ok = {
        "好啦，%d 已经被卷娘记到豁免小本本上啦，违规记录也清空咯～",
        "收到！%d 以后可以放心发言，卷娘不会管 TA 啦，违规记录已清空～",
        "%d 获得免死金牌一枚！卷娘已豁免 TA，并清空了违规记录哦～",
    },
    denied = {
        "只有管理员才能用豁免哦～",
        "豁免是管理员的专属技能啦，你不行哦～",
    },
    usage = {
        "用法：/豁免 QQ号 或 /豁免 @某人 哦～",
    },
    already = {
        "%d 早就在卷娘的豁免名单里啦～",
    },
}

--- 随机取一条话术（可选 string.format 参数）
local function pick(msgs, fmt)
    local m = msgs[math.random(#msgs)]
    if fmt then m = string.format(m, fmt) end
    return m
end

--- 解析 /豁免 参数：QQ 号 或 @某人（[CQ:at,qq=...]）
local function parse_target_q(args)
    if not args or #args == 0 then return nil end
    local raw = tostring(args[1])
    local qq = raw:match("%[CQ:at,qq=(%d+)")
    if not qq then
        qq = raw:match("^(%d+)$")
    end
    if not qq then return nil end
    return tonumber(qq)
end

--- 豁免时自动解除禁言：直接调用 ban_group_member(duration=0) 解除。
--- 不依赖 get_group_member_info 的 shut_up_timestamp 判断——部分 OneBot
--- 实现（如 NapCat 群成员缓存）该字段可能缺失/失效，导致漏判不调解禁。
--- duration=0 为 OneBot11 规范解禁语义（0 表示取消禁言），对未禁言成员是无害 no-op。
local function unmute_if_banned(group_id, user_id)
    local ok, err = jn.onebot11.ban_group_member(group_id, user_id, 0)
    if not ok then
        jn.log.warn(string.format("[group_mgr] 豁免 %d 自动解禁失败（群 %d）: %s", user_id, group_id, tostring(err)))
        return false
    end
    jn.log.info(string.format("[group_mgr] 豁免 %d 时自动解除禁言（群 %d）", user_id, group_id))
    return true
end

jn.command.register("豁免", function(args, event)
    if event.message_type ~= "group" then
        reply(event, "该命令仅限群聊使用哦～")
        return true
    end
    if not is_group_admin(event) then
        reply(event, pick(EXEMPT_TEMPLATES.denied))
        return true
    end
    local qq = parse_target_q(args)
    if not qq then
        reply(event, pick(EXEMPT_TEMPLATES.usage))
        return true
    end
    if EXEMPT[tostring(qq)] then
        reply(event, pick(EXEMPT_TEMPLATES.already, qq))
        return true
    end

    EXEMPT[tostring(qq)] = true
    -- 清除该账号全部群的违规记录
    local cleared = 0
    local suffix = ":" .. tostring(qq)
    for k in pairs(VIOL) do
        if k:sub(-#suffix) == suffix then
            VIOL[k] = nil
            cleared = cleared + 1
        end
    end
    save_config()

    -- 豁免时若用户处于禁言状态自动解除禁言
    local unmuted = unmute_if_banned(event.group_id, qq)

    local msg = pick(EXEMPT_TEMPLATES.ok, qq)
    if unmuted then
        msg = msg .. "另外 TA 之前被禁言，已顺手解除咯～"
    end
    reply(event, msg)
    jn.log.info(string.format("[group_mgr] %d 豁免了 %d（清除违规 %d 条，解除禁言 %s）", event.user_id, qq, cleared, tostring(unmuted)))
    return true
end, {
    description = "豁免某用户：不再检测、清除违规记录，若被禁言自动解除（管理员）",
    usage = "/豁免 QQ号 或 /豁免 @某人",
})

-- ====================================================================
-- 命令: /解除豁免（/取消豁免）—— 管理员从豁免清单移除某用户，恢复检测
-- ====================================================================

local UNEXEMPT_TEMPLATES = {
    ok = {
        "好啦，%d 的豁免已解除，回归正常检测咯～",
        "收到！%d 已从豁免清单移除，之后会正常检测啦～",
        "免死金牌收回！%d 解除豁免，卷娘继续盯着 TA 哦～",
    },
    not_found = {
        "%d 本来就不在豁免清单里啦～",
    },
    usage = {
        "用法：/解除豁免 QQ号 或 /解除豁免 @某人 哦～",
    },
}

local function register_unexempt(path)
    jn.command.register(path, function(args, event)
        if event.message_type ~= "group" then
            reply(event, "该命令仅限群聊使用哦～")
            return true
        end
        if not is_group_admin(event) then
            reply(event, pick(EXEMPT_TEMPLATES.denied))
            return true
        end
        local qq = parse_target_q(args)
        if not qq then
            reply(event, pick(UNEXEMPT_TEMPLATES.usage))
            return true
        end
        if EXEMPT[tostring(qq)] then
            EXEMPT[tostring(qq)] = nil
            save_config()
            reply(event, pick(UNEXEMPT_TEMPLATES.ok, qq))
            jn.log.info(string.format("[group_mgr] %d 解除了 %d 的豁免", event.user_id, qq))
        else
            reply(event, pick(UNEXEMPT_TEMPLATES.not_found, qq))
        end
        return true
    end, {
        description = "解除豁免某用户：从豁免清单移除，恢复检测（管理员）",
        usage = "/解除豁免 QQ号 或 /解除豁免 @某人",
    })
end

register_unexempt("解除豁免")
register_unexempt("取消豁免")

jn.log.info("[redrock_group_manager] 群管理插件已加载")
