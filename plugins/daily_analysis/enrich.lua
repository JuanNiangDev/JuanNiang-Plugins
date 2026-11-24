-- enrich.lua — 无水印/降级开源项目补全（缓存桥 → 本地缓存 → 元数据+README 批量 LLM）

return function(jn, common)
    local M = {}

    local HF_PROXY = "socks5://172.27.0.1:20170"
    local INTRO_CACHE = "http://172.27.0.1:5284/repo-intro"

    local function trim(s)
        s = tostring(s or "")
        return (s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
    end

    local function fmt_k(n)
        n = tonumber(n) or 0
        if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
        if n >= 1000 then return string.format("%.1fk", n / 1000) end
        return tostring(n)
    end

    local function repo_intro_cache(r)
        local encoded = r.name:gsub("[^%w%-_%.]", function(c)
            return string.format("%%%02X", c:byte())
        end)
        local res = jn.http.get(INTRO_CACHE .. "?repo=" .. encoded, "")
        if not (res and res.status == 200) then return nil end
        local d = jn.json.decode(res.body)
        if type(d) == "table" and ((d.summary and d.summary ~= "") or (d.desc_cn and d.desc_cn ~= "")) then
            return d
        end
        return nil
    end

    local function fetch_github(r)
        local res, herr = jn.http.get("https://api.github.com/repos/" .. r.name, "")
        if res and res.status == 404 then
            r.invalid = true
            jn.log.warn(string.format("[%s] GitHub 仓库 404，已剔除 %s", common.PLUGIN_NAME, r.name))
            return "", ""
        end
        if not (res and res.status == 200) then
            jn.log.warn(string.format("[%s] GitHub 简介获取失败 %s status=%s err=%s",
                common.PLUGIN_NAME, r.name, tostring(res and res.status), tostring(herr)))
            return "", ""
        end
        local raw_desc, summary, readme = "", "", ""
        local d = jn.json.decode(res.body)
        if type(d) == "table" then
            raw_desc = trim(d.description)
            local meta = {}
            if trim(d.language) ~= "" then meta[#meta + 1] = d.language end
            if tonumber(d.stargazers_count) then meta[#meta + 1] = "⭐ " .. fmt_k(d.stargazers_count) end
            summary = raw_desc
            if #meta > 0 then
                summary = (summary ~= "" and (summary .. " ") or "") .. "（" .. table.concat(meta, " · ") .. "）"
            end
            if summary == "" and type(d.topics) == "table" then
                local tags = {}
                for i = 1, math.min(4, #d.topics) do tags[#tags + 1] = tostring(d.topics[i]) end
                if #tags > 0 then summary = "标签：" .. table.concat(tags, ", ") end
            end
        end
        local rres = jn.http.get("https://api.github.com/repos/" .. r.name .. "/readme", "")
        if rres and rres.status == 200 then
            local rd = jn.json.decode(rres.body)
            if type(rd) == "table" and type(rd.content) == "string" then
                readme = common.clip(common.b64_decode(rd.content), 8000)
            end
        end
        return raw_desc, summary, readme
    end

    local function fetch_hf(r, proxy)
        local is_ds = r.url:find("/datasets/", 1, true) ~= nil
        local api = is_ds and ("https://huggingface.co/api/datasets/" .. r.name)
            or ("https://huggingface.co/api/models/" .. r.name)
        local res, herr = jn.http.get(api, proxy)
        if res and res.status == 404 then
            r.invalid = true
            jn.log.warn(string.format("[%s] HF 仓库 404，已剔除 %s", common.PLUGIN_NAME, r.name))
            return "", ""
        end
        if not (res and res.status == 200) then
            jn.log.warn(string.format("[%s] HF 简介获取失败 %s status=%s err=%s",
                common.PLUGIN_NAME, r.name, tostring(res and res.status), tostring(herr)))
            return "", ""
        end
        local raw_desc, summary, readme = "", "", ""
        local d = jn.json.decode(res.body)
        if type(d) == "table" then
            local head = trim(d.pipeline_tag)
            if head == "" and type(d.tags) == "table" then
                local tags = {}
                for i = 1, math.min(3, #d.tags) do tags[#tags + 1] = tostring(d.tags[i]) end
                head = table.concat(tags, ", ")
            end
            raw_desc = head
            local meta = {}
            if tonumber(d.downloads) then meta[#meta + 1] = "⬇ " .. fmt_k(d.downloads) end
            if tonumber(d.likes) then meta[#meta + 1] = "♥ " .. fmt_k(d.likes) end
            summary = head
            if #meta > 0 then
                summary = (summary ~= "" and (summary .. " · ") or "") .. table.concat(meta, " · ")
            end
        end
        local sub = is_ds and "datasets/" or ""
        local rres = jn.http.get("https://huggingface.co/" .. sub .. r.name .. "/raw/main/README.md", proxy)
        if rres and rres.status == 200 and type(rres.body) == "string" then
            readme = common.clip(rres.body, 8000)
        end
        return raw_desc, summary, readme
    end

    local function fetch_ms(r)
        local sub = r.url:find("/datasets/", 1, true) and "datasets" or "models"
        local res = jn.http.get("https://modelscope.cn/api/v1/" .. sub .. "/" .. r.name, "")
        if res and res.status == 404 then
            r.invalid = true
            return "", ""
        end
        if res and res.status == 200 then
            local d = jn.json.decode(res.body)
            local dd = type(d) == "table" and (d.Data or d) or nil
            if type(dd) == "table" then
                local raw_desc = trim(dd.Description or dd.ChineseName or "")
                return raw_desc, raw_desc, common.clip(tostring(dd.ReadmeContent or ""), 8000)
            end
        end
        return "", "", ""
    end

    local function enrich_one(r)
        local cache_key = "repoinfo:v4:" .. r.key
        local llm_cache_key = "da:repo_sum:v1:" .. r.key

        local ri = repo_intro_cache(r)
        if ri then
            r.ri = ri
            r.summary = trim(ri.summary)
            if r.summary == "" then r.summary = trim(ri.desc_cn) end
            jn.cache.set(cache_key, { summary = r.summary, ri = ri }, 604800)
            return
        end

        local lcached = jn.cache.get(llm_cache_key)
        if type(lcached) == "table" and ((lcached.summary and lcached.summary ~= "") or (lcached.title and lcached.title ~= "")) then
            r.ri = lcached
            r.summary = trim(lcached.summary)
            return
        end

        local cached = jn.cache.get(cache_key)
        if type(cached) == "table" and cached.invalid then
            r.invalid = true
            return
        end
        if type(cached) == "table" and cached.ri
            and ((cached.ri.summary and cached.ri.summary ~= "") or (cached.ri.desc_cn and cached.ri.desc_cn ~= "")) then
            r.ri = cached.ri
            r.summary = trim(cached.summary)
            return
        end

        local raw_desc, summary, readme = "", "", ""
        if r.kind == "github" then
            raw_desc, summary, readme = fetch_github(r)
        elseif r.kind == "hf" then
            raw_desc, summary, readme = fetch_hf(r, HF_PROXY)
        elseif r.kind == "ms" then
            raw_desc, summary, readme = fetch_ms(r)
        end

        if r.invalid then
            jn.cache.set(cache_key, { summary = "", invalid = true }, 604800)
            return
        end
        r.raw_desc = raw_desc
        r.readme = readme
        if summary ~= "" then r.summary = summary end
        r.need_llm = (raw_desc ~= "" or readme ~= "")
        jn.cache.set(cache_key, { summary = summary, invalid = false }, summary ~= "" and 604800 or 86400)
    end

    local function summarize_missing_repos(list)
        if #list == 0 or not (jn.llm and jn.llm.chat) then return end
        local timeout = math.max(30, common.da_num("llm_timeout", 300))
        local sys = [[你是开源项目介绍助手。用户会给你若干个（GitHub / Hugging Face / ModelScope）仓库的官方简介与 README 摘录，请为每个仓库写出简体中文介绍并严格返回 JSON：
{"repos":[{"index":1,"title":"简短中文定位标题(≤30字)","desc_cn":"官方简介的简体中文翻译(≤60字，无简介则空字符串)","summary":"100~300字简体中文介绍：讲清是什么、核心功能/能力、支持哪些工具或关键用法；只依据提供的元数据与 README，禁止编造数据或写空话套话"}]}]]

        for start = 1, #list, 4 do
            local chunk, parts = {}, {}
            for k = start, math.min(start + 3, #list) do
                local r = list[k]
                chunk[#chunk + 1] = r
                local block = {
                    string.format("【仓库 %d】%s (%s)", #chunk, r.name, r.url or ""),
                    "官方简介：" .. (r.raw_desc or ""),
                }
                if r.readme and r.readme ~= "" then
                    block[#block + 1] = "README 摘录：\n" .. r.readme
                end
                parts[#parts + 1] = table.concat(block, "\n")
            end

            local obj = nil
            for attempt = 1, 2 do
                local resp, err = jn.llm.chat({
                    { role = "system", content = sys },
                    { role = "user", content = table.concat(parts, "\n\n") },
                }, { timeout = timeout })
                if not err and resp and resp ~= "" then
                    obj = common.decode_llm_json(resp, "项目补全")
                    if obj and type(obj.repos) == "table" then break end
                else
                    jn.log.warn(string.format("[%s] 无水印项目总结失败(第 %d 次): %s",
                        common.PLUGIN_NAME, attempt, tostring(err or "空响应")))
                end
            end

            if obj and type(obj.repos) == "table" then
                for _, item in ipairs(obj.repos) do
                    if type(item) == "table" and item.index then
                        local r = chunk[tonumber(item.index)]
                        if r then
                            local title = trim(item.title or "")
                            local desc_cn = trim(item.desc_cn or "")
                            local sum = tostring(item.summary or ""):gsub("^%s+", ""):gsub("%s+$", "")
                            if title ~= "" or sum ~= "" then
                                r.ri = { title = title, desc_cn = desc_cn, summary = sum }
                                r.summary = sum
                                jn.cache.set("da:repo_sum:v1:" .. r.key, r.ri, 604800)
                            end
                        end
                    end
                end
            end
        end
    end

    function M.enrich_repos(repos)
        if #repos == 0 then return end
        local need_llm = {}
        for _, r in ipairs(repos) do
            if not r.text and ((r.summary or "") == "" or r.degraded) then
                pcall(enrich_one, r)
                if not r.invalid and not r.ri and r.need_llm then
                    need_llm[#need_llm + 1] = r
                end
            end
        end
        if #need_llm > 0 then
            jn.log.info(string.format("[%s] 补全总结 %d 个无水印开源项目", common.PLUGIN_NAME, #need_llm))
            pcall(summarize_missing_repos, need_llm)
        end
    end

    return M
end
