-- Template lexer: splits source into data and tag tokens, applying Jinja whitespace rules
-- (trim_blocks, lstrip_blocks, "-"/"+" modifiers, keep_trailing_newline=False) and
-- handling {% raw %} blocks.
local errors = require("dbdash.template.errors")

local M = {}

---@alias dbdash.template.TokenType
---| "data"
---| "var_begin"
---| "var_end"
---| "block_begin"
---| "block_end"
---| "name"
---| "int"
---| "float"
---| "string"
---| "op"
---| "lua"
---| "eof"

---@class dbdash.template.Token
---@field t dbdash.template.TokenType
---@field v any
---@field line integer
---@field col integer

local OPS2 =
  { ["**"] = true, ["//"] = true, ["=="] = true, ["!="] = true, ["<="] = true, [">="] = true }
local OPS1 = {}
for c in ("+-*/%~|.,:()[]{}<>="):gmatch(".") do
  OPS1[c] = true
end
local OPEN = { ["("] = true, ["["] = true, ["{"] = true }
local CLOSE = { [")"] = true, ["]"] = true, ["}"] = true }

local SIMPLE_ESC = {
  n = "\n",
  t = "\t",
  r = "\r",
  a = "\a",
  b = "\b",
  f = "\f",
  v = "\v",
  ["\\"] = "\\",
  ["'"] = "'",
  ['"'] = '"',
  ["\n"] = "",
}

local utf8_char = require("dbdash.util.utf8").char

---@class dbdash.template.Lexer
---@field src string
---@field starts integer[] the byte offset of each line
---@field toks dbdash.template.Token[]
---@field pos integer where the next data starts
---@field strip_next boolean the next data loses its leading whitespace ("-")
local L = {}
L.__index = L

---Line and column of a byte offset.
function L:lc(pos)
  local starts = self.starts
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if starts[mid] <= pos then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo, pos - starts[lo] + 1
end

function L:fail(pos, msg, ...)
  local l, c = self:lc(pos)
  errors.syntax(l, c, msg, ...)
end

function L:push(t, v, pos)
  local l, c = self:lc(pos)
  self.toks[#self.toks + 1] = { t = t, v = v, line = l, col = c }
end

function L:push_data(s, at)
  if self.strip_next then
    s = s:gsub("^%s+", "")
    self.strip_next = false
  end
  if s ~= "" then
    self:push("data", s, at)
  end
end

---The data from `from` to a tag at `s`, without the whitespace "-" strips, or (lstrip_blocks,
---unless "+") the indentation of a block tag alone on its line.
function L:data_before(from, s, mod, is_var)
  local src = self.src
  local data = src:sub(from, s - 1)
  if mod == "-" then
    return (data:gsub("%s+$", ""))
  elseif not is_var and mod ~= "+" then
    local ls = self.starts[self:lc(s)]
    if ls >= from and src:sub(ls, s - 1):match("^[ \t]*$") then
      return src:sub(from, ls - 1)
    end
  end
  return data
end

---A string literal at `p` (Python escapes); returns its value and the position after it.
function L:read_string(p)
  local src = self.src
  local q = src:sub(p, p)
  local out, j = {}, p + 1
  while j <= #src do
    local ch = src:sub(j, j)
    if ch == q then
      return table.concat(out), j + 1
    elseif ch == "\\" then
      local e = src:sub(j + 1, j + 1)
      if SIMPLE_ESC[e] then
        out[#out + 1] = SIMPLE_ESC[e]
        j = j + 2
      elseif e == "x" or e == "u" or e == "U" then
        local n = ({ x = 2, u = 4, U = 8 })[e]
        local hex = src:sub(j + 2, j + 1 + n)
        if #hex ~= n or not hex:match("^%x+$") then
          self:fail(j, "invalid \\%s escape in string", e)
        end
        out[#out + 1] = utf8_char(tonumber(hex, 16))
        j = j + 2 + n
      elseif e:match("[0-7]") then
        local oct = src:match("^[0-7][0-7]?[0-7]?", j + 1)
        out[#out + 1] = utf8_char(tonumber(oct, 8))
        j = j + 1 + #oct
      else
        out[#out + 1] = "\\" -- unknown escapes are kept, like Python
        j = j + 1
      end
    else
      out[#out + 1] = ch
      j = j + 1
    end
  end
  self:fail(p, "unexpected end of string")
end

---A number at `p` (0x1f, 0o17, 0b101, 12, 1.5, 1e3; underscores allowed, like Python), or
---nil; returns the position after it.
function L:read_number(p)
  local src = self.src
  local lit = src:match("^0[xX][%x_]+", p)
    or src:match("^0[oO][0-7_]+", p)
    or src:match("^0[bB][01_]+", p)
  if lit then
    local base = ({ x = 16, o = 8, b = 2 })[lit:sub(2, 2):lower()]
    self:push("int", tonumber((lit:sub(3):gsub("_", "")), base), p)
    return p + #lit
  end
  if not src:sub(p, p):match("%d") then
    return nil
  end
  local num = src:match("^%d[%d_]*%.%d[%d_]*[eE][-+]?%d+", p)
    or src:match("^%d[%d_]*%.%d[%d_]*", p)
    or src:match("^%d[%d_]*[eE][-+]?%d+", p)
  if num then
    self:push("float", tonumber((num:gsub("_", ""))), p)
  else
    num = src:match("^%d[%d_]*", p)
    self:push("int", tonumber((num:gsub("_", ""))), p)
  end
  return p + #num
end

---An operator at `p`; `depth` counts open brackets. Returns the position after it and
---the depth.
function L:read_op(p, depth)
  local src = self.src
  local c, two = src:sub(p, p), src:sub(p, p + 1)
  local op = OPS2[two] and two or (OPS1[c] and c)
  if not op then
    self:fail(p, "unexpected char '%s'", c)
  end
  if OPEN[op] then
    depth = depth + 1
  elseif CLOSE[op] then
    depth = depth - 1
    if depth < 0 then
      self:fail(p, "unexpected '%s'", op)
    end
  end
  self:push("op", op, p)
  return p + #op, depth
end

---Lex expression tokens until the closing delimiter. Returns position after it and
---the end modifier ("-", "+" or nil).
function L:lex_expr(p, kind)
  local src = self.src
  local close = kind == "%" and "%}" or "}}"
  local depth = 0
  while true do
    p = src:match("^%s*()", p)
    if p > #src then
      self:fail(
        p - 1,
        "unexpected end of template, expected '%s'.",
        kind == "%" and "end of statement block" or "end of print statement"
      )
    end
    if depth == 0 then
      if src:sub(p, p + 1) == close then
        return p + 2, nil
      elseif
        src:sub(p + 1, p + 2) == close
        and (src:sub(p, p) == "-" or (kind == "%" and src:sub(p, p) == "+"))
      then
        return p + 3, src:sub(p, p)
      end
    end
    local c = src:sub(p, p)
    local name = src:match("^[%a_][%w_]*", p)
    if name then
      self:push("name", name, p)
      p = p + #name
    elseif c == "'" or c == '"' then
      local str, after = self:read_string(p)
      self:push("string", str, p)
      p = after
    else
      local after = self:read_number(p)
      if after then
        p = after
      else
        p, depth = self:read_op(p, depth)
      end
    end
  end
end

---{# comment #} at `s` (its text from `inner`).
function L:comment(s, inner)
  local src = self.src
  local e = src:find("#}", inner, true)
  if not e then
    self:fail(s, "missing end of comment tag")
  end
  self.pos = e + 2
  if src:sub(e - 1, e - 1) == "-" then
    self.strip_next = true
  elseif src:sub(self.pos, self.pos) == "\n" then
    self.pos = self.pos + 1
  end
end

---{% raw %}...{% endraw %} after a tag ending at self.pos: everything up to endraw is
---literal data. Returns endraw's end modifier.
function L:raw_block(s, endmod)
  local src, pos = self.src, self.pos
  local es, ee, m1, m2 = src:find("{%%([-+]?)%s*endraw%s*([-+]?)%%}", pos)
  if not es then
    self:fail(s, "missing {% endraw %}") -- no format arguments: % stays literal
  end
  self.strip_next = endmod == "-"
  local content = src:sub(pos, es - 1)
  if m1 == "-" then
    content = content:gsub("%s+$", "")
  elseif m1 ~= "+" then
    local ls = self.starts[self:lc(es)]
    if ls >= pos and src:sub(ls, es - 1):match("^[ \t]*$") then
      content = src:sub(pos, ls - 1)
    end
  end
  self:push_data(content, pos)
  self.pos = ee + 1
  return m2 ~= "" and m2 or nil
end

---{% lua %}...{% endlua %}: everything up to endlua is Lua code (its {{ and {% are Lua).
---Returns endlua's end modifier.
function L:lua_block(s)
  local es, ee, _, m2 = self.src:find("{%%([-+]?)%s*endlua%s*([-+]?)%%}", self.pos)
  if not es then
    self:fail(s, "missing {% endlua %}")
  end
  self:push("lua", self.src:sub(self.pos, es - 1), self.pos)
  self.pos = ee + 1
  return m2 ~= "" and m2 or nil
end

---A statement tag {% ... %} at `s`; {% raw %} and {% lua %} take their blocks.
function L:statement(s, inner)
  local toks = self.toks
  local first = #toks + 1
  self:push("block_begin", nil, s)
  local after, endmod = self:lex_expr(inner, "%")
  self:push("block_end", nil, after - 2)
  self.pos = after
  local t = toks[first + 1]
  local word = #toks == first + 2 and t.t == "name" and t.v
  if word == "raw" or word == "lua" then
    for k = #toks, first, -1 do
      toks[k] = nil
    end
    if word == "raw" then
      endmod = self:raw_block(s, endmod)
    else
      endmod = self:lua_block(s)
    end
  end
  if endmod == "-" then
    self.strip_next = true
  elseif endmod == nil and self.src:sub(self.pos, self.pos) == "\n" then
    self.pos = self.pos + 1 -- trim_blocks
  end
end

---Tokenize template source.
---@param src string
---@return dbdash.template.Token[]
function M.tokenize(src)
  src = src:gsub("\r\n", "\n")
  if src:sub(-1) == "\n" then
    src = src:sub(1, -2)
  end
  local starts = { 1 }
  for p in src:gmatch("()\n") do
    starts[#starts + 1] = p + 1
  end
  local lx = setmetatable({ src = src, starts = starts, toks = {}, pos = 1, strip_next = false }, L)
  while true do
    local s = src:find("{[{%%#]", lx.pos)
    if not s then
      lx:push_data(src:sub(lx.pos), lx.pos)
      break
    end
    local kind = src:sub(s + 1, s + 1)
    local mod = src:sub(s + 2, s + 2) ---@type string?
    local inner = s + 2
    if mod == "-" or (mod == "+" and kind ~= "{") then
      inner = inner + 1
    else
      mod = nil
    end
    lx:push_data(lx:data_before(lx.pos, s, mod, kind == "{"), lx.pos)
    if kind == "#" then
      lx:comment(s, inner)
    elseif kind == "{" then
      lx:push("var_begin", nil, s)
      local after, endmod = lx:lex_expr(inner, "{")
      lx:push("var_end", nil, after - 2)
      lx.pos = after
      lx.strip_next = endmod == "-"
    else
      lx:statement(s, inner)
    end
  end
  local l, c = lx:lc(#src + 1)
  lx.toks[#lx.toks + 1] = { t = "eof", line = l, col = c }
  return lx.toks
end

return M
