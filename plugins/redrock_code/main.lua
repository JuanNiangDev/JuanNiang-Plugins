-- ====================================================================
-- redrock_code
-- 基于 Judge0 的在线代码运行插件
-- 用法: /code <语言> [输入...]
--       代码内容
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- 配置：Judge0 地址（无鉴权）
-- ====================================================================
local JUDGE0_BASE_URL = "http://2.2.2.1:2358"

-- ====================================================================
-- 语言 → Judge0 language_id 映射
-- ====================================================================
local language_map = {
    py = 71, python = 71, python3 = 71,
    php = 68,
    java = 62,
    cpp = 54, ["c++"] = 54,
    js = 63, javascript = 63, node = 63, nodejs = 63,
    csharp = 51, cs = 51, ["c#"] = 51,
    c = 50,
    go = 60, golang = 60,
    asm = 45, assembly = 45,
    ats = 97,
    bash = 46, sh = 46,
    lisp = 55, clisp = 55, commonlisp = 55,
    clojure = 86,
    cobol = 77,
    coffeescript = 59,
    crystal = 90,
    d = 56,
    elixir = 57,
    elm = 58,          -- 若实例不支持需自行调整
    erlang = 61,
    fsharp = 87, ["f#"] = 87,
    groovy = 88,
    guide = 99,        -- 若实例不支持需自行调整
    hare = 100,        -- 若实例不支持需自行调整
    haskell = 89,
    idris = 101,       -- 若实例不支持需自行调整
    julia = 93,
    kotlin = 78,
    lua = 64,
    mercury = 102,     -- 若实例不支持需自行调整
    nim = 79,
    nix = 103,         -- 若实例不支持需自行调整
    ocaml = 65,
    pascal = 67,
    perl = 85,
    raku = 96,
    ruby = 72,
    rust = 73,
    sac = 104,         -- 若实例不支持需自行调整
    scala = 81,
    swift = 83,
    typescript = 74, ts = 74,
    zig = 98,
    plaintext = 43, text = 43, txt = 43,
}

-- 语言名 → 显示名
local language_names = {
    py = "Python 3", python = "Python 3", python3 = "Python 3",
    php = "PHP",
    java = "Java",
    cpp = "C++", ["c++"] = "C++",
    js = "JavaScript", javascript = "JavaScript", node = "JavaScript (Node.js)", nodejs = "JavaScript (Node.js)",
    csharp = "C#", cs = "C#", ["c#"] = "C#",
    c = "C",
    go = "Go", golang = "Go",
    asm = "Assembly", assembly = "Assembly",
    ats = "ATS",
    bash = "Bash", sh = "Bash",
    lisp = "Common Lisp", clisp = "Common Lisp", commonlisp = "Common Lisp",
    clojure = "Clojure",
    cobol = "COBOL",
    coffeescript = "CoffeeScript",
    crystal = "Crystal",
    d = "D",
    elixir = "Elixir",
    elm = "Elm",
    erlang = "Erlang",
    fsharp = "F#", ["f#"] = "F#",
    groovy = "Groovy",
    guide = "Guide",
    hare = "Hare",
    haskell = "Haskell",
    idris = "Idris",
    julia = "Julia",
    kotlin = "Kotlin",
    lua = "Lua",
    mercury = "Mercury",
    nim = "Nim",
    nix = "Nix",
    ocaml = "OCaml",
    pascal = "Pascal",
    perl = "Perl",
    raku = "Raku",
    ruby = "Ruby",
    rust = "Rust",
    sac = "SAC",
    scala = "Scala",
    swift = "Swift",
    typescript = "TypeScript", ts = "TypeScript",
    zig = "Zig",
    plaintext = "Plain Text", text = "Plain Text", txt = "Plain Text",
}

-- ====================================================================
-- 辅助函数
-- ====================================================================

--- 从 raw_message 中提取代码（取第一行换行之后的内容）
local function extract_code(raw_message)
    local pos = raw_message:find("\n")
    if pos then
        return raw_message:sub(pos + 1)
    end
    return nil
end

--- 发送带 example.png 的提示消息
local function reply_help(event, text)
    local segments = {
        { type = "text", data = { text = text .. "\n\n" } },
        { type = "image", data = { file = "example.png" } },
    }
    jn.onebot11.send_group_msg(event.group_id, segments)
end

--- 回复消息
local function reply(event, text)
    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, text)
    else
        jn.onebot11.send_private_msg(event.user_id, text)
    end
end

--- 截断过长的输出
local function truncate(str, max_len)
    max_len = max_len or 1500
    if #str > max_len then
        return str:sub(1, max_len) .. "\n... (输出过长已截断)"
    end
    return str
end

--- 发送代码到 Judge0 并获取结果
---@return table { ok=boolean, output=string, time=number, memory=number }
local function run_code(lang_id, code, stdin)
    local url = JUDGE0_BASE_URL .. "/submissions?base64_encoded=false&wait=true"

    local body = jn.json.encode({
        source_code = code,
        language_id = lang_id,
        stdin = stdin or "",
    })

    jn.log.info("[code] 提交代码: lang=" .. lang_id .. " len=" .. #code)

    local resp, err = jn.http.post(url, "application/json", body)
    if not resp then
        return { ok = false, output = "请求 Judge0 失败: " .. (err or "unknown") }
    end

    if resp.status < 200 or resp.status >= 300 then
        return { ok = false, output = "Judge0 返回错误状态: " .. resp.status }
    end

    local data = jn.json.decode(resp.body)
    if not data then
        return { ok = false, output = "解析 Judge0 响应失败" }
    end

    -- 拼接输出
    local output = ""
    local has_content = false

    -- 编译错误/运行时错误
    if data.compile_output and data.compile_output ~= "" then
        output = output .. data.compile_output
        has_content = true
    end

    if data.stderr and data.stderr ~= "" then
        if has_content then output = output .. "\n" end
        output = output .. data.stderr
        has_content = true
    end

    -- 标准输出
    if data.stdout and data.stdout ~= "" then
        if has_content then output = output .. "\n" end
        output = output .. data.stdout
        has_content = true
    end

    -- 超时等状态信息
    if not has_content and data.status then
        local desc = data.status.description or "未知状态"
        output = desc
    end

    return {
        ok = true,
        output = output,
        time = data.time,
        memory = data.memory,
    }
end

-- ====================================================================
-- 命令: /code <语言> [输入参数...]
--       代码
-- ====================================================================
jn.command.register("code", function(args, event)
    -- 仅群聊可用
    if event.message_type ~= "group" then
        reply(event, "代码运行仅在群聊中可用哦～")
        return true
    end

    if #args == 0 then
        reply_help(event, "请指定语言和代码。\n用法: /code <语言> [输入...]\n代码内容")
        return true
    end

    -- 解析语言
    local lang = args[1]:lower()
    local lang_id = language_map[lang]
    if not lang_id then
        local supported = {}
        local seen = {}
        for k, _ in pairs(language_map) do
            if #k <= 12 and not seen[k] then
                seen[k] = true
                supported[#supported + 1] = k
            end
        end
        table.sort(supported)
        reply(event, "不支持的语言: " .. lang .. "\n支持的语言: " .. table.concat(supported, ", "))
        return true
    end

    local lang_name = language_names[lang] or lang

    -- 解析输入（空格替换为换行）
    local stdin = nil
    if #args > 1 then
        local input_parts = {}
        for i = 2, #args do
            input_parts[#input_parts + 1] = args[i]
        end
        stdin = table.concat(input_parts, "\n")
    end

    -- 提取代码
    local code = extract_code(event.raw_message or "")
    if not code or code:match("^%s*$") then
        reply_help(event, "请提供代码内容！\n用法: /code " .. lang .. "\n代码...")
        return true
    end

    -- 执行
    local result = run_code(lang_id, code, stdin)

    -- 格式化输出
    local header = "🔧 " .. lang_name

    if not result.ok then
        header = header .. "\n\n" .. truncate(result.output)
        reply(event, header)
        return true
    end

    local output = truncate(result.output)
    if output == "" then output = "(无输出)" end

    -- 耗时和内存
    local meta_parts = {}
    local t = tonumber(result.time)
    if t then
        meta_parts[#meta_parts + 1] = string.format("%.2fs", t)
    end
    local m = tonumber(result.memory)
    if m and m > 0 then
        if m >= 1024 then
            meta_parts[#meta_parts + 1] = string.format("%.0fKB", m / 1024)
        else
            meta_parts[#meta_parts + 1] = string.format("%dB", m)
        end
    end

    local meta = ""
    if #meta_parts > 0 then
        meta = " | " .. table.concat(meta_parts, " ")
    end

    reply(event, header .. meta .. "\n\n" .. output)
    return true
end, {
    description = "运行代码（基于 Judge0）",
    usage = "/code <语言> [输入...]\n代码",
})

-- 当命令未被匹配时，不做任何事
function on_message(event)
    return false, nil
end

jn.log.info("[redrock_code] 代码运行插件已加载")
