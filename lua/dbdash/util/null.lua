-- NULL (vim.NIL: JSON null, a NULL value of a database) as Lua's nil.
local M = {}

---`v`, or nil when it is vim.NIL.
---@generic T
---@param v T
---@return T?
function M.nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

return M
