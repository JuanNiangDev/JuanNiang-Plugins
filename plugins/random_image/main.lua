-- ====================================================================
-- random_image 随机图片插件
-- --------------------------------------------------------------------
-- 移植自 lanmei-dream 的随机图片玩法，图片来源改为本项目图床（jn.images）：
--   /随机图片              → 默认目录（config.default_folder）随机一张
--   /随机图片 <分类>       → 分类 → 图床目录（先查映射别名，未命中直接当目录名）
--   /随机<别名>            → 映射注册的自定义随机命令（如 /随机奶龙 /随机奶蛙）
-- 命中图片后发 [CQ:image,file=imgs://<图床id>]，发送层统一解析为 base64。
-- 映射在插件加载时注册为命令，改 config 后需重载插件。
-- ====================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

-- --------------------------------------------------------------------
-- 配置解析
-- --------------------------------------------------------------------
-- 解析 mappings 配置（"别名=目录" 列表）→ {alias → {folder,...}}
-- 目录部分支持逗号分隔多个（如 奶娃=表情包,艺术创作）；同一别名
-- 出现在多行时目录合并。容错：忽略空项、无 "="、目录全空的别名
local function parse_mappings()
    local m = jn.config.get("mappings")
    local out = {}
    if type(m) ~= "table" then return out end
    for _, item in ipairs(m) do
        local s = tostring(item or "")
        local alias, folders_part = s:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
        if alias and alias ~= "" and folders_part and folders_part ~= "" then
            local list = out[alias]
            if list == nil then
                list = {}
                out[alias] = list
            end
            folders_part = folders_part:gsub("，", ",") -- 全角逗号统一为半角（字节级替换，避免字符类截断多字节汉字）
            for folder in folders_part:gmatch("[^,]+") do
                folder = folder:match("^%s*(.-)%s*$")
                if folder ~= "" then
                    list[#list + 1] = folder
                end
            end
        end
    end
    return out
end

-- 分类 → 图床目录列表。未命中映射时直接把分类当目录名（目录名即分类）
local function resolve_folders(category)
    if category == nil or category == "" then
        local def = jn.config.get("default_folder")
        if def and def ~= "" then return { tostring(def) } end
        return nil
    end
    local mapped = parse_mappings()[category]
    if mapped and #mapped > 0 then return mapped end
    return { tostring(category) }
end

-- --------------------------------------------------------------------
-- 随机挑图
-- --------------------------------------------------------------------
-- 汇总多个目录的全部图片后统一随机（每张图等概率；单目录上限 500 条）
-- 返回 asset 表或 (nil, err)。池为空返回 nil（无图，不算错误）
local function pick_random(folders)
    if jn.images == nil then
        return nil, "本机未启用图床（缺少 image 权限或图片 DAO 不可用）"
    end
    local pool = {}
    for _, folder in ipairs(folders) do
        local ok, list = pcall(jn.images.list, folder)
        if ok and type(list) == "table" then
            for _, a in ipairs(list) do
                pool[#pool + 1] = a
            end
        end
    end
    if #pool == 0 then return nil, nil end
    return pool[math.random(#pool)], nil
end

local function build_image_cq(asset)
    return string.format("[CQ:image,file=imgs://%s]", asset.id)
end

-- --------------------------------------------------------------------
-- 发送
-- --------------------------------------------------------------------
local function send_random(event, category)
    local folders = resolve_folders(category)
    if not folders then
        return true, "未配置默认图床目录，请在面板设置 random_image.default_folder"
    end
    local asset, err = pick_random(folders)
    if err then return true, err end
    if not asset then
        return true, string.format("图床目录「%s」暂无图片", table.concat(folders, "、"))
    end
    local cq = build_image_cq(asset)
    if event.message_type == "group" then
        jn.onebot11.send_group_msg(event.group_id, cq)
    else
        jn.onebot11.send_private_msg(event.user_id, cq)
    end
    return true, nil -- 图片已发送，无需文本回复
end

-- --------------------------------------------------------------------
-- 命令注册（主命令 + 映射生成的自定义随机命令）
-- --------------------------------------------------------------------
jn.command.register("随机图片", function(args, event)
    return send_random(event, args[1])
end, {
    description = "随机发一张图床图片（可带分类）",
    usage = "/随机图片 [分类]",
})

math.randomseed(os.time())

-- 每个别名注册一条自定义随机命令（别名 → 可能是多个目录）
local alias_list = {}
for alias in pairs(parse_mappings()) do
    alias_list[#alias_list + 1] = alias
end
table.sort(alias_list)
for _, alias in ipairs(alias_list) do
    jn.command.register("随机" .. alias, function(_, event)
        return send_random(event, alias)
    end, {
        description = "随机发送图床「" .. table.concat(parse_mappings()[alias] or {}, "、") .. "」的图片",
        usage = "/随机" .. alias,
    })
end

-- 测试钩子（仅供单元测试调用，不参与运行时逻辑）
_G.__random_image_test = {
    parse_mappings = parse_mappings,
    resolve_folders = resolve_folders,
    pick_random = pick_random,
    build_image_cq = build_image_cq,
}

jn.log.info("[random_image] 随机图片插件已加载")
