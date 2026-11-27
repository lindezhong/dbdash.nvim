-- Number formatting for axis labels and values.
local M = {}

local function group_thousands(s)
  local sign, int, rest = s:match("^(-?)(%d+)(.*)$")
  if not int then
    return s
  end
  int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return sign .. int .. rest
end

---Format with a Python format-spec subset: "{:,.2f}", "{:.1%}", "{:d}", "{:,}", "{}".
---Returns nil when the spec is not understood.
---@param v number
---@param spec string
---@return string?
function M.python(v, spec)
  -- Text around one field is kept, as in Python: "{:.0f}%", "$ {:,.2f}", "{:,} users".
  local pre, inner, post = spec:match("^([^{]*){:?([^}]*)}(.*)$")
  if not inner then
    return nil
  end
  if pre ~= "" or post ~= "" then
    local s = M.python(v, "{:" .. inner .. "}")
    return s and (pre .. s .. post) or nil
  end
  local comma, prec, kind = inner:match("^(,?)%.?(%d*)([fd%%eg]?)$")
  if not comma then
    return nil
  end
  local s
  if kind == "%" then
    s = ("%." .. (prec ~= "" and prec or "0") .. "f"):format(v * 100) .. "%"
    return comma ~= "" and group_thousands(s) or s
  elseif kind == "d" then
    s = ("%d"):format(math.floor(v + 0.5))
  elseif kind == "f" or prec ~= "" then
    s = ("%." .. (prec ~= "" and prec or "6") .. "f"):format(v)
  elseif kind == "e" or kind == "g" then
    s = ("%" .. (prec ~= "" and ("." .. prec) or "") .. kind):format(v)
  else
    s = require("dbdash.util.number").numstr(v)
  end
  return comma ~= "" and group_thousands(s) or s
end

---Shortest readable text for a number: integers as is, others with up to `digits`
---significant decimals, large magnitudes compacted (12.5k, 3.4M).
---@param v number
---@param decimals integer? fixed number of decimals
function M.number(v, decimals)
  if v ~= v then
    return "NaN"
  end
  local a = math.abs(v)
  if a >= 1e6 then
    for _, u in ipairs({ { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" } }) do
      if a >= u[1] then
        local s = ("%.2f"):format(v / u[1]):gsub("%.?0+$", "")
        return s .. u[2]
      end
    end
  end
  if decimals then
    return ("%." .. decimals .. "f"):format(v)
  end
  if v == math.floor(v) then
    return ("%d"):format(v)
  end
  local s = ("%.4g"):format(v)
  if s:find("e") then
    s = ("%.4f"):format(v):gsub("0+$", ""):gsub("%.$", "")
  end
  return s
end

---Value label honoring an optional python-style format.
function M.value(v, fmt)
  if fmt then
    local s = M.python(v, fmt)
    if s then
      return s
    end
  end
  return M.number(v)
end

---Display text for a cell value. Line breaks become "↵" unless `keep_lines` (wrapping
---tables break the cell there).
---@return string text, boolean is_null
function M.value_text(v, ltype, null_text, keep_lines)
  if v == nil or v == vim.NIL then
    return null_text, true
  end
  local t = type(v)
  local s
  if t == "string" then
    if ltype == "bytes" then
      s = "\\x" .. require("dbdash.crypto.util").hex(v)
    else
      s = v
    end
  elseif t == "number" then
    s = require("dbdash.util.number").numstr(v)
  elseif t == "boolean" then
    s = v and "true" or "false"
  elseif t == "table" then
    local ok, j = pcall(vim.json.encode, v)
    s = ok and j or tostring(v)
  else
    s = tostring(v)
  end
  s = s:gsub("\r\n?", "\n"):gsub("\t", " ")
  if not keep_lines then
    s = s:gsub("\n", "↵")
  end
  return s, false
end

return M
