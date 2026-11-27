-- Numbers as Python writes them (repr): the template engine's output, and values written
-- into SQL. A float with an integral value (2.0) is boxed (Float) so it keeps its ".0".
local M = {}

local Float = {}
Float.__index = Float
M.Float = Float

---A float: boxed when its value is integral (2.0), else the plain number.
---@param x number
function M.float(x)
  if x == x and x ~= math.huge and x ~= -math.huge and x == math.floor(x) then
    return setmetatable({ v = x }, Float)
  end
  return x
end

---True for a boxed integral float.
function M.is_float_box(v)
  return getmetatable(v) == Float
end

---Python repr() of a float (boxed or plain).
function M.floatstr(v)
  if getmetatable(v) == Float then
    v = v.v
  end
  if v == math.floor(v) and math.abs(v) < 1e16 then
    return ("%.0f"):format(v) .. ".0"
  end
  return M.numstr(v)
end

---Python repr() of a float/int.
function M.numstr(v)
  if getmetatable(v) == Float then
    return M.floatstr(v)
  end
  if v ~= v then
    return "nan"
  elseif v == math.huge then
    return "inf"
  elseif v == -math.huge then
    return "-inf"
  elseif v == math.floor(v) and math.abs(v) < 1e16 then
    return ("%.0f"):format(v)
  end
  local s
  for p = 1, 17 do
    s = ("%." .. p .. "e"):format(v)
    if tonumber(s) == v then
      break
    end
  end
  -- s looks like "-1.2345e-05": rebuild in Python's repr style.
  local sign, int, frac, exp = s:match("^(-?)(%d)%.?(%d*)e([-+]%d+)$")
  local digits = (int .. frac):gsub("0+$", "")
  if digits == "" then
    digits = "0"
  end
  exp = tonumber(exp) or 0 -- (the pattern matched digits)
  if exp >= -4 and exp < 16 then
    if exp < 0 then
      return sign .. "0." .. string.rep("0", -exp - 1) .. digits
    end
    local ip = digits:sub(1, exp + 1)
    ip = ip .. string.rep("0", exp + 1 - #ip)
    local fp = digits:sub(exp + 2)
    return sign .. ip .. "." .. (fp == "" and "0" or fp)
  end
  local m = digits:sub(1, 1) .. (#digits > 1 and ("." .. digits:sub(2)) or "")
  return ("%s%se%s%02d"):format(sign, m, exp < 0 and "-" or "+", math.abs(exp))
end

return M
