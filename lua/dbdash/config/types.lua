-- The interface of a validator (lua-language-server annotations; nothing runs here). A
-- validator is a module's lua/dbdash/<module>/validate.lua (a driver's, a chart type's
-- too), found by config/validators.lua on the runtimepath.

---@class dbdash.config.Validator
---@field name string what its errors say: `board.yaml:12:5: [db] ...`
---@field checks string what it checks (for :help and for whoever reads its errors)
---@field after string[]? the validators that run before it (one completes what it reads:
---  [db] gives each panel's database its type)
---@field validate fun(cfg: dbdash.Config, ctx: dbdash.config.Ctx) the whole config: it
---  checks its own part and may complete it (normalized values, defaults); ctx:fail(path,
---  msg, ...) reports a problem with the line of `path` (it does not return)
---@field module string? its module (set when it is found)

-- dbdash.config.Ctx (config.lua) gives validators fail, expect, duration, document(cfg),
-- file and pos (the line of every path).

local M = {}

return M
