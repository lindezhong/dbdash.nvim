-- Duration parsing shared by config files and connection URLs.
local M = {}

---Parse 30, "30s", "5m", "1h", "500ms" into milliseconds. Numbers are seconds.
---@param v any
---@return integer? ms, string? err
function M.parse(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  if type(v) == "number" then
    if v < 0 then
      return nil, "duration must not be negative"
    end
    return math.floor(v * 1000)
  end
  if type(v) ~= "string" then
    return nil, "duration must be a number or a string like 30s"
  end
  local n, unit = vim.trim(v):lower():match("^(%d+%.?%d*)%s*(%a*)$")
  local mult = ({ [""] = 1000, ms = 1, s = 1000, m = 60000, h = 3600000 })[unit or ""]
  if not n or not mult then
    return nil, ("invalid duration %q (use s, m, h or ms)"):format(v)
  end
  return math.floor(tonumber(n) * mult)
end

return M
