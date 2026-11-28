-- numbers:// (an example of a driver of your own, :help dbdash-extend): query.sql is a count
-- N; the rows are n = 1..N with n * database.options.step and its square. A driver is a
-- directory db/drivers/<name>/ on the runtimepath: this init.lua, its validate.lua and
-- whatever files it needs.
local M = {
  name = "numbers",
  schemes = { "numbers" },
  capabilities = { tls = false, sql = false, query_language = "a count" },
  -- the database.options it reads (checked by its validate.lua)
  options = { step = "integer" },
}

local Conn = {}
Conn.__index = Conn

---A database: connect gives a connection whose execute runs one query.
function M.connect(info)
  return setmetatable({ info = info }, Conn)
end

---@param sql string the query, rendered (templates work as with any database)
function Conn:execute(sql)
  local n = tonumber(vim.trim(sql))
  if not n then
    require("dbdash.util.error").raise("query", ("not a count: %q"):format(sql))
  end
  local step = (self.info.options or {}).step or 1
  local rows = {}
  for i = 1, n do
    rows[i] = { "n" .. i, i * step, (i * step) ^ 2 }
  end
  return require("dbdash.db.resultset").new({
    { name = "label", type = "string" },
    { name = "value", type = "integer" },
    { name = "square", type = "integer" },
  }, rows)
end

function Conn:close() end

return M
