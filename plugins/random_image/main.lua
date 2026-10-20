-- ====================================================================
-- random_image 随机图片插件
-- --------------------------------------------------------------------
-- 移植自 lanmei-dream 的随机图片玩法，图片来源改为本项目图床（jn.images）：
--   /随机图片              → 默认目录（config.default_folder）随机一张
--   /随机图片 <分类>       → 分类 → 图床目录（先查映射别名，未命中直接当目录名）
--   /随机<别名>            → 映射注册的自定义随机命令（如 /随机奶龙 /随机奶蛙）
-- 新增特性：
--   * 关键词自动回复：检测到包含配置关键词时，自动从指定的多个目录或多个具体图片中
--     抽取一张回复，支持白名单群、触发概率与群冷却保护。
-- 命中图片后发 [CQ:image,file=imgs://<图床id>]，发送层统一解析为 base64。
-- ====================================================================

local jn = require("jn")

---@diagnostic disable: undefined-global

-- --------------------------------------------------------------------
-- 配置解析
-- --------------------------------------------------------------------
-- 解析 mappings 配置（"别名=目录" 列表）→ {alias → {folder,...}}
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
            folders_part = folders_part:gsub("，", ",")
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

-- 解析关键词规则列表：
--   格式：关键词1,关键词2...=目录:目录1,目录2|图片:图片名1,图片名2
--   或简写：关键词1,关键词2...=目录1,目录2
local function parse_keyword_rules()
    local raw = jn.config.get("keyword_rules")
    local rules = {}
    if type(raw) ~= "table" then return rules end
    for _, item in ipairs(raw) do
        local s = tostring(item or "")
        local kw_part, target_part = s:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
        if kw_part and target_part and target_part ~= "" then
            local keywords = {}
            kw_part = kw_part:gsub("，", ",")
            for kw in kw_part:gmatch("[^,]+") do
                kw = kw:match("^%s*(.-)%s*$")
                if kw ~= "" then keywords[#keywords + 1] = kw end
            end

            local folders = {}
            local image_names = {}

            target_part = target_part:gsub("，", ",")
            if target_part:find("目录:") or target_part:find("图片:") then
                for seg in target_part:gmatch("[^|]+") do
                    seg = seg:match("^%s*(.-)%s*$")
                    if seg:find("^目录:") then
                        local f_str = seg:sub(8)
                        for f in f_str:gmatch("[^,]+") do
                            f = f:match("^%s*(.-)%s*$")
                            if f ~= "" then folders[#folders + 1] = f end
                        end
                    elseif seg:find("^图片:") then
                        local img_str = seg:sub(8)
                        for im in img_str:gmatch("[^,]+") do
                            im = im:match("^%s*(.-)%s*$")
                            if im ~= "" then image_names[#image_names + 1] = im end
                        end
                    end
                end
            else
                -- 简写语法：直接作为多个目录
                for f in target_part:gmatch("[^,]+") do
                    f = f:match("^%s*(.-)%s*$")
                    if f ~= "" then folders[#folders + 1] = f end
                end
            end

            if #keywords > 0 and (#folders > 0 or #image_names > 0) then
                rules[#rules + 1] = {
                    keywords = keywords,
                    folders = folders,
                    images = image_names,
                }
            end
        end
    end
    return rules
end

local function is_keyword_enabled_group(group_id)
    local gid = tonumber(group_id) or 0
    if gid <= 0 then return false end
    local raw = jn.config.get("keyword_enable_groups")
    local list = {}
    if type(raw) == "table" then
        list = raw
    elseif type(raw) == "string" then
        for item in raw:gmatch("[^,，%s]+") do list[#list + 1] = item end
    end
    if #list == 0 then return true end
    for _, v in ipairs(list) do
        if v == "*" or tonumber(v) == gid then return true end
    end
    return false
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
-- 汇总多个目录及多个指定图片名称，统一随机
local function pick_random(folders, specific_images)
    if jn.images == nil then
        return nil, "本机未启用图床（缺少 image 权限或图片 DAO 不可用）"
    end
    local pool = {}
    local seen_ids = {}

    -- 1. 指定目录下的所有图片
    if folders and #folders > 0 then
        for _, folder in ipairs(folders) do
            local ok, list = pcall(jn.images.list, folder)
            if ok and type(list) == "table" then
                for _, a in ipairs(list) do
                    if a.id and not seen_ids[a.id] then
                        seen_ids[a.id] = true
                        pool[#pool + 1] = a
                    end
                end
            end
        end
    end

    -- 2. 指定单张图片（按名称搜索精准或前缀匹配）
    if specific_images and #specific_images > 0 then
        for _, img_name in ipairs(specific_images) do
            local ok, list = pcall(jn.images.search, img_name, 5)
            if ok and type(list) == "table" then
                for _, a in ipairs(list) do
                    if a.id and not seen_ids[a.id] then
                        -- 精准命中或名称相符
                        if tostring(a.name) == img_name or tostring(a.name):find(img_name, 1, true) then
                            seen_ids[a.id] = true
                            pool[#pool + 1] = a
                        end
                    end
                end
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
    if not folders or #folders == 0 then
        return true, "未配置默认目录，请在后台设置 default_folder 或指定分类"
    end
    local asset, err = pick_random(folders, nil)
    if err then
        return true, err
    end
    if not asset then
        local cat_name = category or jn.config.get("default_folder") or ""
        return true, string.format("图床「%s」分类下还没有图片", cat_name)
    end
    jn.onebot11.send_group_msg(event.group_id, build_image_cq(asset))
    return true, nil
end

-- --------------------------------------------------------------------
-- 命令注册（主命令 + 映射生成的自定义随机命令）
-- --------------------------------------------------------------------
jn.command.register("随机图片", function(args, event)
    return send_random(event, args[1])
end, {
    description = "随机发送图床图片",
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
        description = string.format("从「%s」映射的图床目录中随机发送一张", alias),
        usage = "/随机" .. alias,
    })
end

-- --------------------------------------------------------------------
-- 普通消息关键词监听触发
-- --------------------------------------------------------------------
function on_message(event)
    if not event or event.message_type ~= "group" then return false, nil end
    local gid = tonumber(event.group_id) or 0
    if gid <= 0 or not is_keyword_enabled_group(gid) then return false, nil end

    local raw = tostring(event.raw_message or "")
    if raw == "" or raw:sub(1, 1) == "/" then return false, nil end

    local rules = parse_keyword_rules()
    if #rules == 0 then return false, nil end

    -- 检查是否命中任何规则
    local matched_rule = nil
    for _, rule in ipairs(rules) do
        for _, kw in ipairs(rule.keywords) do
            if raw:find(kw, 1, true) then
                matched_rule = rule
                break
            end
        end
        if matched_rule then break end
    end
    if not matched_rule then return false, nil end

    -- 概率控制
    local prob = tonumber(jn.config.get("keyword_reply_probability")) or 100
    if prob <= 0 then return false, nil end
    if prob < 100 and math.random(100) > prob then return false, nil end

    -- 冷却控制
    local cd = tonumber(jn.config.get("keyword_cooldown_seconds")) or 10
    if cd > 0 and jn.cache then
        local ckey = "random_image:cd:" .. gid
        if jn.cache.exists(ckey) > 0 then
            return false, nil
        end
        jn.cache.set(ckey, "1", cd)
    end

    local asset, err = pick_random(matched_rule.folders, matched_rule.images)
    if asset and not err then
        jn.onebot11.send_group_msg(gid, build_image_cq(asset))
    end
    return false, nil
end

-- 测试钩子（仅供单元测试调用，不参与运行时逻辑）
_G.__random_image_test = {
    parse_mappings = parse_mappings,
    resolve_folders = resolve_folders,
    pick_random = pick_random,
    parse_keyword_rules = parse_keyword_rules,
}

jn.log.info("[random_image] 随机图片插件已加载（支持多目录与关键词自动回复）")
