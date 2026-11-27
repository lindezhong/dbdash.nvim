-- Defaults of the data layer: what a query gets when its caller passes nothing. setup()
-- (dbdash/options.lua) sets the current ones from its `defaults` and `push` options; the
-- built-in ones are also setup()'s defaults for those options.
local M = {}

---@class dbdash.db.Defaults
---@field timeout string|integer?
---@field connect_timeout string|integer?
---@field max_rows integer?
---@field max_record string|integer?

M.BUILTIN = {
  timeout = "30s", -- a query, when the URL sets none
  connect_timeout = "10s",
  max_rows = 10000,
  max_record = "1MB", -- the longest item of a push source
}

---The defaults in effect.
M.current = vim.deepcopy(M.BUILTIN)

---Set the defaults in effect (a missing value is the built-in one).
---@param t dbdash.db.Defaults
function M.set(t)
  for k, v in pairs(M.BUILTIN) do
    M.current[k] = t[k] or v
  end
end

return M
