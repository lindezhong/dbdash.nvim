-- Python's str() and repr() of plain data (strings, numbers, booleans, None, safe strings,
-- lists and ordered mappings): what templates print, and the text of non-string map keys
-- from databases. The template engine adds its own values (tuples, loops, macros, ...).
local map = require("dbdash.util.map")
local markup = require("dbdash.util.markup")
local number = require("dbdash.util.number")

local M = {}

---Python repr() of a string.
function M.strrepr(s)
  local q = "'"
  if s:find("'", 1, true) and not s:find('"', 1, true) then
    q = '"'
  end
  local out = s:gsub("[\\\n\r\t%c" .. q .. "]", function(c)
    if c == "\\" then
      return "\\\\"
    elseif c == "\n" then
      return "\\n"
    elseif c == "\r" then
      return "\\r"
    elseif c == "\t" then
      return "\\t"
    elseif c == q then
      return "\\" .. q
    end
    return ("\\x%02x"):format(c:byte())
  end)
  return q .. out .. q
end

---Python repr() of plain data; `rec` writes nested values (default: this function).
---@param rec (fun(v: any): string)?
function M.repr(v, rec)
  rec = rec or M.repr
  if type(v) == "string" then
    return M.strrepr(v)
  elseif markup.is_safe(v) then
    return "Markup(" .. M.strrepr(v.s) .. ")"
  elseif map.is_map(v) then
    local parts = {}
    for k, x in map.pairs(v) do
      parts[#parts + 1] = rec(k) .. ": " .. rec(x)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif type(v) == "table" and v ~= vim.NIL and getmetatable(v) == nil then
    local parts = {}
    for i = 1, #v do
      parts[i] = rec(v[i])
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return M.str(v)
end

---Python str() of plain data.
function M.str(v)
  local t = type(v)
  if t == "string" then
    return v
  elseif t == "number" then
    return number.numstr(v)
  elseif number.is_float_box(v) then
    return number.floatstr(v)
  elseif v == true then
    return "True"
  elseif v == false then
    return "False"
  elseif v == vim.NIL or v == nil then
    return "None"
  elseif markup.is_safe(v) then
    return v.s
  elseif t == "table" then
    return M.repr(v)
  end
  return tostring(v)
end

return M
