-- ====================================================================
-- {{.Name}}
-- {{.Description}}
-- ====================================================================

local jn = require("jn")

--- Plugin entry point: called on every message
---@param event jn.Event
function on_message(event)
    -- TODO: your logic here

    -- 插件目录内文本文件读写示例（需在 pluggin.yaml permissions 申请 file）：
    --   local ok, err = jn.file.write("data/state.txt", "hello")
    --   local content, err = jn.file.read("data/state.txt")
    --   jn.file.append_line("data/log.txt", "msg from " .. (event.user_id or "?"))

    return false, nil
end
