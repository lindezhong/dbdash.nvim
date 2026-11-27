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

---@class dbdash.util.json.Parser
---@field s string
---@field i integer the position
local P = {}
P.__index = P

local ESC =
  { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

function P:fail(msg)
  require("dbdash.util.error").raise("query", ("invalid JSON at offset %d: %s"):format(self.i, msg))
end

function P:ws()
  self.i = self.s:match("^[ \t\r\n]*()", self.i)
end

---A \u escape at j (a surrogate pair joined); returns its character.
function P:unicode(j)
  local s = self.s
  local cp = tonumber(s:sub(j + 2, j + 5), 16)
  if not cp then
    self:fail("bad \\u escape")
  end
  self.i = j + 6
  local i = self.i
  if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
    local lo = tonumber(s:sub(i + 2, i + 5), 16)
    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
      cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
      self.i = i + 6
    end
  end
  return require("dbdash.util.utf8").char(cp)
end

function P:string()
  local s = self.s
  self.i = self.i + 1
  local out = {}
  while true do
    local j = s:find('["\\]', self.i)
    if not j then
      self:fail("unterminated string")
    end
    out[#out + 1] = s:sub(self.i, j - 1)
    if s:sub(j, j) == '"' then
      self.i = j + 1
      return table.concat(out)
    end
    local e = s:sub(j + 1, j + 1)
    if e == "u" then
      out[#out + 1] = self:unicode(j)
    elseif ESC[e] then
      out[#out + 1] = ESC[e]
      self.i = j + 2
    else
      self:fail("bad escape")
    end
  end
end

---After a member or an element: `close` ends it (true), "," goes on.
function P:next_or(close)
  self:ws()
  local d = self.s:sub(self.i, self.i)
  self.i = self.i + 1
  if d == close then
    return true
  elseif d ~= "," then
    self:fail(("expected ',' or '%s'"):format(close))
  end
end

---An object: an ordered mapping.
function P:object()
  local s = self.s
  self.i = self.i + 1
  local m = map.new()
  self:ws()
  if s:sub(self.i, self.i) == "}" then
    self.i = self.i + 1
    return m
  end
  repeat
    self:ws()
    if s:sub(self.i, self.i) ~= '"' then
      self:fail("expected a string key")
    end
    local k = self:string()
    self:ws()
    if s:sub(self.i, self.i) ~= ":" then
      self:fail("expected ':'")
    end
    self.i = self.i + 1
    map.set(m, k, self:value())
  until self:next_or("}")
  return m
end

function P:array()
  self.i = self.i + 1
  local a = {}
  self:ws()
  if self.s:sub(self.i, self.i) == "]" then
    self.i = self.i + 1
    return a
  end
  repeat
    a[#a + 1] = self:value()
  until self:next_or("]")
  return a
end

---A number: a Double box when written with a fraction or an exponent, an Int64 box past
---2^53, else a Lua number.
function P:number(c)
  local num = self.s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", self.i)
  if not num or num == "" or num == "-" then
    self:fail("unexpected character '" .. c .. "'")
  end
  self.i = self.i + #num
  local n = tonumber(num)
  if not n then
    self:fail("bad number")
  end
  if num:find("[.eE]") then
    return M.double(n)
  end
  if math.abs(n) >= 2 ^ 53 then
    return M.int64(num)
  end
  return n
end

local WORDS = { { "true", true }, { "false", false }, { "null", vim.NIL } }

function P:value()
  self:ws()
  local s, i = self.s, self.i
  local c = s:sub(i, i)
  if c == "{" then
    return self:object()
  elseif c == "[" then
    return self:array()
  elseif c == '"' then
    return self:string()
  end
  for _, w in ipairs(WORDS) do
    if s:sub(i, i + #w[1] - 1) == w[1] then
      self.i = i + #w[1]
      return w[2]
    end
  end
  return self:number(c)
end

---Parse JSON keeping object key order (ordered mappings). Integers and floats are told
---apart with `is_float[value_table][key]`-free semantics: numbers written with a fraction
---or exponent are returned as M.Double boxes so BSON can encode them as doubles.
---@param s string
---@return any
function M.parse(s)
  local p = setmetatable({ s = s, i = 1 }, P)
  local v = p:value()
  p:ws()
  if p.i <= #s then
    p:fail("trailing characters")
  end
  return v
end

-- Boxes that keep JSON number kinds for BSON encoding.
local Double = {
  __tostring = function(d)
    return tostring(d.v)
  end,
}
local Int64 = {
  __tostring = function(d)
    return d.s
  end,
}

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
