-- store.lua — PostgreSQL 持久化去重、基线记录、静默队列与诊断状态读取

return function(jn, common)
    local M = {}

    local TABLE_SEEN = "pluggin_ai_reset_monitor_seen"
    local TABLE_PENDING = "pluggin_ai_reset_monitor_pending"

    local db_ready = false
    local mem_seen = {}

    function M.init()
        if db_ready or not (jn.database and jn.database.exec) then return end
        local sql = [[
            CREATE TABLE IF NOT EXISTS ]] .. TABLE_SEEN .. [[ (
                event_key VARCHAR(255) PRIMARY KEY,
                product VARCHAR(64) NOT NULL,
                event_kind VARCHAR(64) NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                source_url TEXT NOT NULL DEFAULT '',
                announced_ts BIGINT NOT NULL DEFAULT 0,
                payload_json TEXT NOT NULL DEFAULT '',
                notified BOOLEAN NOT NULL DEFAULT FALSE,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_arm_seen_prod_ts
                ON ]] .. TABLE_SEEN .. [[ (product, announced_ts DESC);

            CREATE TABLE IF NOT EXISTS ]] .. TABLE_PENDING .. [[ (
                id SERIAL PRIMARY KEY,
                group_id BIGINT NOT NULL,
                event_key VARCHAR(255) NOT NULL,
                product VARCHAR(64) NOT NULL,
                message_text TEXT NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
                UNIQUE (group_id, event_key)
            );
            CREATE INDEX IF NOT EXISTS idx_arm_pending_gid
                ON ]] .. TABLE_PENDING .. [[ (group_id, id);
        ]]
        local _, err = jn.database.exec(sql)
        if err then
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 初始化数据库表失败: " .. tostring(err))
        else
            db_ready = true
        end
    end

    local function cache_key(event_key)
        return "arm:seen:" .. common.fnv1a_hex(event_key) .. ":" .. event_key:sub(1, 64)
    end

    function M.has_seen(event_key)
        if not event_key or event_key == "" then return true end
        if mem_seen[event_key] then return true end
        if jn.cache and jn.cache.get then
            local c = jn.cache.get(cache_key(event_key))
            if type(c) == "table" and c.seen then
                mem_seen[event_key] = true
                return true
            end
        end
        if jn.database and jn.database.query then
            M.init()
            local rows, err = jn.database.query(
                "SELECT event_key FROM " .. TABLE_SEEN .. " WHERE event_key = ? LIMIT 1",
                { event_key }
            )
            if not err and type(rows) == "table" and #rows > 0 then
                mem_seen[event_key] = true
                if jn.cache and jn.cache.set then
                    jn.cache.set(cache_key(event_key), { seen = true }, 30 * 86400)
                end
                return true
            end
        end
        return false
    end

    function M.count_seen()
        if not (jn.database and jn.database.query) then return 0 end
        M.init()
        local rows, err = jn.database.query("SELECT COUNT(*) AS cnt FROM " .. TABLE_SEEN)
        if err or type(rows) ~= "table" or #rows == 0 then return 0 end
        return tonumber(rows[1].cnt) or 0
    end

    function M.mark_seen(ev, notified)
        if not ev or not ev.event_key or ev.event_key == "" then return end

        local function persist_row(key, prod, kind, ttl, url, ts, pjson, is_notified)
            mem_seen[key] = true
            if jn.cache and jn.cache.set then
                jn.cache.set(cache_key(key), { seen = true }, 30 * 86400)
            end
            if not (jn.database and jn.database.exec) then return end
            M.init()
            local sql = [[
                INSERT INTO ]] .. TABLE_SEEN .. [[
                    (event_key, product, event_kind, title, source_url, announced_ts, payload_json, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (event_key) DO UPDATE SET
                    notified = ]] .. TABLE_SEEN .. [[.notified OR EXCLUDED.notified
            ]]
            local _, err = jn.database.exec(sql, {
                tostring(key):sub(1, 250),
                tostring(prod or ""),
                tostring(kind or ""),
                tostring(ttl or ""),
                tostring(url or ""),
                tonumber(ts) or 0,
                tostring(pjson or ""),
                is_notified == true,
            })
            if err then
                jn.log.warn("[" .. common.PLUGIN_NAME .. "] 写入 seen 记录失败: " .. tostring(err))
            end
        end

        local payload_json = ""
        if ev.event_kind ~= "incident_suppressed" and ev.event_kind ~= "incident_notified" then
            local ok, enc = pcall(jn.json.encode, {
                scope = ev.scope or "",
                objective_summary = ev.objective_summary or "",
                persona_comment = ev.persona_comment or "",
                is_major = ev.is_major == true,
                source_name = ev.source_name or "",
            })
            if ok and type(enc) == "string" then payload_json = enc end
        end

        persist_row(ev.event_key, ev.product, ev.event_kind, ev.title, ev.source_url, ev.announced_ts, payload_json, notified)

        if (ev.event_kind == "status_incident" or ev.event_kind == "status_resolved")
            and ev.incident_notify_key and ev.incident_notify_key ~= "" then
            persist_row(ev.incident_notify_key, "_meta", "incident_notified", ev.title, ev.source_url, ev.announced_ts, "", notified)
        end
    end

    function M.enqueue_pending(group_id, event_key, product, message_text)
        if not (jn.database and jn.database.exec) then return false end
        M.init()
        local sql = [[
            INSERT INTO ]] .. TABLE_PENDING .. [[ (group_id, event_key, product, message_text)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (group_id, event_key) DO NOTHING
        ]]
        local _, err = jn.database.exec(sql, {
            tonumber(group_id) or 0,
            tostring(event_key):sub(1, 250),
            tostring(product or ""),
            tostring(message_text or ""),
        })
        if err then
            jn.log.warn("[" .. common.PLUGIN_NAME .. "] 静默队列入队失败: " .. tostring(err))
            return false
        end
        return true
    end

    function M.list_pending_groups()
        if not (jn.database and jn.database.query) then return {} end
        M.init()
        local rows, err = jn.database.query(
            "SELECT DISTINCT group_id FROM " .. TABLE_PENDING .. " ORDER BY group_id"
        )
        if err or type(rows) ~= "table" then return {} end
        local out = {}
        for _, r in ipairs(rows) do
            local gid = tonumber(r.group_id)
            if gid and gid > 0 then out[#out + 1] = gid end
        end
        return out
    end

    function M.take_pending_for_group(group_id)
        if not (jn.database and jn.database.query) then return {} end
        M.init()
        local rows, err = jn.database.query(
            "SELECT id, event_key, product, message_text FROM " .. TABLE_PENDING ..
            " WHERE group_id = ? ORDER BY id ASC",
            { tonumber(group_id) or 0 }
        )
        if err or type(rows) ~= "table" then return {} end
        return rows
    end

    function M.delete_pending_ids(ids)
        if not ids or #ids == 0 or not (jn.database and jn.database.exec) then return end
        for _, id in ipairs(ids) do
            jn.database.exec("DELETE FROM " .. TABLE_PENDING .. " WHERE id = ?", { tonumber(id) or 0 })
        end
    end

    function M.latest_per_product()
        if not (jn.database and jn.database.query) then return {} end
        M.init()
        local sql = [[
            SELECT DISTINCT ON (product)
                product, event_kind, title, source_url, announced_ts, payload_json
            FROM ]] .. TABLE_SEEN .. [[
            ORDER BY product, announced_ts DESC, created_at DESC
        ]]
        local rows, err = jn.database.query(sql)
        if err or type(rows) ~= "table" then return {} end
        return rows
    end

    function M.recent_for_product(product, lookback_sec, now_ts)
        if not product or product == "" or not (jn.database and jn.database.query) then return {} end
        M.init()
        local cutoff = (now_ts or os.time()) - math.max(60, tonumber(lookback_sec) or 3600)
        local sql = [[
            SELECT event_key, product, event_kind, title, source_url, announced_ts, payload_json
            FROM ]] .. TABLE_SEEN .. [[
            WHERE product = ?
              AND announced_ts >= ?
              AND event_kind NOT IN ('unrelated', 'seed', 'active', 'cleared', 'incident_suppressed', 'incident_notified')
            ORDER BY announced_ts ASC, created_at ASC
        ]]
        local rows, err = jn.database.query(sql, { product, cutoff })
        if err or type(rows) ~= "table" then return {} end
        return rows
    end

    function M.has_open_status_incident(now_ts)
        if not (jn.database and jn.database.query) then return false end
        M.init()
        local cutoff = (now_ts or os.time()) - 6 * 3600
        local sql = [[
            SELECT DISTINCT ON (product) product, event_kind, announced_ts
            FROM ]] .. TABLE_SEEN .. [[
            WHERE product IN ('openai_status', 'claude_status', 'deepseek_status')
              AND announced_ts >= ?
              AND event_kind IN ('status_incident', 'status_resolved')
            ORDER BY product, announced_ts DESC, created_at DESC
        ]]
        local rows, err = jn.database.query(sql, { cutoff })
        if err or type(rows) ~= "table" then return false end
        for _, r in ipairs(rows) do
            if r.event_kind == "status_incident" then return true end
        end
        return false
    end

    return M
end
