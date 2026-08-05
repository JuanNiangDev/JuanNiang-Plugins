-- ====================================================================
-- redrock_caidanci
-- 红岩网校猜单词小游戏 (Wordle)
-- 使用 Redis 缓存存储游戏状态
-- ====================================================================

local jn = require("jn")

-- ====================================================================
-- 单词库
-- ====================================================================
local word_pool = {
    -- 5 字母 (默认)
    { word = "apple",  category = "水果",     clue = "一种红色/绿色的水果，乔布斯用它命名了公司" },
    { word = "linux",  category = "技术",     clue = "开源操作系统，红岩服务器上跑的就是它" },
    { word = "debug",  category = "技术",     clue = "程序员每天都在干的事：找 bug 修 bug" },
    { word = "stack",  category = "技术",     clue = "数据结构中的'栈'，也指全栈开发的那个栈" },
    { word = "cache",  category = "技术",     clue = "缓存，让系统跑得更快的小助手" },
    { word = "proxy",  category = "技术",     clue = "代理服务器，翻墙必备" },
    { word = "route",  category = "技术",     clue = "路由，决定数据包该往哪走" },
    { word = "query",  category = "技术",     clue = "数据库查询，SQL 的 Q 就是这个" },
    { word = "token",  category = "技术",     clue = "令牌，登录认证就靠它" },
    { word = "patch",  category = "技术",     clue = "补丁，修 bug 的小更新包" },
    { word = "merge",  category = "技术",     clue = "合并代码，Git 操作中最让人紧张的环节" },
    { word = "shell",  category = "技术",     clue = "命令行界面，终端里黑色的那个窗口" },
    { word = "scale",  category = "技术",     clue = "扩展/伸缩，服务器扛不住了就加机器" },
    { word = "build",  category = "技术",     clue = "构建/编译，写完代码后的第一步" },
    { word = "logic",  category = "技术",     clue = "逻辑，写代码离不开的基本功" },
    { word = "array",  category = "技术",     clue = "数组，最基础的数据结构之一" },
    { word = "class",  category = "技术",     clue = "面向对象编程的核心：类" },
    { word = "value",  category = "技术",     clue = "变量里的那个'值'" },
    { word = "cloud",  category = "技术",     clue = "云，服务器不在本地就在这上面" },
    { word = "spark",  category = "技术",     clue = "大数据计算框架，也是 Apache 的顶级项目" },
    { word = "react",  category = "技术",     clue = "前端最火的框架之一，Facebook 出品" },
    { word = "skill",  category = "通用",     clue = "技能，红岩教你各种新技能" },
    { word = "learn",  category = "校园",     clue = "学习，来红岩就是要学东西的" },
    { word = "group",  category = "校园",     clue = "群组，你现在就在群里聊天呢" },
    { word = "start",  category = "通用",     clue = "开始，万事开头难，但开始了就好" },
    { word = "focus",  category = "通用",     clue = "专注，写代码时最需要保持的状态" },
    { word = "error",  category = "技术",     clue = "程序出错了！红色的报错信息" },
    { word = "frame",  category = "技术",     clue = "框架，比如 Spring、Django、Vue" },
    { word = "level",  category = "通用",     clue = "等级/水平，祝你在红岩不断提升" },
    { word = "share",  category = "通用",     clue = "分享，好知识要一起分享" },
    { word = "guide",  category = "通用",     clue = "指南/引导，学长学姐给你指路" },
    { word = "match",  category = "通用",     clue = "匹配，找个合适的队友一起做项目" },

    -- 4 字母
    { word = "code",  category = "技术",     clue = "代码，程序员的日常" },
    { word = "node",  category = "技术",     clue = "Node.js，JavaScript 的后端运行时" },
    { word = "push",  category = "技术",     clue = "Git push，把代码推送到远程仓库" },
    { word = "pull",  category = "技术",     clue = "Git pull，拉取最新代码" },
    { word = "json",  category = "技术",     clue = "最常用的数据交换格式" },
    { word = "html",  category = "技术",     clue = "网页的基础标记语言" },
    { word = "sync",  category = "技术",     clue = "同步，async/await 的那个 sync" },
    { word = "disc",  category = "技术",     clue = "Discord，国外程序员常用的交流工具" },
    { word = "chat",  category = "通用",     clue = "聊天，就像你们现在在做的事" },
    { word = "ping",  category = "技术",     clue = "检测网络连通性，pong!" },
    { word = "team",  category = "校园",     clue = "团队，红岩每个组都是一个团队" },
    { word = "club",  category = "校园",     clue = "社团，红岩网校就是一个技术社团" },
    { word = "plan",  category = "通用",     clue = "计划，做项目前要先规划好" },
    { word = "play",  category = "通用",     clue = "玩/播放，学累了就放松一下" },
    { word = "link",  category = "技术",     clue = "链接，网页之间就靠它跳转" },
    { word = "test",  category = "技术",     clue = "测试，写完代码别忘了测一测" },
    { word = "task",  category = "通用",     clue = "任务，Todo List 上的待办事项" },

    -- 6 字母
    { word = "python",  category = "技术", clue = "最流行的编程语言之一，语法简洁优雅" },
    { word = "docker",  category = "技术", clue = "容器化技术，一次打包到处运行" },
    { word = "server",  category = "技术", clue = "服务器，后台服务就运行在这上面" },
    { word = "design",  category = "技术", clue = "设计，好看的界面靠的就是它" },
    { word = "commit",  category = "技术", clue = "Git commit，保存代码快照" },
    { word = "branch",  category = "技术", clue = "Git 分支，多人协作的基础" },
    { word = "deploy",  category = "技术", clue = "部署，把代码发布到服务器上" },
    { word = "import",  category = "技术", clue = "导入，引用别的模块或库" },
    { word = "export",  category = "技术", clue = "导出，把数据/函数暴露出去" },
    { word = "script",  category = "技术", clue = "脚本，自动化任务的利器" },
    { word = "format",  category = "技术", clue = "格式化，让代码看起来整齐划一" },
    { word = "campus",  category = "校园", clue = "校园，你正在度过青春的地方" },
    { word = "studio",  category = "校园", clue = "工作室，红岩是一个很棒的工作室" },
    { word = "online",  category = "通用", clue = "在线，现在大多数事情都在线上做" },
    { word = "commit",  category = "技术", clue = "提交，Git 版本控制的关键操作" },
    { word = "review",  category = "技术", clue = "代码审查，合并前让同事帮忙看看" },
    { word = "search",  category = "技术", clue = "搜索，程序员最常用的技能之一" },
}

-- ====================================================================
-- 常量（可在 Web 面板配置中调整）
-- ====================================================================
local DEFAULT_LENGTH = tonumber(jn.config.get("default_length")) or 5
local MAX_ATTEMPTS = tonumber(jn.config.get("max_attempts")) or 6

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
        jn.log.error("[caidanci] 保存游戏状态失败: " .. (err or "unknown"))
    end
end

--- 删除游戏状态
local function delete_game(group_id)
    jn.cache.del(cache_key(group_id))
end

--- 从指定长度的单词中随机选一个
local function pick_word(length)
    local candidates = {}
    for _, entry in ipairs(word_pool) do
        if #entry.word == length then
            candidates[#candidates + 1] = entry
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(#candidates)]
end

--- 比较猜测和目标单词，返回反馈符号串
--- 参考 Wordle 规则：先标记绿色，再标记黄色，最后灰色
local function compare_guess(guess, target)
    local n = #target
    local result = {}
    local used = {}  -- 目标单词中已被匹配的位置

    for i = 1, n do
        result[i] = nil
        used[i] = false
    end

    -- 第一遍：绿色 (位置正确)
    for i = 1, n do
        if string.sub(guess, i, i) == string.sub(target, i, i) then
            result[i] = "🟩"
            used[i] = true
        end
    end

    -- 第二遍：黄色 (字母存在但位置不对)
    for i = 1, n do
        if result[i] == nil then
            local ch = string.sub(guess, i, i)
            for j = 1, n do
                if not used[j] and string.sub(target, j, j) == ch then
                    result[i] = "🟨"
                    used[j] = true
                    break
                end
            end
        end
    end

    -- 第三遍：灰色
    for i = 1, n do
        if result[i] == nil then
            result[i] = "⬜"
        end
    end

    return table.concat(result, "")
end

--- 获取第 N 次猜测的鼓励语
local function get_encouragement(attempt_num, max_attempts, feedback)
    local green_count = 0
    for _ in string.gmatch(feedback, "🟩") do
        green_count = green_count + 1
    end

    -- 第一条鼓励语根据绿色数量
    if green_count >= 3 then
        local cheers = { "超对！就这样继续～💪", "很棒！大部分都对了！", "卷娘觉得你离答案越来越近了！", "厉害呀，方向完全正确！" }
        return cheers[math.random(#cheers)]
    elseif green_count >= 1 then
        local cheers = { "有好几个字母对了！加油～", "开头不错，再想想后面的～", "方向是对的，继续尝试！", "很不错，再调整一下就好！" }
        return cheers[math.random(#cheers)]
    end

    -- 根据剩余次数给出不同风格的鼓励
    local remaining = max_attempts - attempt_num
    if remaining <= 1 then
        return "最后一次机会啦！卷娘相信你一定能猜出来✨"
    elseif remaining <= 2 then
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

--- 失败时的安慰语
local function get_defeat_msg(word)
    local msgs = {
        "😢 次数用完啦～答案是 " .. word .. "，下次一定能猜出来的！",
        "💨 揭晓答案：" .. word .. "！没关系，再来一局？",
        "🤗 差一点就对啦～答案是 " .. word .. "，要不要再玩一次？",
    }
    return msgs[math.random(#msgs)]
end

--- 格式化游戏历史记录
local function format_history(game)
    local lines = {}
    for i, att in ipairs(game.attempts) do
        lines[#lines + 1] = "第" .. i .. "次：" .. att.feedback .. "  " .. att.guess
    end
    return table.concat(lines, "\n")
end

--- 格式化提示信息
local function format_hint(game)
    local word = game.word_info
    local hint_num = game.hints_given + 1
    local total_hints = 4

    if hint_num == 1 then
        return "🧩 提示 " .. hint_num .. "/" .. total_hints .. "：" .. word.category .. "类单词"
    elseif hint_num == 2 then
        return "🔤 提示 " .. hint_num .. "/" .. total_hints .. "：首字母是 " .. string.upper(string.sub(word.word, 1, 1))
    elseif hint_num == 3 then
        return "🔤 提示 " .. hint_num .. "/" .. total_hints .. "：尾字母是 " .. string.upper(string.sub(word.word, -1))
    else
        return "💡 提示 " .. hint_num .. "/" .. total_hints .. "：" .. word.clue
    end
end

--- 回复消息
local function reply(event, text)
    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, text)
    else
        jn.onebot11.send_private_msg(event.user_id, text)
    end
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
    local group_id = event.group_id

    -- 检查是否已有进行中的游戏
    local existing = get_game(group_id)
    if existing and existing.status == "playing" then
        reply(event, "本群已有进行中的猜单词游戏啦！\n发送 /结束 可以结束当前游戏。")
        return true
    end

    -- 解析参数
    local word_length = DEFAULT_LENGTH
    for i, arg in ipairs(args) do
        if (arg == "-l" or arg == "--length") and args[i + 1] then
            local n = tonumber(args[i + 1])
            if n and n >= 4 and n <= 6 then
                word_length = n
            else
                reply(event, "单词长度只支持 4、5、6，默认使用 5")
                return true
            end
        end
    end

    -- 选词
    local word_entry = pick_word(word_length)
    if not word_entry then
        reply(event, "抱歉，单词库中暂时没有 " .. word_length .. " 字母的单词，请用默认长度试试～")
        return true
    end

    -- 创建游戏状态
    local game = {
        word = word_entry.word,
        word_info = word_entry,
        length = word_length,
        max_attempts = MAX_ATTEMPTS,
        attempts = {},
        hints_given = 0,
        status = "playing",
    }
    save_game(group_id, game)

    local lines = {
        "🎮 猜单词游戏开始！",
        "单词长度：" .. word_length .. " 个字母 ｜ 最多 " .. MAX_ATTEMPTS .. " 次机会",
        "",
    }
    -- 给出字母位置占位符
    local placeholders = {}
    for _ = 1, word_length do
        placeholders[#placeholders + 1] = "_"
    end
    lines[#lines + 1] = table.concat(placeholders, " ")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "🟩 字母正确且位置正确"
    lines[#lines + 1] = "🟨 字母正确但位置不对"
    lines[#lines + 1] = "⬜ 没有这个字母"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "发送 /提示 获取帮助 ｜ /结束 退出游戏"

    reply(event, table.concat(lines, "\n"))
    return true
end, {
    description = "玩一局猜单词游戏（Wordle）",
    usage = "/猜单词 [-l 长度]",
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

    local lines = {"游戏已结束！答案是：" .. game.word}
    if #game.attempts > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "你的猜测记录："
        lines[#lines + 1] = format_history(game)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "发送 /猜单词 可以再来一局～"

    reply(event, table.concat(lines, "\n"))
    return true
end, {
    description = "结束当前猜单词游戏",
    usage = "/结束",
})

-- ====================================================================
-- 命令: /提示 —— 获取提示
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

    if game.hints_given >= 4 then
        reply(event, "提示已经给完了！卷娘相信大家能猜出来的💪\n目前进度：\n" .. format_history(game))
        return true
    end

    game.hints_given = game.hints_given + 1
    save_game(group_id, game)

    local hint = format_hint(game)
    reply(event, hint)
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

    -- 检查是否已猜过
    for _, att in ipairs(game.attempts) do
        if att.guess == guess then
            reply(event, "这个单词已经猜过啦～换一个试试吧！")
            return true
        end
    end

    local feedback = compare_guess(guess, game.word)
    local attempt_num = #game.attempts + 1
    game.attempts[#game.attempts + 1] = { guess = guess, feedback = feedback }

    -- 猜对了
    if guess == game.word then
        game.status = "won"
        save_game(group_id, game)

        local lines = {
            get_victory_msg(game.word, attempt_num),
            "",
            format_history(game),
            "",
            "发送 /猜单词 再来一局～",
        }
        reply(event, table.concat(lines, "\n"))
        return true
    end

    -- 次数用完了
    if #game.attempts >= game.max_attempts then
        game.status = "lost"
        save_game(group_id, game)

        local lines = {
            get_defeat_msg(game.word),
            "",
            format_history(game),
            "",
            "发送 /猜单词 再来一局～",
        }
        reply(event, table.concat(lines, "\n"))
        return true
    end

    -- 还没结束
    save_game(group_id, game)

    local encouragement = get_encouragement(attempt_num, game.max_attempts, feedback)
    local remaining = game.max_attempts - #game.attempts
    local lines = {
        "第 " .. attempt_num .. " 次猜测：" .. feedback,
        encouragement,
    }
    if game.hints_given < 4 and remaining <= 3 then
        lines[#lines + 1] = "（剩余 " .. remaining .. " 次，发送 /提示 获取帮助）"
    end
    reply(event, table.concat(lines, "\n"))
    return true
end, {
    description = "提交猜单词的猜测",
    usage = "/猜 <单词>",
})

jn.log.info("[redrock_caidanci] 猜单词插件已加载")
