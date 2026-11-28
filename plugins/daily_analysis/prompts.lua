-- prompts.lua — daily_analysis 人设读取、主分析 / Map 切片 / Reduce 汇总提示词

return function(jn, common)
    local M = {}

    function M.get_bot_persona_prompt()
        local persona_style = jn.config.get("use_bot_persona") or "deep"
        if persona_style == "none" or persona_style == false or persona_style == "false" then
            return "你是一个客观、严谨、幽默的群聊内容分析专家。"
        end

        local persona_text = ""
        if jn.agent and jn.agent.get_persona then
            local p = jn.agent.get_persona()
            if type(p) == "table" and p.content and p.content ~= "" then
                persona_text = p.content
            elseif type(p) == "string" and p ~= "" then
                persona_text = p
            end
        end

        if persona_text ~= "" then
            if persona_style == "deep" then
                return "【你的人格设定（最高优先级，在话题分析、点评和全群总结时，深度还原此人设口吻、口癖与性格特质）】：\n" .. persona_text
            else
                return "【你的人格参考（保持适度幽默风趣，口吻贴合此人设）】：\n" .. persona_text
            end
        end

        return "你是一个风趣幽默、擅长观察但又不失温情的群聊观察员。"
    end

    local SLANG_AND_MEDIA_RULES = table.concat({
        "- 【图片与合并转发关联（严禁输出内部编号）】：聊天流里的 `[图#编号：...]` 与 `[转发#编号｜N条] ...` 仅是供你理解上下文的内部参考标签。请结合回复引用与上下文发言确认围绕它展开的讨论，但在最终输出的所有展示文案中**严禁出现 `[图#1]`、`[转发#1]` 这类编号标签**，必须改用自然语言（如「某人发的图片」「某人转发的聊天记录」）。",
        "- 【网络黑话与谐音梗识别】：群友常使用谐音词、黑话、双关语、隐晦开车调侃或网络热梗。请在话题叙事中结合上下文自然点破笑点（措辞适度克制避免触碰审查），在金句里保留原句文本并在 `reason` 中说明梗点。",
    }, "\n")

    local QUOTE_CRITERIA_RULES = table.concat({
        "   ⚠️【明确算金句（欢迎收录以下 6 类）】：① 复制粘贴段子/模板文学（如发疯文学、V我50变体、反向凡尔赛等）；② 常规谐音词/普通或隐晦开车玩梗；③ 神反转抖包袱；④ 反常识逆天暴论；⑤ 用专业/技术概念降维精准吐槽生活或人际关系；⑥ 戏剧张力极强的群友神回。",
        "   ⚠️【明确不收（宁缺毋滥，以下一律淘汰）】：① 脱离前文上下文就看不懂、没头没尾的 3~8 字短接话碎片 / 普通反问 / 日常提问（例如「HIV吗」「这还需要ai吗」「原来那个字念jìng吗」「这是几晚上的问题吗」「好看我也不给」——单独挂出来既看不懂笑点又容易让群友莫名其妙；若笑点靠前两句铺垫，必须是同一发言人连续或中间被他人短暂插话打断但仍语义相连的几条发言合并后完整自洽才收，否则留给话题分析）；② 普通的技术排查、参数解释（如解释 application id）、日常闲聊、问好或单纯伸手求图。",
        "   ⚠️【只取本人正文】只收发言人自己打出的字。严禁把「【回复 某人：「…」】」这类被引用的原文写进 content；清掉 [CQ:...] 等占位符；若该金句针对某张图片或转发记录吐槽，在 `reason` 中用「针对某人发的图片/转发的聊天记录」自然说明，严禁输出 `[图#k]` 或 `[转发#k]`。",
        "   ⚠️【合并同人多条发言（含中间被打断） & 防拆分】同一个人连续 2-3 条消息、或同一人在短时间内发了好几条关联消息即便中间被他人短暂插话打断（如铺垫被插嘴后本人继续抖包袱/补充反转），只要合起来完整成梗均可评为金句并合并成一条：`content` 用 \\n 依次串联该发言人的这几条原话（严禁把中间打断者的发言混入 `content`，可在 `reason` 中说明“中间被他人插话后本人继续补刀/反转”）；`msg_ids` 数组依次列出这几条对应的数字编号（如 `[10, 12]`，单条填 `[10]`），`msg_id` 填首条编号；每行 `[#编号 HH:MM]` 不得按空行拆条，sender 必须是真实昵称。",
    }, "\n")

    function M.build_analysis_prompt(chat_stream, stats, persona_prompt, caps)
        caps = caps or {}
        local max_topics = caps.topics or 0
        local max_quotes = caps.quotes or 0
        local max_titles = caps.titles or 0
        local max_critiques = caps.critique or 0
        local use_persona = jn.config.get("use_bot_persona") or "deep"

        local topics_rule
        if max_topics > 0 then
            topics_rule = string.format("提取不多于 %d 个今日核心热门话题", max_topics)
        elseif max_topics == -1 then
            topics_rule = "提取今日出现的所有核心热门话题，不限数量上限"
        else
            topics_rule = "无需提取话题（本项已关闭）"
        end

        local quotes_rule
        if max_quotes > 0 then
            quotes_rule = string.format("从全天聊天中严选不多于 %d 句真正够格登上「群圣经」的高光金句（宁缺毋滥，不足则按实际精品数输出）；引用必须逐字完整，禁止省略或概括", max_quotes)
        elseif max_quotes == -1 then
            quotes_rule = "不设固定条数上限，但务必宁缺毋滥：只甄选脱离前文依然好笑、完整自洽的高光「群圣经/金句」，坚决淘汰平淡接话与凑数短句；引用必须逐字完整，禁止省略或概括"
        else
            quotes_rule = "无需提取金句（本项已关闭）"
        end

        local titles_rule
        if max_titles > 0 then
            titles_rule = string.format("为不多于 %d 位发言活跃群友评选极具特色的荣誉头衔与行为特征画像", max_titles)
        elseif max_titles == -1 then
            titles_rule = "为今日所有活跃群友评选极具特色的头衔与行为特征画像，不限数量上限"
        else
            titles_rule = "无需评选头衔（本项已关闭）"
        end

        local critique_rule
        if max_critiques ~= 0 then
            local count_text = (max_critiques > 0) and string.format("不多于 %d 个", max_critiques) or "不限数量"
            if use_persona == "none" then
                critique_rule = string.format("将今日聊天划分为 %s 抽象维度（如技术研讨、职业焦虑、日常摸鱼），为每个维度计算大致占比百分比，并给出客观严谨的分析点评与全天综合表现总结！", count_text)
            else
                critique_rule = string.format("将今日聊天划分为 %s 抽象维度（如技术研讨、职业焦虑、日常摸鱼），为每个维度计算大致占比百分比，并【结合你的人格设定】给出贴合你性格与口吻的精彩、幽默或生动点评，最后附一句全天综合表现总结！", count_text)
            end
        else
            critique_rule = "无需进行聊天质量点评（本项已关闭）"
        end

        local clean_stream = common.strip_wm(chat_stream or "")

        return string.format([[
%s

你现在正在为群聊生成一份智能的「今日群聊日常分析报告」。
请根据下方给出的【群聊记录数据流】，按规则完成分析，并以严格的纯 JSON 格式返回。

## 核心任务要求：
1. 话题分析：%s。
   - summary 必须写成 150-300 字的叙事段落：交代起因、谁抛出了什么、群里怎么交锋、最后的结论或笑点；点名具体发言人（真实昵称），可以引用短句。
   - 禁止把「某人分享了一个链接/单篇短评/一个仓库」单独列为话题——除非群里围绕它展开了讨论。零散分享并入最相关的话题；若群里有成批合并转发的多篇公众号/资讯合集且未展开讨论，可合并成一条「资讯搬运」概述。
   - 提及发言人必须使用真实【QQ昵称】（nickname 属性），严禁只写参与者编号或纯 QQ 号。
   - 标题不超过 20 字，禁止「讨论 XX」「关于 XX」这种空壳标题。
%s
2. 群圣经甄选：%s。
%s
3. 群友头衔：%s。user 必须填群友真实昵称。
4. 质量锐评与人设点评：%s。

## 返回 JSON 数据结构规范（严禁包含 markdown 代码块包裹之外的杂质，必须是合法 JSON）：
```json
{
  "topics": [
    {
      "title": "话题标题（不超过 20 字）",
      "summary": "150-300 字叙事：起因、谁怎么说、若围绕某人发的图片或转发记录展开请直接写明该图片/转发的核心内容与众人反应、交锋焦点与笑点，点名发言人昵称（严禁输出 [图#k] 或 [转发#k]）",
      "participants": "主要讨论者（使用真实昵称，逗号分隔）"
    }
  ],
  "golden_quotes": [
    {
      "msg_id": 1,
      "msg_ids": [1],
      "sender": "发言人真实昵称",
      "content": "金句原文：逐字完整引用本人正文，保留原有换行；严禁省略、缩写、只留开头结尾或用省略号代替中间内容。不含被引用内容、中间打断者的插话与 CQ 码；同人连续或中间被打断的多条关联发言用换行串联",
      "reason": "入选理由（具体说明其逆天逻辑/谐音笑点/神人反差；若吐槽了某人发的图片或转发记录请自然点明，严禁输出 [图#k] 或 [转发#k]）"
    }
  ],
  "user_titles": [
    {
      "user": "群友真实昵称",
      "title": "幽默专属头衔",
      "description": "获此头衔的行为特征点评"
    }
  ],
  "critique": {
    "dimensions": [
      {
        "name": "抽象维度名称（如职业焦虑/技术交锋/深夜水群）",
        "percentage": 30,
        "comment": "深度还原你人设口吻的犀利点评"
      }
    ],
    "overall_summary": "以你的人设口吻给出的全天群聊综合表现霸气金句总结"
  }
}
```

## 群聊记录数据流（共 %d 条）：
%s
]], persona_prompt, topics_rule, SLANG_AND_MEDIA_RULES, quotes_rule, QUOTE_CRITERIA_RULES, titles_rule, critique_rule, stats.total_count, clean_stream)
    end

    function M.build_map_prompt(chunk_stream, part_idx, total_parts, persona_prompt, section_caps)
        local clean_stream = common.strip_wm(chunk_stream or "")
        local max_quotes = section_caps and tonumber(section_caps.quotes) or -1
        local map_quote_rule
        if max_quotes == 0 then
            map_quote_rule = "【切片金句配额】：当前已关闭金句板块，`golden_quotes` 必须返回空数组 `[]`。"
        elseif max_quotes > 0 then
            map_quote_rule = string.format("【切片金句配额】：本切片至多初选 %d 条最强候选金句（宁缺毋滥，不够不硬凑，无合适可返回 `[]`），留待汇总阶段在全天所有分片候选中二次精选。", max_quotes)
        else
            map_quote_rule = "【切片金句配额】：不限制本切片候选条数上限，但严格按门槛初选（宁缺毋滥，不凑平淡接话，无合适可返回 `[]`），留待汇总阶段二次淘汰筛选。"
        end
        return string.format([[%s

你正在执行大群日报的【第 %s/%d 时段切片提炼】任务。请从以下聊天片段中提取关键话题、图片/合并转发独立摘要、候选金句与氛围亮点，严格返回纯 JSON：
```json
{
  "media_summaries": [
    {
      "ref": "[图#1] 或 [转发#1]",
      "summary": "独立概括该图片画面或该合并转发聊天记录的核心内容",
      "related_msgs": "哪些[#编号]或谁的发言/讨论围绕它展开及核心反应"
    }
  ],
  "topics": [
    { "title": "话题标题(≤20字)", "summary": "80-180字分段叙事（点名真实昵称、交代起因结论；若围绕某人发的图片或转发记录展开请自然写明核心内容，严禁输出 [图#k] 或 [转发#k]）", "participants": "主要讨论者昵称，逗号分隔" }
  ],
  "golden_quotes": [
    { "msg_id": 1, "msg_ids": [1], "sender": "真实昵称", "content": "逐字原话(不含回复引用、中间插话和CQ码；同人连续或被打断的关联多发用\\n串联)", "reason": "简短入选理由（说明笑点/反转/梗点或对某人发的图片/转发的吐槽，严禁输出 [图#k] 或 [转发#k]）" }
  ],
  "highlights": ["1-2条时段氛围或活跃人物特点简述"]
}
```
要求：
1. 每行 `[#编号 HH:MM] 昵称: 内容` 中的编号即 `msg_id`；零散无关链接可合并或忽略。
2. 【切片独立总结图片与转发】：本片断只要出现 `[图#k：...]` 或 `[转发#k...]` 且有内容价值或引出讨论，必须在 `media_summaries` 单独总结它讲了什么，并确认切片内哪几条讨论围绕它展开。
3. 【金句初选标准】%s
%s
4. 只输出纯 JSON，不要多余解释。

## 群聊切片记录：
%s]], persona_prompt, tostring(part_idx), tonumber(total_parts) or 1, map_quote_rule, QUOTE_CRITERIA_RULES, clean_stream)
    end

    function M.build_quote_curation_prompt(candidates, total_parts, persona_prompt, max_quotes)
        local n_lim = tonumber(max_quotes) or -1
        local payload = {}
        for i, c in ipairs(candidates or {}) do
            payload[#payload + 1] = {
                id = i,
                part = c.part,
                msg_id = c.msg_id,
                msg_ids = c.msg_ids,
                sender = c.sender,
                content = c.content,
                reason = c.reason,
            }
        end
        local quota_rule
        if n_lim > 0 then
            quota_rule = string.format(
                "当前全天共从 %d 个时段切片初选出 %d 条候选金句。请你站在全天横向对比的视角执行【严格二次终筛】，优中选优、淘汰相对平淡或弱上下文的条目，最终仅保留最炸裂的 **至多 %d 条**（不足 %d 条按实际精品数保留，严禁硬凑）。",
                tonumber(total_parts) or 1, #payload, n_lim, n_lim)
        else
            quota_rule = string.format(
                "当前全天共从 %d 个时段切片初选出 %d 条候选金句（配额设为不限上限）。请你站在全天横向对比的视角执行【严格二次淘汰】：主动删掉其中相对平淡、凑数、或脱离前文就没头没尾（如 3~8 字短反问/单句接话/日常提问/普通技术解释）的后排候选，通常淘汰掉相对较弱的那一部分，只保留真正配得上「群圣经」的精品（宁缺毋滥）。",
                tonumber(total_parts) or 1, #payload)
        end

        return string.format([[%s

你现在专门负责为今日群聊日报执行「群圣经 / 金句」的最终二次筛选。
%s

%s

输出格式要求：
1. 严格只返回纯 JSON，不要输出 markdown 代码块之外的任何杂质：
```json
{
  "golden_quotes": [
    {
      "id": 1,
      "msg_id": 123,
      "msg_ids": [123],
      "sender": "发言人真实昵称",
      "content": "完整保留候选原话（禁止修改、缩减或加省略号）",
      "reason": "精炼犀利的入选理由（严禁出现 [图#k] 或 [转发#k]）"
    }
  ]
}
```
2. `id` 必须严格对应下方候选列表中的 `id`（不得凭空捏造新候选），按精彩程度从高到低排序。

## 全天分片初选候选列表（共 %d 条）：
%s
]], persona_prompt, quota_rule, QUOTE_CRITERIA_RULES, #payload, common.strip_wm(jn.json.encode(payload)))
    end

    function M.build_reduce_prompt(map_items, stats, persona_prompt, caps)
        local parts = {}
        local idx_ok = 0
        for k, m in ipairs(map_items) do
            if m.data then
                idx_ok = idx_ok + 1
                parts[#parts + 1] = string.format("【切片 %d 结果】\n%s", k, common.strip_wm(jn.json.encode(m.data)))
            end
        end
        local top_lines = {}
        for i = 1, math.min(10, #(stats.top_users or {})) do
            local u = stats.top_users[i]
            top_lines[#top_lines + 1] = string.format("- %s: %d 条发言", common.strip_wm(u.name), u.count)
        end
        local digest_stream = string.format(
            "以下为全天 %d 个时段切片的结构化提炼结果（共原始发言 %d 条；包含各切片独立归纳的 `media_summaries` 图片/转发摘要及其关联讨论）。请去重合并跨切片同话题、把图片/转发的独立摘要与讨论因果自然融入对应话题，精炼为最终完整 JSON 报告：\n\n### 活跃发言榜 Top10：\n%s\n\n### 分段提炼汇总：\n%s",
            idx_ok, stats.total_count,
            #top_lines > 0 and table.concat(top_lines, "\n") or "无",
            table.concat(parts, "\n\n")
        )
        return M.build_analysis_prompt(digest_stream, stats, persona_prompt, caps)
    end

    return M
end
