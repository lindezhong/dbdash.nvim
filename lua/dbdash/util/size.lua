-- Window size specs: a number of columns/rows, or "N%" of the editor's width/height.
-- Resolved once when a window opens.
local M = {}

---Check a size spec. Returns an error message for invalid values.
---@param v any
---@return string? err
function M.check(v)
  if type(v) == "number" then
    if v < 1 or v ~= math.floor(v) then
      return "must be a positive integer or a percentage like \"30%\""
    end
    return nil
  end
  if type(v) == "string" then
    local n = tonumber(vim.trim(v):match("^(%d+%.?%d*)%s*%%$"))
    if n and n > 0 and n <= 100 then
      return nil
    end
  end
  return ("invalid size %s (use a number of cells or a percentage like \"30%%\")"):format(vim.inspect(v))
end

---Resolve a size spec against `total` cells: numbers as they are, "N%" as
---floor(total * N / 100), at least 1.
---@param v integer|string
---@param total integer
---@return integer
function M.resolve(v, total)
  local err = M.check(v)
  if err then
    error(err, 2)
  end
  if type(v) == "number" then
    return v
  end
  local pct = tonumber(vim.trim(v):match("^(%d+%.?%d*)"))
  return math.max(1, math.floor(total * pct / 100))
end

return M
