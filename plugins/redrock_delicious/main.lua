-- ====================================================================
-- redrock_delicious
-- CronJob 触发后随机向指定群发送一条吃饭语录
--
-- CronJob Payload 示例:
--   { "groups": [123456, 789012] }
--
-- 语录库：内置红岩周边觅食推荐（中心食堂一楼/二楼 + 校外），
-- 面板可通过 extra_quotes 配置追加自定义语录。
-- ====================================================================

local jn = require("jn")

-- 内置语录库（红岩er 亲测好味，统一开头："该吃饭了，卷娘到xxx吃了xxx"，结尾评价各不重复）
local QUOTES = {
    -- 中心食堂一楼
    "该吃饭了，卷娘到中心食堂一楼吃了个掉渣饼，酥得直掉渣，好吃到停不下来喵～",
    "该吃饭了，卷娘到中心食堂一楼吃了煎饼果子，卷得扎实，一口下去超满足喵～",
    "该吃饭了，卷娘到中心食堂一楼面包店吃了岩烧乳酪面包，奶香在嘴里化开，绝了喵～",
    "该吃饭了，卷娘到中心食堂一楼面包店顺了个咖啡面包，微苦回甘，越嚼越香喵～",
    "该吃饭了，卷娘到中心食堂一楼吃了番茄鸡蛋滑蛋饭，蛋又嫩又滑，拌着汁能炫两碗喵～",
    "该吃饭了，卷娘到中心食堂一楼喝了杯瑞幸咖啡，困意瞬间消散，精神满了喵～",
    "该吃饭了，卷娘到中心食堂一楼吃了宜宾素燃面，麻辣鲜香，嗦完还想再来一碗喵～",
    "该吃饭了，卷娘到中心食堂一楼吃了份轻食，清爽不腻，减脂人也安心喵～",
    "该吃饭了，卷娘到中心食堂一楼麦当劳吃了巨无霸，经典味道依旧，真香喵～",
    "该吃饭了，卷娘到中心食堂一楼吃了藤椒抄手，麻意顺着舌尖窜，太过瘾了喵～",
    -- 中心食堂二楼
    "该吃饭了，卷娘到中心食堂二楼吃了兰州拉面的番茄鸡蛋盖浇面，浇汁拌饭一绝喵～",
    "该吃饭了，卷娘到中心食堂二楼吃了贵州蘸水菜，往蘸水里一滚，鲜掉眉毛喵～",
    "该吃饭了，卷娘到中心食堂二楼吃了山城小火锅，越煮越香，麻辣过瘾喵～",
    -- 校外
    "该吃饭了，卷娘到兰馨面庄吃了碗面，汤鲜面弹，难怪大家都说好吃喵～",
    "该吃饭了，卷娘到六婶老火锅吃了顿火锅，毛肚七上八下，巴适得很喵～",
    "该吃饭了，卷娘到中原面馆吃了碗面，分量扎实，老味道一点没变喵～",
    "该吃饭了，卷娘到校外吃了份肠粉，米香滑嫩，酱汁一浇绝配喵～",
    "该吃饭了，卷娘到彩蝶轩吃了顿饭，菜品常有惊喜，换口味首选喵～",
    "该吃饭了，卷娘到福建千里馄饨王吃了碗馄饨，皮薄馅大，一口一个鲜喵～",
    -- 通用
    "该吃饭了，卷娘今天还不知道去哪吃，其他食堂有什么好吃的快来告诉卷娘喵～",
}

-- 组装语录库：内置 + 面板 extra_quotes 自定义（写法参照 poke-reply）
local function build_quotes()
    local quotes = {}
    for _, q in ipairs(QUOTES) do
        quotes[#quotes + 1] = q
    end
    local extra = jn.config.get("extra_quotes")
    if type(extra) == "table" then
        for _, q in ipairs(extra) do
            if type(q) == "string" and q ~= "" then
                quotes[#quotes + 1] = q
            end
        end
    end
    return quotes
end

-- 定时任务回调（引擎派发 on_cronjob）
function on_cronjob(event)
    local payload = event.payload or {}
    local groups = payload.groups

    if not groups or #groups == 0 then
        jn.log.error("[delicious] payload 缺少 groups 数组")
        return
    end

    local quotes = build_quotes()
    local quote = quotes[math.random(#quotes)]

    for _, gid in ipairs(groups) do
        jn.onebot11.send_group_msg(tonumber(gid), quote)
        jn.log.info(string.format("[delicious] 已向群 %s 发送语录: %s", tostring(gid), quote))
    end
end

jn.log.info("[redrock_delicious] 干饭语录插件已加载")
