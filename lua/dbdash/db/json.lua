-- JSON decoding for driver values: objects become ordered mappings (keys sorted, since
-- vim.json does not keep their order), arrays stay lists, null is db.NULL.
local map = require("dbdash.util.map")

local M = {}

local EMPTY_DICT_MT = getmetatable(vim.empty_dict())

local function convert(v)
  if type(v) ~= "table" or v == vim.NIL then
    return v
  end
  if getmetatable(v) ~= EMPTY_DICT_MT and vim.islist(v) then
    local out = {}
    for i, x in ipairs(v) do
      out[i] = convert(x)
    end
    return out
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys)
  local m = map.new()
  for _, k in ipairs(keys) do
    map.set(m, k, convert(v[k]))
  end
  return m
end

---Decode JSON text; returns the original string when it is not valid JSON.
function M.decode(s)
  local ok, v = pcall(vim.json.decode, s, { luanil = { object = false, array = false } })
  if not ok then
    return s
  end
  return convert(v)
end

---Parse JSON keeping object key order (ordered mappings). Integers and floats are told
---apart with `is_float[value_table][key]`-free semantics: numbers written with a fraction
---or exponent are returned as M.Double boxes so BSON can encode them as doubles.
---@param s string
---@return any
function M.parse(s)
  local i = 1
  local function fail(msg)
    error({ phase = "query", message = ("invalid JSON at offset %d: %s"):format(i, msg) }, 0)
  end
  local function ws()
    i = s:match("^[ \t\r\n]*()", i)
  end
  local value
  local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
  local function str()
    i = i + 1
    local out = {}
    while true do
      local j = s:find('["\\]', i)
      if not j then
        fail("unterminated string")
      end
      out[#out + 1] = s:sub(i, j - 1)
      if s:sub(j, j) == '"' then
        i = j + 1
        return table.concat(out)
      end
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local cp = tonumber(s:sub(j + 2, j + 5), 16)
        if not cp then
          fail("bad \\u escape")
        end
        i = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
          local lo = tonumber(s:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = require("dbdash.template.lexer").utf8_char(cp)
      elseif ESC[e] then
        out[#out + 1] = ESC[e]
        i = j + 2
      else
        fail("bad escape")
      end
    end
  end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      i = i + 1
      local m = map.new()
      ws()
      if s:sub(i, i) == "}" then
        i = i + 1
        return m
      end
      while true do
        ws()
        if s:sub(i, i) ~= '"' then
          fail("expected a string key")
        end
        local k = str()
        ws()
        if s:sub(i, i) ~= ":" then
          fail("expected ':'")
        end
        i = i + 1
        map.set(m, k, value())
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "}" then
          return m
        elseif d ~= "," then
          fail("expected ',' or '}'")
        end
      end
    elseif c == "[" then
      i = i + 1
      local a = {}
      ws()
      if s:sub(i, i) == "]" then
        i = i + 1
        return a
      end
      while true do
        a[#a + 1] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "]" then
          return a
        elseif d ~= "," then
          fail("expected ',' or ']'")
        end
      end
    elseif c == '"' then
      return str()
    elseif s:sub(i, i + 3) == "true" then
      i = i + 4
      return true
    elseif s:sub(i, i + 4) == "false" then
      i = i + 5
      return false
    elseif s:sub(i, i + 3) == "null" then
      i = i + 4
      return vim.NIL
    end
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" or num == "-" then
      fail("unexpected character '" .. c .. "'")
    end
    i = i + #num
    local n = tonumber(num)
    if not n then
      fail("bad number")
    end
    if num:find("[.eE]") then
      return M.double(n)
    end
    if math.abs(n) >= 2 ^ 53 then
      return M.int64(num)
    end
    return n
  end
  local v = value()
  ws()
  if i <= #s then
    fail("trailing characters")
  end
  return v
end

-- Boxes that keep JSON number kinds for BSON encoding.
local Double = { __tostring = function(d)
  return tostring(d.v)
end }
local Int64 = { __tostring = function(d)
  return d.s
end }

function M.double(v)
  return setmetatable({ v = v }, Double)
end
function M.is_double(x)
  return getmetatable(x) == Double
end
function M.int64(s)
  return setmetatable({ s = s }, Int64)
end
function M.is_int64(x)
  return getmetatable(x) == Int64
end

return M
