-- ====================================================================
-- redrock_caidanci_grade
-- 红岩网校分级猜单词小游戏 (Wordle)
-- 难度: 高考/四级/六级/考研/雅思/托福/GRE（默认四级）
-- 词库: words.csv（word,translation,tag，启动时加载进内存索引）
-- 棋盘: HTML 模板 + T2I 渲染 PNG（本地 PoetsenOne 字体），按棋盘状态缓存
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- 词库（words.csv → 内存索引）
--
-- words.csv 由 7 个分级词库合并生成（已去除音标列）：
--   - word 纯小写字母；tag 为难度标识（gaokao/cet4/cet6/kaoyan/ielts/toefl/gre）
--   - translation 可能被引号包裹（内含逗号），引号内 "" 为转义引号
--   - translation 中的字面 "\r\n" / "\n" 序列表示换行，加载时转为真实换行
-- 只读数据，启动时一次性加载；查询全部为 O(1) 哈希查找，无外部依赖
-- ====================================================================

local DIFFICULTIES = {
    { key = "gaokao", name = "高考" },
    { key = "cet4",   name = "四级" },
    { key = "cet6",   name = "六级" },
    { key = "kaoyan", name = "考研" },
    { key = "ielts",  name = "雅思" },
    { key = "toefl",  name = "托福" },
    { key = "gre",    name = "GRE" },
}

-- 难度别名（命令参数，大小写不敏感）
local ALIASES = {
    gaokao = "gaokao", ["高考"] = "gaokao",
    cet4 = "cet4", ["cet-4"] = "cet4", ["四级"] = "cet4",
    cet6 = "cet6", ["cet-6"] = "cet6", ["六级"] = "cet6",
    kaoyan = "kaoyan", ["考研"] = "kaoyan",
    ielts = "ielts", ["雅思"] = "ielts",
    toefl = "toefl", ["托福"] = "toefl",
    gre = "gre",
}

local words_by_len = {}  -- [diff_key][len] = {word,...}
local union_words = {}   -- 全部词库并集（词典校验用）
local word_trans = {}    -- [word] = 中文释义

--- 解析一行 CSV（word,translation,tag）
--- translation 带引号时：先剥离末尾的 ,tag（tag 不含逗号），再去掉首尾引号并还原 ""。
--- 返回 word, translation, tag；格式非法返回 nil
local function parse_row(line)
    local word, rest = line:match("^([^,]*),(.*)$")
    if not rest then return nil end
    local trans, tag
    if rest:sub(1, 1) == '"' then
        local close = rest:match(",([^,]*)$")
        local field = close and rest:sub(1, #rest - #close - 1) or rest
        if field:sub(1, 1) ~= '"' or field:sub(-1) ~= '"' then return nil end
        trans = field:sub(2, -2):gsub('""', '"')
        tag = close or ""
    else
        local head, tail = rest:match("^(.-),(.*)$")
        if head then
            trans, tag = head, tail
        else
            trans, tag = rest, ""
        end
    end
    -- 字面 "\r\n" / "\n" 序列转为真实换行，便于消息展示
    if trans:find("\\n", 1, true) then
        trans = trans:gsub("\\r\\n", "\n"):gsub("\\n", "\n")
    end
    return word, trans, tag
end

--- 从 words.csv 行数组构建内存索引
---@return number row_count 保留的有效行数
---@return number word_count 唯一单词数
local function build_index(lines)
    local row_count = 0
    local word_count = 0
    for _, line in ipairs(lines) do
        -- 跳过表头（精确匹配，避免误伤词库中真实的 "word" 词条）
        if line ~= "word,translation,tag" then
            local word, trans, tag = parse_row(line)
            if word and tag ~= "" and word:match("^[a-z]+$") then
                row_count = row_count + 1
                local bucket = words_by_len[tag]
                if not bucket then
                    bucket = {}
                    words_by_len[tag] = bucket
                end
                local L = #word
                local lenb = bucket[L]
                if not lenb then
                    lenb = {}
                    bucket[L] = lenb
                end
                lenb[#lenb + 1] = word
                union_words[word] = true
                if word_trans[word] == nil then
                    word_trans[word] = trans
                    word_count = word_count + 1
                end
            end
        end
    end
    return row_count, word_count
end

local function load_wordlists()
    local lines, err = jn.file.read_lines("words.csv")
    if not lines then
        jn.log.error("[caidanci_grade] 词库加载失败 words.csv: " .. (err or "unknown"))
        return
    end
    local rows, uniq = build_index(lines)
    jn.log.info(string.format("[caidanci_grade] 词库加载 %d 行 / %d 个唯一单词", rows, uniq))
end
load_wordlists()

-- ====================================================================
-- 常量（可在 Web 面板配置中调整）
-- ====================================================================
local DEFAULT_DIFF = ALIASES[tostring(jn.config.get("default_difficulty") or "四级"):lower()] or "cet4"
local MIN_LENGTH = 4
local MAX_LENGTH = tonumber(jn.config.get("max_length")) or 10
local DEFAULT_LEN_MIN = tonumber(jn.config.get("default_length_min")) or 4
local DEFAULT_LEN_MAX = tonumber(jn.config.get("default_length_max")) or 6
local MAX_ATTEMPTS = tonumber(jn.config.get("max_attempts")) or 6
local BOARD_CACHE_TTL = 86400 -- 棋盘图片 URL 缓存（秒）

-- 配置健壮性：随机长度范围必须落在合法区间内
if MAX_LENGTH < MIN_LENGTH then MAX_LENGTH = MIN_LENGTH end
if DEFAULT_LEN_MIN > DEFAULT_LEN_MAX then
    DEFAULT_LEN_MIN, DEFAULT_LEN_MAX = DEFAULT_LEN_MAX, DEFAULT_LEN_MIN
end
if DEFAULT_LEN_MIN < MIN_LENGTH then DEFAULT_LEN_MIN = MIN_LENGTH end
if DEFAULT_LEN_MAX > MAX_LENGTH then DEFAULT_LEN_MAX = MAX_LENGTH end
if DEFAULT_LEN_MIN > DEFAULT_LEN_MAX then DEFAULT_LEN_MIN = DEFAULT_LEN_MAX end

-- ====================================================================
-- 棋盘渲染尺寸预设
-- ====================================================================
-- 与 board_template.html 的 tile/gap/padding 严格对应；按单词长度与最大
-- 猜测次数算出精确画布尺寸，随 T2I options 下发（viewport + full_page=false），
-- 使每个长度都渲染成恰好容纳棋盘的图片，避免出现大面积空白。
local TILE_SIZE = 52 -- 单格边长 (px)
local TILE_GAP = 7   -- 格间距 (px)
local BOARD_PAD = 16 -- 棋盘外边距 (px)

--- 计算某长度棋盘的精确画布尺寸
---@return number width 画布宽 (px)
---@return number height 画布高 (px)
local function board_size(length, rows)
    local w = length * TILE_SIZE + (length - 1) * TILE_GAP + BOARD_PAD * 2
    local h = rows * TILE_SIZE + (rows - 1) * TILE_GAP + BOARD_PAD * 2
    return w, h
end

-- ====================================================================
-- 辅助函数
-- ====================================================================

--- 构建缓存 key（按群隔离）
local function cache_key(group_id)
    return tostring(group_id)
end

--- 获取游戏状态
---@return table|nil
local function get_game(group_id)
    return jn.cache.get(cache_key(group_id))
end

--- 保存游戏状态
local function save_game(group_id, game)
    local ok, err = jn.cache.set(cache_key(group_id), game)
    if not ok then
        jn.log.error("[caidanci_grade] 保存游戏状态失败: " .. (err or "unknown"))
    end
end

--- 删除游戏状态
local function delete_game(group_id)
    jn.cache.del(cache_key(group_id))
end

--- 从指定难度的指定长度词中随机选一个
local function pick_word(diff_key, length)
    local bucket = words_by_len[diff_key] and words_by_len[diff_key][length]
    if not bucket or #bucket == 0 then return nil end
    return bucket[math.random(#bucket)]
end

--- 难度 key → 显示名
local function diff_name(diff_key)
    for _, d in ipairs(DIFFICULTIES) do
        if d.key == diff_key then return d.name end
    end
    return diff_key
end

--- 比较猜测和目标单词，返回状态串（G=绿 / Y=黄 / X=灰）
--- 参考 Wordle 规则：先标记绿色，再标记黄色，最后灰色
local function compare_guess(guess, target)
    local n = #target
    local result = {}
    local used = {}

    for i = 1, n do
        result[i] = "X"
        used[i] = false
    end

    -- 第一遍：绿色 (位置正确)
    for i = 1, n do
        if string.sub(guess, i, i) == string.sub(target, i, i) then
            result[i] = "G"
            used[i] = true
        end
    end

    -- 第二遍：黄色 (字母存在但位置不对)
    for i = 1, n do
        if result[i] == "X" then
            local ch = string.sub(guess, i, i)
            for j = 1, n do
                if not used[j] and string.sub(target, j, j) == ch then
                    result[i] = "Y"
                    used[j] = true
                    break
                end
            end
        end
    end

    return table.concat(result, "")
end

--- 获取第 N 次猜测的鼓励语
---@param hint_used boolean 本局提示是否已用（已用则不再引导 /提示）
local function get_encouragement(attempt_num, max_attempts, feedback, hint_used)
    local green_count = 0
    for _ in string.gmatch(feedback, "G") do
        green_count = green_count + 1
    end

    if green_count >= 3 then
        local cheers = { "超对！就这样继续～💪", "很棒！大部分都对了！", "卷娘觉得你离答案越来越近了！", "厉害呀，方向完全正确！" }
        return cheers[math.random(#cheers)]
    elseif green_count >= 1 then
        local cheers = { "有好几个字母对了！加油～", "开头不错，再想想后面的～", "方向是对的，继续尝试！", "很不错，再调整一下就好！" }
        return cheers[math.random(#cheers)]
    end

    local remaining = max_attempts - attempt_num
    if remaining <= 1 then
        return "最后一次机会啦！卷娘相信你一定能猜出来✨"
    elseif remaining <= 2 then
        if hint_used then
            return "还有" .. remaining .. "次机会，加油～"
        end
        return "还有" .. remaining .. "次机会，用 /提示 获取帮助哦～"
    else
        local encouragements = {
            "别急，慢慢来～",
            "加油，卷娘觉得你可以的！",
            "再试一个试试，说不定就对啦～",
            "猜单词就像 debug，多试几次总能找到问题所在😜",
        }
        return encouragements[math.random(#encouragements)]
    end
end

--- 获胜时的庆祝语
local function get_victory_msg(word, attempt_num)
    local msgs = {
        "🎉 恭喜！你猜对了！答案就是 " .. word .. "！",
        "✨ 太厉害了！" .. word .. " 就是这个单词！",
        "🏆 完美！" .. word .. "，猜词大师就是你！",
        "👏 不错哦～" .. attempt_num .. " 次就猜出了 " .. word .. "！",
    }
    return msgs[math.random(#msgs)]
end

--- 单词中文释义（无释义返回 nil）
local function word_meaning(word)
    local t = word_trans[word]
    if t == nil or t == "" then return nil end
    return t
end

--- 在文本末尾追加释义行（无释义时原样返回）
local function append_meaning(text, word)
    local meaning = word_meaning(word)
    if meaning then
        return text .. "\n📖 " .. meaning
    end
    return text
end

--- 词性缩写 → 中文词性名
local POS_NAMES = {
    n = "名词", v = "动词", vt = "及物动词", vi = "不及物动词",
    a = "形容词", adj = "形容词", ad = "副词", adv = "副词",
    prep = "介词", pron = "代词", conj = "连词", interj = "感叹词",
    num = "数词", art = "冠词", aux = "助动词", modal = "情态动词",
    abbr = "缩写",
}

--- 取释义行中的第一个中文意思（按 ASCII / 全角逗号分号切分，字节级扫描）
---
--- 注意：不能用 Lua 字符类写 `[^,;，；]+` 来切分——Lua 模式按「字节」匹配，
--- 全角 `，；` 的 UTF-8 字节（EF BC 8C / EF BC 9B）会混进排除集合，导致任何
--- 多字节编码中含有 0xBC/0x8C/0x9B/0xEF 的汉字被拦腰截断，产出半个汉字
--- （如 `伤`=E4 BC A4 含 0xBC，会被切成「悲\xE4」这类非法 UTF-8 乱码）。
--- 这里改为逐字节扫描，只在真正的分隔符处切断。
---@param rest string 词性行内容（如 "悲伤的, 痛的, 引起痛苦的"）
---@return string 首个释义（可能为空串，表示 rest 以分隔符开头）
local function first_meaning(rest)
    local len = #rest
    for i = 1, len do
        local b = string.byte(rest, i)
        if b == 0x2C or b == 0x3B then -- ASCII , ;
            return rest:sub(1, i - 1)
        end
        if b == 0xEF and i + 2 <= len then -- 全角 ，(EF BC 8C) / ；(EF BC 9B)
            local b2 = string.byte(rest, i + 1)
            local b3 = string.byte(rest, i + 2)
            if (b2 == 0xBC and (b3 == 0x8C or b3 == 0x9B)) then
                return rest:sub(1, i - 1)
            end
        end
    end
    return rest
end

--- 丢弃字符串尾部不完整的 UTF-8 序列（防御脏词库数据，避免发出半个汉字）。
--- 完整序列（含 ASCII 结尾）原样保留；只处理「起始字节声明长度超出实际」的截断。
---@param s string
---@return string
local function truncate_tail_utf8(s)
    local len = #s
    local cont = 0 -- 从尾部起连续的后续字节数
    while len > 0 do
        local b = string.byte(s, len)
        if b < 0x80 then
            return s:sub(1, len) -- ASCII 字符收尾，之前序列必然完整
        elseif b >= 0xC0 then
            local need -- 该起始字节应携带的后续字节数
            if b < 0xE0 then need = 1
            elseif b < 0xF0 then need = 2
            else need = 3 end
            if cont >= need then
                return s:sub(1, len + need) -- 序列完整，保留
            end
            return s:sub(1, len - 1) -- 尾部序列不完整，去掉起始字节
        end
        cont = cont + 1
        len = len - 1
    end
    return ""
end

--- 从释义中随机取一个「词性 + 单个中文意思」；无可用词性行返回 nil
local function pick_pos_meaning(word)
    local t = word_trans[word]
    if not t or t == "" then return nil end
    local pos_lines = {}
    for line in (t .. "\n"):gmatch("(.-)\n") do
        local pos, rest = line:match("^([a-z]+)%.%s*(.+)$")
        if pos and rest ~= "" then
            pos_lines[#pos_lines + 1] = { pos = pos, rest = rest }
        end
    end
    if #pos_lines == 0 then return nil end
    local pick = pos_lines[math.random(#pos_lines)]
    local meaning = truncate_tail_utf8(first_meaning(pick.rest))
    meaning = meaning:gsub("^%s+", ""):gsub("%s+$", "")
    if meaning == "" then
        -- rest 以分隔符开头时回退为整行释义
        meaning = truncate_tail_utf8(pick.rest):gsub("^%s+", ""):gsub("%s+$", "")
    end
    return POS_NAMES[pick.pos] or pick.pos, meaning
end

--- 失败时的安慰语
local function get_defeat_msg(word)
    local msgs = {
        "😢 次数用完啦～答案是 " .. word .. "，下次一定能猜出来的！",
        "💨 揭晓答案：" .. word .. "！没关系，再来一局？",
        "🤗 差一点就对啦～答案是 " .. word .. "，要不要再玩一次？",
    }
    return msgs[math.random(#msgs)]
end

--- emoji 兜底反馈（T2I 不可用时）
local function emoji_feedback(states)
    return states:gsub("G", "🟩"):gsub("Y", "🟨"):gsub("X", "⬜")
end

--- emoji 版猜测记录（T2I 兜底）
local function format_history_emoji(game)
    local lines = {}
    for i, att in ipairs(game.attempts) do
        lines[#lines + 1] = "第" .. i .. "次：" .. emoji_feedback(att.states) .. "  " .. att.guess
    end
    return table.concat(lines, "\n")
end

--- 回复纯文本
local function reply(event, text)
    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, text)
    else
        jn.onebot11.send_private_msg(event.user_id, text)
    end
end

local render_board -- 前向声明（reply_with_board 中使用）

--- 回复文本 + 棋盘图片；T2I 不可用时降级为 emoji 文本
local function reply_with_board(event, text, game)
    local url = nil
    if jn.t2i.is_active() then
        url = render_board(game)
    end
    if not url then
        local lines = { text }
        if game and game.attempts and #game.attempts > 0 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = format_history_emoji(game)
        end
        text = table.concat(lines, "\n")
    end
    local segments = { { type = "text", data = { text = text } } }
    if url then
        segments[#segments + 1] = { type = "image", data = { file = url } }
    end
    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, segments)
    else
        jn.onebot11.send_private_msg(event.user_id, segments)
    end
end

-- ====================================================================
-- 棋盘渲染（HTML → T2I PNG + Redis 缓存）
-- ====================================================================

local FONT_B64
local TEMPLATE

--- 读取并缓存字体 base64（去掉 base64:// 前缀，供 data URI 使用）
local function get_font_b64()
    if FONT_B64 == nil then
        local b64, err = jn.onebot11.read_file_base64("PoetsenOne-Regular.ttf")
        if b64 then
            FONT_B64 = b64:gsub("^base64://", "")
        else
            jn.log.error("[caidanci_grade] 读取字体失败: " .. (err or "unknown"))
            FONT_B64 = ""
        end
    end
    return FONT_B64
end

--- 读取并缓存棋盘模板
local function get_template()
    if TEMPLATE == nil then
        local content, err = jn.file.read("board_template.html")
        if content then
            TEMPLATE = content
        else
            jn.log.error("[caidanci_grade] 读取棋盘模板失败: " .. (err or "unknown"))
            TEMPLATE = false
        end
    end
    return TEMPLATE
end

local function tile_class(state)
    if state == "G" then
        return "green"
    elseif state == "Y" then
        return "yellow"
    else
        return "grey"
    end
end

--- 生成棋盘逐行 HTML（max_attempts 行 × length 列）
--- 提示（词性/字母）只发文字，不渲染进棋盘
local function build_rows_html(game)
    local n = game.length
    local parts = {}
    -- 当前轮次：最近一次输入的那一行（开局尚无输入时高亮第 1 行）
    local current_row = #game.attempts
    if current_row == 0 then current_row = 1 end
    for r = 1, game.max_attempts do
        local row = {}
        local att = game.attempts[r]
        for i = 1, n do
            local cls
            local content = ""
            if att then
                cls = "tile " .. tile_class(string.sub(att.states, i, i))
                content = string.upper(string.sub(att.guess, i, i))
            else
                cls = "tile empty"
            end
            if r == current_row then cls = cls .. " current" end
            row[#row + 1] = '<div class="' .. cls .. '">' .. content .. "</div>"
        end
        parts[#parts + 1] = table.concat(row, "")
    end
    return table.concat(parts, "")
end

--- 棋盘状态缓存 key（与群无关，相同局面共享渲染；提示只发文字，不影响棋盘）
local function board_cache_key(game)
    local parts = { tostring(game.length), tostring(#game.attempts) }
    for _, att in ipairs(game.attempts) do
        parts[#parts + 1] = att.guess .. ":" .. att.states
    end
    return "board:" .. table.concat(parts, "|")
end

--- 渲染棋盘并返回图片 URL；失败返回 nil
render_board = function(game)
    if not jn.t2i.is_active() then return nil end
    local key = board_cache_key(game)
    local cached = jn.cache.get(key)
    if cached and cached.url then return cached.url end
    local template = get_template()
    if not template then return nil end
    local w, h = board_size(game.length, game.max_attempts)
    local html = template
        :gsub("__FONT_B64__", function() return get_font_b64() end)
        :gsub("__LEN__", function() return tostring(game.length) end)
        :gsub("__ROWS__", function() return tostring(game.max_attempts) end)
        :gsub("__WIDTH__", tostring(w))
        :gsub("__ROWS_HTML__", function() return build_rows_html(game) end)
    local url, err = jn.t2i.generate_url(html, {
        viewport_width = w,
        viewport_height = h,
        full_page = false,
    })
    if not url then
        jn.log.error("[caidanci_grade] 棋盘渲染失败: " .. (err or "unknown"))
        return nil
    end
    jn.cache.set(key, { url = url }, BOARD_CACHE_TTL)
    return url
end

-- ====================================================================
-- 帮助菜单
-- ====================================================================

local HELP_MENU = table.concat({
    "- /猜 — 提交猜单词的猜测",
    "- /猜单词 — 玩一局猜单词游戏（Wordle）",
    "- /猜单词 <难度> — 指定难度高考/四级/六级/考研/雅思/托福/GRE",
    "- /猜单词 <长度> — 指定单词长度",
    "- /怎么猜单词 — 查看玩法与指定难度/长度的方法",
}, "\n")

local function is_help_arg(arg)
    local a = tostring(arg):lower()
    return a == "help" or a == "帮助" or a == "菜单"
end

local function has_help_arg(args)
    for _, arg in ipairs(args) do
        if is_help_arg(arg) then return true end
    end
    return false
end

--- 解析开局参数，返回 {diff=key, len=n}；非法返回错误信息字符串
local function parse_start_args(args)
    local diff, len
    for _, arg in ipairs(args) do
        local a = tostring(arg):lower()
        local n = tonumber(a)
        if n then
            if n ~= math.floor(n) then return nil, "单词长度必须是整数" end
            if len then return nil, "长度参数重复指定了" end
            len = n
        else
            local k = ALIASES[a]
            if k then
                if diff then return nil, "难度参数重复指定了" end
                diff = k
            else
                return nil, "无法识别的参数：" .. arg
            end
        end
    end
    return { diff = diff, len = len }
end

--- 选择提示位置：最近一次猜测中猜错且未揭示的位置里随机；
--- 若全部猜对/已揭示，则在未揭示位置中随机
local function pick_hint_position(game)
    local n = game.length
    local hinted = {}
    for _, h in ipairs(game.hints or {}) do
        hinted[h.pos] = true
    end
    local candidates = {}
    local att = game.attempts[#game.attempts]
    if att then
        for i = 1, n do
            if not hinted[i] and string.sub(att.guess, i, i) ~= string.sub(game.word, i, i) then
                candidates[#candidates + 1] = i
            end
        end
    end
    if #candidates == 0 then
        for i = 1, n do
            if not hinted[i] then candidates[#candidates + 1] = i end
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(#candidates)]
end

-- ====================================================================
-- 命令: /猜单词 —— 启动游戏
-- ====================================================================
jn.command.register("猜单词", function(args, event)
    -- 仅群聊可用
    if event.message_type ~= "group" then
        reply(event, "猜单词游戏仅在群聊中可用哦～")
        return true
    end

    if has_help_arg(args) then
        reply(event, HELP_MENU)
        return true
    end

    local group_id = event.group_id

    -- 检查是否已有进行中的游戏
    local existing = get_game(group_id)
    if existing and existing.status == "playing" then
        reply(event, "本群已有进行中的猜单词游戏啦！\n发送 /结束 可以结束当前游戏。")
        return true
    end

    -- 解析参数（难度/长度顺序任意）
    local parsed, err = parse_start_args(args)
    if not parsed then
        reply(event, err)
        return true
    end

    local diff = parsed.diff or DEFAULT_DIFF
    local length = parsed.len
    if not length then
        length = math.random(DEFAULT_LEN_MIN, DEFAULT_LEN_MAX)
    elseif length < MIN_LENGTH or length > MAX_LENGTH then
        reply(event, "单词长度只支持 " .. MIN_LENGTH .. "～" .. MAX_LENGTH .. "，未指定时默认 " .. DEFAULT_LEN_MIN .. "-" .. DEFAULT_LEN_MAX .. " 随机")
        return true
    end

    -- 选词
    local word = pick_word(diff, length)
    if not word then
        reply(event, "该难度词库中暂时没有 " .. length .. " 字母的单词，换个长度试试～")
        return true
    end

    -- 创建游戏状态
    local game = {
        word = word,
        difficulty = diff,
        difficulty_name = diff_name(diff),
        length = length,
        max_attempts = MAX_ATTEMPTS,
        attempts = {},
        hints = {},
        status = "playing",
    }
    save_game(group_id, game)

    local lines = {
        "🎮 猜单词游戏开始！",
        "难度：" .. game.difficulty_name,
        "单词长度：" .. length .. " 个字母",
        "最多 " .. MAX_ATTEMPTS .. " 次机会",
        "本局只能提示一次，请谨慎使用～",
        "",
    }
    -- 开局给出一张空白棋盘（全部为空表格）；T2I 不可用/渲染失败时降级为下划线占位
    local board_url = nil
    if jn.t2i.is_active() then
        board_url = render_board(game)
    end
    if not board_url then
        local placeholders = {}
        for _ = 1, length do
            placeholders[#placeholders + 1] = "_"
        end
        lines[#lines + 1] = table.concat(placeholders, " ")
        lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "发送 /提示 获取帮助 ｜ /结束 退出游戏"

    local segments = { { type = "text", data = { text = table.concat(lines, "\n") } } }
    if board_url then
        segments[#segments + 1] = { type = "image", data = { file = board_url } }
    end
    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, segments)
    else
        jn.onebot11.send_private_msg(event.user_id, segments)
    end
    return true
end, {
    description = "玩一局猜单词游戏（Wordle）",
    usage = "/猜单词 [难度] [长度]（顺序任意）\n难度：高考/四级/六级/考研/雅思/托福/GRE（默认四级）\n长度：单词字母数（默认 4-6 随机）",
})

-- ====================================================================
-- 命令: /怎么猜单词 —— 玩法与指定难度/长度的方法
-- ====================================================================
local HOW_TO_PLAY = table.concat({
    "🎮 猜单词（Wordle）玩法：",
    "每局随机一个英文单词，最多 " .. MAX_ATTEMPTS .. " 次机会猜出来。",
    "发送 /猜 <单词> 提交猜测，格子颜色表示：",
    "🟩 位置和字母都对；🟨 字母对但位置不对；⬜ 单词里没有这个字母",
    "",
    "开始一局：/猜单词（默认四级，长度 " .. DEFAULT_LEN_MIN .. "-" .. DEFAULT_LEN_MAX .. " 随机）",
    "指定难度：/猜单词 六级（高考/四级/六级/考研/雅思/托福/GRE）",
    "指定长度：/猜单词 6（4～" .. MAX_LENGTH .. " 个字母）",
    "同时指定：/猜单词 六级 6（顺序任意）",
    "",
    "/提示 每局仅一次：揭示一个字母或给出词性与中文意思，/结束 查看答案。",
}, "\n")

jn.command.register("怎么猜单词", function(args, event)
    if event.message_type ~= "group" then
        reply(event, "猜单词游戏仅在群聊中可用哦～")
        return true
    end
    reply(event, HOW_TO_PLAY)
    return true
end, {
    description = "查看猜单词玩法与指定难度/长度的方法",
    usage = "/怎么猜单词",
})

-- ====================================================================
-- 命令: /结束 —— 结束游戏
-- ====================================================================
jn.command.register("结束", function(args, event)
    -- 仅群聊可用
    if event.message_type ~= "group" then return true end
    local group_id = event.group_id

    local game = get_game(group_id)
    if not game then
        reply(event, "本群还没有进行中的游戏哦～发送 /猜单词 来一局吧！")
        return true
    end

    delete_game(group_id)

    local text = "游戏已结束！答案是：" .. game.word
    text = append_meaning(text, game.word) .. "\n\n发送 /猜单词 可以再来一局～"
    reply_with_board(event, text, game)
    return true
end, {
    description = "结束当前猜单词游戏",
    usage = "/结束",
})

-- ====================================================================
-- 命令: /提示 —— 获取提示（揭示一个猜错位置的正确字母）
-- ====================================================================
jn.command.register("提示", function(args, event)
    -- 仅群聊可用
    if event.message_type ~= "group" then return true end
    local group_id = event.group_id

    local game = get_game(group_id)
    if not game or game.status ~= "playing" then
        reply(event, "本群还没有进行中的游戏哦～发送 /猜单词 来一局吧！")
        return true
    end

    -- 每局只能提示一次
    if game.hint_used or (game.hints and #game.hints >= 1) then
        reply(event, "本局只能提示一次哦～提示已经用掉啦，卷娘相信大家能猜出来的💪")
        return true
    end

    -- 30% 概率给出词性与一个中文意思，否则在棋盘上揭示一个正确字母
    if math.random() < 0.3 then
        local pos_name, meaning = pick_pos_meaning(game.word)
        if pos_name then
            game.hint_used = true
            save_game(group_id, game)
            reply(event, "💡 提示：词性是" .. pos_name .. "，一个意思是「" .. meaning .. "」")
            return true
        end
    end

    local pos = pick_hint_position(game)
    if not pos then
        reply(event, "提示已经给完啦！卷娘相信大家能猜出来的💪")
        return true
    end

    local letter = string.sub(game.word, pos, pos)
    game.hints[#game.hints + 1] = { pos = pos, letter = letter }
    save_game(group_id, game)

    -- 字母提示只发文字：渲染进棋盘会随轮次移动到最近一行，与猜测字母混淆，
    -- 用户无法判断单词中该字母的真实数量（如两个 T 时只提示出一个 T）
    reply(event, "💡 提示：第 " .. pos .. " 位是 " .. string.upper(letter))
    return true
end, {
    description = "查看当前猜单词游戏的提示",
    usage = "/提示",
})

-- ====================================================================
-- on_message: 引导触发
-- ====================================================================
function on_message(event)
    -- 仅群聊可用
    if event.message_type ~= "group" then return false, nil end

    local raw = (event.raw_message or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return false, nil end

    -- 引导触发开关
    local enable_trigger = jn.config.get("enable_trigger") ~= false
    if not enable_trigger then return false, nil end

    -- 没有游戏时：检查引导触发词
    if not get_game(event.group_id) then
        local triggers = { "没意思", "没劲", "有啥好玩", "有什么好玩", "好玩的", "玩什么" }
        for _, kw in ipairs(triggers) do
            if raw:find(kw, 1, true) then
                reply(event, "来玩猜单词呀！@卷娘 /猜单词 就能开局～\n看看你能用几次猜出正确答案 🤔")
                return true
            end
        end
    end

    return false, nil
end

-- ====================================================================
-- 命令: /猜 —— 提交猜测
-- ====================================================================
jn.command.register("猜", function(args, event)
    -- 仅群聊可用
    if event.message_type ~= "group" then return true end
    local group_id = event.group_id

    local game = get_game(group_id)
    if not game or game.status ~= "playing" then
        reply(event, "本群还没有进行中的游戏哦～发送 /猜单词 来一局吧！")
        return true
    end

    if #args == 0 then
        reply(event, "请输入要猜的单词，例如：/猜 apple")
        return true
    end

    local guess = args[1]:lower()

    -- 长度检查
    if #guess ~= game.length then
        reply(event, "单词长度不对哦～当前单词有 " .. game.length .. " 个字母")
        return true
    end

    -- 纯字母检查
    if not guess:match("^[a-z]+$") then
        reply(event, "请输入纯英文字母的单词～")
        return true
    end

    -- 词典校验：不在全部词库并集中的词
    if not union_words[guess] then
        reply(event, "你确定 " .. guess .. " 是一个单词吗")
        return true
    end

    -- 检查是否已猜过
    for _, att in ipairs(game.attempts) do
        if att.guess == guess then
            reply(event, "这个单词已经猜过啦～换一个试试吧！")
            return true
        end
    end

    local states = compare_guess(guess, game.word)
    local attempt_num = #game.attempts + 1
    game.attempts[#game.attempts + 1] = { guess = guess, states = states }

    -- 猜对了
    if guess == game.word then
        game.status = "won"
        save_game(group_id, game)
        reply_with_board(event, append_meaning(get_victory_msg(game.word, attempt_num), game.word), game)
        return true
    end

    -- 次数用完了
    if #game.attempts >= game.max_attempts then
        game.status = "lost"
        save_game(group_id, game)
        reply_with_board(event, append_meaning(get_defeat_msg(game.word), game.word), game)
        return true
    end

    -- 还没结束
    save_game(group_id, game)

    -- 提示已用（词性/意思或字母揭示）后不再引导 /提示
    local hint_used = game.hint_used or (game.hints and #game.hints >= 1)
    local encouragement = get_encouragement(attempt_num, game.max_attempts, states, hint_used)
    local remaining = game.max_attempts - #game.attempts
    local lines = { encouragement }
    if remaining <= 3 then
        if hint_used then
            lines[#lines + 1] = "（剩余 " .. remaining .. " 次）"
        else
            lines[#lines + 1] = "（剩余 " .. remaining .. " 次，发送 /提示 获取帮助）"
        end
    end
    reply_with_board(event, table.concat(lines, "\n"), game)
    return true
end, {
    description = "提交猜单词的猜测",
    usage = "/猜 <单词>",
})

jn.log.info("[redrock_caidanci_grade] 分级猜单词插件已加载")
