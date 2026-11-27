-- lua:// "database": query.sql is Lua code (after the template), run inside the query task.
-- Its return value is the raw result: rows (see db/lua_result.lua), directly or after
-- query.transform. It can use args and the dbdash.* helpers (see db/lua_env.lua). Configs
-- with Lua need the user's trust (:help dbdash-lua).
local M = {
  name = "lua",
  schemes = { "lua" },
  capabilities = { tls = false, sql = false, query_language = "lua" },
}

local Conn = {}
Conn.__index = Conn

function M.connect(info)
  return setmetatable({ info = info }, Conn)
end

---@class dbdash.db.drivers.lua.ExecuteOpts
---@field max_rows integer
---@field timeout integer
---@field args table?
---@field source string?
---@field line integer?

---@param code string
---@param opts dbdash.db.drivers.lua.ExecuteOpts
function Conn:execute(code, opts)
  local value = require("dbdash.db.lua_env").run(code, {
    phase = "query",
    source = opts.source,
    line = opts.line,
    args = opts.args,
    meta = opts.meta,
    lua = opts.lua,
    timeout = opts.timeout,
    max_rows = opts.max_rows,
    cancel = opts.cancel, -- cancelling the query stops the script
  })
  return require("dbdash.db.lua_result").raw(value)
end

function Conn:close() end

function Conn:server_version()
  return jit and jit.version or _VERSION
end

-- database.options: none (dbdash.db.options)
M.options = {}

return M
