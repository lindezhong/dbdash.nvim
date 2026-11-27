-- ECMA-262 regular expressions (the dialect of JSON Schema's `pattern`), on Unicode code
-- points, with a backtracking matcher. Supported: literals, ., [classes] (ranges, negation,
-- escapes), \d \D \w \W \s \S \b \B, ^ $, groups (...) (?:...) (?<name>...), |, the
-- quantifiers * + ? {n} {n,} {n,m} (greedy and lazy), the escapes \t \n \r \f \v \0
-- \xHH \uHHHH \u{H...} \cX, and Unicode general categories \p{L} \p{Letter} \P{Nd}
-- \p{gc=Lu} (also Any, ASCII). Not supported (an error when compiled): backreferences,
-- lookaround ((?=, (?!, (?<=, (?<!) and other Unicode properties (scripts, binary ones).
local M = {}

---Code points of UTF-8 text.
local function cps(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
    local cp
    if len == 1 then
      cp = b
    elseif len == 2 then
      cp = (b % 0x20) * 0x40 + (s:byte(i + 1) or 0x80) % 0x40
    elseif len == 3 then
      cp = (b % 0x10) * 0x1000
        + ((s:byte(i + 1) or 0x80) % 0x40) * 0x40
        + (s:byte(i + 2) or 0x80) % 0x40
    else
      cp = (b % 0x08) * 0x40000
        + ((s:byte(i + 1) or 0x80) % 0x40) * 0x1000
        + ((s:byte(i + 2) or 0x80) % 0x40) * 0x40
        + (s:byte(i + 3) or 0x80) % 0x40
    end
    out[#out + 1] = cp
    i = i + len
  end
  return out
end
M.codepoints = cps

local function fail(msg, ...)
  error({ regex = true, message = msg:format(...) }, 0)
end

local function is_digit(c)
  return c >= 48 and c <= 57
end
local function is_word(c)
  return is_digit(c) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
end
-- ECMAScript WhiteSpace and LineTerminator.
local SPACE = {
  [9] = true,
  [10] = true,
  [11] = true,
  [12] = true,
  [13] = true,
  [32] = true,
  [0xA0] = true,
  [0x1680] = true,
  [0x2028] = true,
  [0x2029] = true,
  [0x202F] = true,
  [0x205F] = true,
  [0x3000] = true,
  [0xFEFF] = true,
}
for c = 0x2000, 0x200A do
  SPACE[c] = true
end
local function is_space(c)
  return SPACE[c] == true
end
local LINE_END = { [10] = true, [13] = true, [0x2028] = true, [0x2029] = true }

-- Parser: pattern (code points) -> AST ---------------------------------------------------------
--   { t = "char", c }, { t = "any" }, { t = "set", items, neg }, { t = "seq", list },
--   { t = "alt", list }, { t = "group", node }, { t = "rep", node, min, max, lazy },
--   { t = "bol" }, { t = "eol" }, { t = "wordb", neg }

local P = {}
P.__index = P

function P:peek(k)
  return self.s[self.i + (k or 0)]
end

function P:next()
  local c = self.s[self.i]
  self.i = self.i + 1
  return c
end

local function ch(c)
  return string.char(c)
end

-- Unicode general categories (\p{...}) --------------------------------------------------------

local LONG = {
  Letter = "L",
  Cased_Letter = "LC",
  Uppercase_Letter = "Lu",
  Lowercase_Letter = "Ll",
  Titlecase_Letter = "Lt",
  Modifier_Letter = "Lm",
  Other_Letter = "Lo",
  Mark = "M",
  Nonspacing_Mark = "Mn",
  Spacing_Mark = "Mc",
  Enclosing_Mark = "Me",
  Number = "N",
  Decimal_Number = "Nd",
  Letter_Number = "Nl",
  Other_Number = "No",
  Punctuation = "P",
  Connector_Punctuation = "Pc",
  Dash_Punctuation = "Pd",
  Open_Punctuation = "Ps",
  Close_Punctuation = "Pe",
  Initial_Punctuation = "Pi",
  Final_Punctuation = "Pf",
  Other_Punctuation = "Po",
  Symbol = "S",
  Math_Symbol = "Sm",
  Currency_Symbol = "Sc",
  Modifier_Symbol = "Sk",
  Other_Symbol = "So",
  Separator = "Z",
  Space_Separator = "Zs",
  Line_Separator = "Zl",
  Paragraph_Separator = "Zp",
  Other = "C",
  Control = "Cc",
  Format = "Cf",
  Surrogate = "Cs",
  Private_Use = "Co",
  Unassigned = "Cn",
  digit = "Nd",
  punct = "P",
}
local GROUPS = {
  L = { "Lu", "Ll", "Lt", "Lm", "Lo" },
  LC = { "Lu", "Ll", "Lt" },
  M = { "Mn", "Mc", "Me" },
  N = { "Nd", "Nl", "No" },
  P = { "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po" },
  S = { "Sm", "Sc", "Sk", "So" },
  Z = { "Zs", "Zl", "Zp" },
  C = { "Cc", "Cf", "Cs", "Co", "Cn" },
}

local categories
local function in_ranges(r, c)
  local lo, hi = 1, #r / 2
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if c < r[2 * mid - 1] then
      hi = mid - 1
    elseif c > r[2 * mid] then
      lo = mid + 1
    else
      return true
    end
  end
  return false
end

---A predicate for \p{name}; raises for names that are not general categories.
local function property(name)
  local value = name:match("^General_Category=(.+)$") or name:match("^gc=(.+)$") or name
  if value == "Any" then
    return function()
      return true
    end
  elseif value == "ASCII" then
    return function(c)
      return c < 128
    end
  end
  local short = LONG[value] or value
  local list = GROUPS[short] or { short }
  categories = categories or require("dbdash.util.unicode_categories")
  local tables = {}
  for _, cat in ipairs(list) do
    if cat ~= "Cn" and not categories[cat] then
      fail("Unicode property \\p{%s} is not supported (general categories only)", name)
    end
    tables[#tables + 1] = cat
  end
  return function(c)
    for _, cat in ipairs(tables) do
      if cat == "Cn" then
        local assigned = false
        for _, r in pairs(categories) do
          if in_ranges(r, c) then
            assigned = true
            break
          end
        end
        if not assigned then
          return true
        end
      elseif in_ranges(categories[cat], c) then
        return true
      end
    end
    return false
  end
end

---A class escape (\d \w \s and their negations) as a set item, or nil.
local function class_escape(c)
  if c == 100 then -- d
    return { fn = is_digit }
  elseif c == 68 then -- D
    return { fn = is_digit, neg = true }
  elseif c == 119 then -- w
    return { fn = is_word }
  elseif c == 87 then -- W
    return { fn = is_word, neg = true }
  elseif c == 115 then -- s
    return { fn = is_space }
  elseif c == 83 then -- S
    return { fn = is_space, neg = true }
  end
end

local function hex(p, n)
  local v = 0
  for _ = 1, n do
    local c = p:next()
    local d = c and tonumber(ch(c), 16)
    if not d then
      fail("invalid hexadecimal escape")
    end
    v = v * 16 + d
  end
  return v
end

---A character escape after "\" (not a class escape): its code point.
function P:char_escape(c)
  if c == 116 then
    return 9
  elseif c == 110 then
    return 10
  elseif c == 114 then
    return 13
  elseif c == 102 then
    return 12
  elseif c == 118 then
    return 11
  elseif c == 48 then -- \0 (not followed by a digit)
    if self:peek() and is_digit(self:peek()) then
      fail("octal escapes are not supported")
    end
    return 0
  elseif c == 120 then -- \xHH
    return hex(self, 2)
  elseif c == 117 then -- \uHHHH, \u{H...}
    if self:peek() == 123 then
      self:next()
      local v = 0
      while self:peek() and self:peek() ~= 125 do
        local d = tonumber(ch(self:next()), 16)
        if not d then
          fail("invalid \\u{...} escape")
        end
        v = v * 16 + d
      end
      if not self:next() then
        fail("unterminated \\u{...} escape")
      end
      return v
    end
    local v = hex(self, 4)
    -- A surrogate pair written as two \u escapes.
    if v >= 0xD800 and v <= 0xDBFF and self:peek() == 92 and self:peek(1) == 117 then
      local save = self.i
      self.i = self.i + 2
      local ok, lo = pcall(hex, self, 4)
      if ok and lo >= 0xDC00 and lo <= 0xDFFF then
        return 0x10000 + (v - 0xD800) * 0x400 + (lo - 0xDC00)
      end
      self.i = save
    end
    return v
  elseif c == 99 then -- \cX
    local x = self:next()
    if not x or not ((x >= 65 and x <= 90) or (x >= 97 and x <= 122)) then
      fail("invalid \\c escape")
    end
    return x % 32
  elseif is_digit(c) then
    fail("backreferences are not supported")
  elseif c == 107 then
    fail("named backreferences are not supported")
  end
  return c -- an escaped punctuation character stands for itself
end

---\p{name} / \P{name} after "\p": a set item.
function P:prop(neg)
  if self:next() ~= 123 then
    fail("\\p must be followed by {name}")
  end
  local name = {}
  while self:peek() and self:peek() ~= 125 do
    name[#name + 1] = ch(self:next())
  end
  if not self:next() then
    fail("unterminated \\p{...}")
  end
  return { fn = property(table.concat(name)), neg = neg }
end

function P:set()
  local items, neg = {}, false
  if self:peek() == 94 then
    self:next()
    neg = true
  end
  local first = true
  while true do
    local c = self:next()
    if not c then
      fail("missing ]")
    end
    if c == 93 and not first then
      break
    end
    first = false
    local lo
    if c == 92 then
      local e = self:next()
      if not e then
        fail("\\ at end of pattern")
      end
      local cls = class_escape(e)
      if cls then
        items[#items + 1] = cls
      elseif e == 112 or e == 80 then -- \p{...}, \P{...}
        items[#items + 1] = self:prop(e == 80)
      elseif e == 98 then -- \b in a class is backspace
        lo = 8
      elseif e == 45 then
        lo = 45
      else
        lo = self:char_escape(e)
      end
    else
      lo = c
    end
    if lo then
      if self:peek() == 45 and self:peek(1) and self:peek(1) ~= 93 then
        self:next()
        local hc = self:next()
        local hi
        if hc == 92 then
          local e = self:next()
          if class_escape(e) then
            fail("invalid range in a character class")
          end
          hi = e == 98 and 8 or self:char_escape(e)
        else
          hi = hc
        end
        if hi < lo then
          fail("range out of order in a character class")
        end
        items[#items + 1] = { lo = lo, hi = hi }
      else
        items[#items + 1] = { lo = lo, hi = lo }
      end
    end
  end
  return { t = "set", items = items, neg = neg }
end

function P:atom()
  local c = self:next()
  if c == 46 then
    return { t = "any" }
  elseif c == 94 then
    return { t = "bol" }
  elseif c == 36 then
    return { t = "eol" }
  elseif c == 91 then
    return self:set()
  elseif c == 40 then
    if self:peek() == 63 then -- (?
      local k = self:peek(1)
      if k == 58 then -- (?:
        self.i = self.i + 2
      elseif k == 60 and self:peek(2) ~= 61 and self:peek(2) ~= 33 then -- (?<name>
        self.i = self.i + 2
        while self:peek() and self:peek() ~= 62 do
          self:next()
        end
        if not self:next() then
          fail("unterminated group name")
        end
      else
        fail("lookaround assertions are not supported")
      end
    end
    local node = self:alt()
    if self:next() ~= 41 then
      fail("missing )")
    end
    return { t = "group", node = node }
  elseif c == 92 then
    local e = self:next()
    if not e then
      fail("\\ at end of pattern")
    end
    local cls = class_escape(e)
    if cls then
      return { t = "set", items = { cls }, neg = false }
    elseif e == 112 or e == 80 then
      return { t = "set", items = { self:prop(e == 80) }, neg = false }
    elseif e == 98 then
      return { t = "wordb" }
    elseif e == 66 then
      return { t = "wordb", neg = true }
    end
    return { t = "char", c = self:char_escape(e) }
  elseif c == 41 then
    fail("unmatched )")
  elseif c == 42 or c == 43 or c == 63 then
    fail("nothing to repeat")
  end
  return { t = "char", c = c }
end

---{n}, {n,}, {n,m} at the current position, or nil (then "{" is a literal).
function P:braces()
  local j = self.i + 1
  local function num()
    local v
    while self.s[j] and is_digit(self.s[j]) do
      v = (v or 0) * 10 + self.s[j] - 48
      j = j + 1
    end
    return v
  end
  local lo = num()
  if not lo then
    return nil
  end
  local hi = lo
  if self.s[j] == 44 then
    j = j + 1
    hi = num() or math.huge
  end
  if self.s[j] ~= 125 then
    return nil
  end
  self.i = j + 1
  if hi < lo then
    fail("numbers out of order in {} quantifier")
  end
  return lo, hi
end

function P:term()
  local a = self:atom()
  while true do
    local c = self:peek()
    local lo, hi
    if c == 42 then
      self:next()
      lo, hi = 0, math.huge
    elseif c == 43 then
      self:next()
      lo, hi = 1, math.huge
    elseif c == 63 then
      self:next()
      lo, hi = 0, 1
    elseif c == 123 then
      lo, hi = self:braces()
      if not lo then
        return a
      end
    else
      return a
    end
    if a.t == "bol" or a.t == "eol" or a.t == "wordb" then
      fail("nothing to repeat")
    end
    local lazy = false
    if self:peek() == 63 then
      self:next()
      lazy = true
    end
    a = { t = "rep", node = a, min = lo, max = hi, lazy = lazy }
  end
end

function P:seq()
  local list = {}
  while self:peek() and self:peek() ~= 124 and self:peek() ~= 41 do
    list[#list + 1] = self:term()
  end
  return { t = "seq", list = list }
end

function P:alt()
  local list = { self:seq() }
  while self:peek() == 124 do
    self:next()
    list[#list + 1] = self:seq()
  end
  if #list == 1 then
    return list[1]
  end
  return { t = "alt", list = list }
end

-- Matcher -------------------------------------------------------------------------------

local function set_has(node, c)
  local hit = false
  for _, it in ipairs(node.items) do
    if it.fn then
      local r = it.fn(c)
      if it.neg then
        r = not r
      end
      if r then
        hit = true
        break
      end
    elseif c >= it.lo and c <= it.hi then
      hit = true
      break
    end
  end
  if node.neg then
    return not hit
  end
  return hit
end

---Does `node` match a single code point (for fast repetition)?
local function single(node)
  return node.t == "char" or node.t == "any" or node.t == "set"
end

local function single_ok(node, c)
  if c == nil then
    return false
  elseif node.t == "char" then
    return c == node.c
  elseif node.t == "any" then
    return not LINE_END[c]
  end
  return set_has(node, c)
end

---Match `node` against `s` (code points) at `i`; `k(j)` continues with the rest.
local function m(node, s, i, k)
  local t = node.t
  if t == "char" or t == "any" or t == "set" then
    if single_ok(node, s[i]) then
      return k(i + 1)
    end
    return false
  elseif t == "seq" then
    local list = node.list
    local function step(n, j)
      if n > #list then
        return k(j)
      end
      return m(list[n], s, j, function(j2)
        return step(n + 1, j2)
      end)
    end
    return step(1, i)
  elseif t == "alt" then
    for _, a in ipairs(node.list) do
      if m(a, s, i, k) then
        return true
      end
    end
    return false
  elseif t == "group" then
    return m(node.node, s, i, k)
  elseif t == "bol" then
    return i == 1 and k(i)
  elseif t == "eol" then
    return i == #s + 1 and k(i)
  elseif t == "wordb" then
    local a = i > 1 and is_word(s[i - 1])
    local b = i <= #s and is_word(s[i])
    local at = a ~= b
    if node.neg then
      at = not at
    end
    return at and k(i)
  elseif t == "rep" then
    local sub, min, max = node.node, node.min, node.max
    if single(sub) then
      -- One code point per repetition: count how far it can go, then back off.
      local n = 0
      while n < max and single_ok(sub, s[i + n]) do
        n = n + 1
      end
      if n < min then
        return false
      end
      if node.lazy then
        for c = min, n do
          if k(i + c) then
            return true
          end
        end
      else
        for c = n, min, -1 do
          if k(i + c) then
            return true
          end
        end
      end
      return false
    end
    local function rep(count, j)
      local function more()
        if count >= max then
          return false
        end
        return m(sub, s, j, function(j2)
          if j2 == j and count >= min then
            return false -- an empty repetition would loop for ever
          end
          return rep(count + 1, j2)
        end)
      end
      if count < min then
        return more()
      end
      if node.lazy then
        return k(j) or more()
      end
      return more() or k(j)
    end
    return rep(0, i)
  end
  error("regex: unknown node " .. tostring(t))
end

---Compile `pattern`; raises { regex = true, message } for invalid or unsupported ones.
---@return { test: fun(self, s: string): boolean }
function M.compile(pattern)
  local p = setmetatable({ s = cps(pattern), i = 1 }, P)
  local ast = p:alt()
  if p.i <= #p.s then
    fail("unmatched )")
  end
  return {
    pattern = pattern,
    ---True when the pattern matches somewhere in `s` (not anchored, like JSON Schema).
    test = function(_, s)
      local c = cps(s)
      for i = 1, #c + 1 do
        if m(ast, c, i, function()
          return true
        end) then
          return true
        end
      end
      return false
    end,
  }
end

local cache = setmetatable({}, { __mode = "v" })

---Compiled pattern (cached); nil and the error message when it is invalid.
function M.get(pattern)
  local r = cache[pattern]
  if r then
    return r
  end
  local ok, res = pcall(M.compile, pattern)
  if not ok then
    return nil, type(res) == "table" and res.message or tostring(res)
  end
  cache[pattern] = res
  return res
end

return M
