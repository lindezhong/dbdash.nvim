-- Read-only views of tables, for values Lua code may read but not change (meta).
local M = {}

---A table that reads `values` and raises "<name> is read-only (<name>.<key>)" on writes;
---pairs() walks `values`.
---@param values table
---@param name string
---@return table
function M.proxy(values, name)
  return setmetatable({}, {
    __index = values,
    __newindex = function(_, k)
      error(("%s is read-only (%s.%s)"):format(name, name, tostring(k)), 2)
    end,
    __pairs = function()
      return next, values, nil
    end,
  })
end

return M
