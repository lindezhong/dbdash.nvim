-- Template lexer: splits source into data and tag tokens, applying Jinja whitespace rules
-- (trim_blocks, lstrip_blocks, "-"/"+" modifiers, keep_trailing_newline=False) and
-- handling {% raw %} blocks.
local errors = require("dbdash.template.errors")

local M = {}

---@class dbdash.template.Token
---@field t "data"|"var_begin"|"var_end"|"block_begin"|"block_end"|"name"|"int"|"float"|"string"|"op"|"eof"
---@field v any
---@field line integer
---@field col integer

local OPS2 = { ["**"] = true, ["//"] = true, ["=="] = true, ["!="] = true, ["<="] = true, [">="] = true }
local OPS1 = {}
for c in ("+-*/%~|.,:()[]{}<>="):gmatch(".") do
  OPS1[c] = true
end
local OPEN = { ["("] = true, ["["] = true, ["{"] = true }
local CLOSE = { [")"] = true, ["]"] = true, ["}"] = true }

local SIMPLE_ESC = {
  n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v",
  ["\\"] = "\\", ["'"] = "'", ['"'] = '"', ["\n"] = "",
}

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end
M.utf8_char = utf8_char

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
  ---Line and column of a byte offset.
  local function lc(pos)
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
  local function fail(pos, msg, ...)
    local l, c = lc(pos)
    errors.syntax(l, c, msg, ...)
  end

  local toks = {}
  local function push(t, v, pos)
    local l, c = lc(pos)
    toks[#toks + 1] = { t = t, v = v, line = l, col = c }
  end

  local pos = 1
  local strip_next = false

  local function push_data(s, at)
    if strip_next then
      s = s:gsub("^%s+", "")
      strip_next = false
    end
    if s ~= "" then
      push("data", s, at)
    end
  end

  ---Data preceding a tag at `s`, after "-" or lstrip_blocks handling.
  local function data_before(s, mod, is_var)
    local data = src:sub(pos, s - 1)
    if mod == "-" then
      return (data:gsub("%s+$", ""))
    elseif not is_var and mod ~= "+" then
      local l = lc(s)
      local ls = starts[l]
      if ls >= pos and src:sub(ls, s - 1):match("^[ \t]*$") then
        return src:sub(pos, ls - 1)
      end
    end
    return data
  end

  local function read_string(p)
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
            fail(j, "invalid \\%s escape in string", e)
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
    fail(p, "unexpected end of string")
  end

  ---Lex expression tokens until the closing delimiter. Returns position after it and
  ---the end modifier ("-", "+" or nil).
  local function lex_expr(p, kind)
    local close = kind == "%" and "%}" or "}}"
    local depth = 0
    while true do
      p = src:match("^%s*()", p)
      if p > #src then
        fail(p - 1, "unexpected end of template, expected '%s'.", kind == "%" and "end of statement block" or "end of print statement")
      end
      if depth == 0 then
        if src:sub(p, p + 1) == close then
          return p + 2, nil
        elseif src:sub(p + 1, p + 2) == close and (src:sub(p, p) == "-" or (kind == "%" and src:sub(p, p) == "+")) then
          return p + 3, src:sub(p, p)
        end
      end
      local c = src:sub(p, p)
      local name = src:match("^[%a_][%w_]*", p)
      if name then
        push("name", name, p)
        p = p + #name
      elseif c:match("%d") then
        local num = src:match("^%d[%d_]*%.%d[%d_]*[eE][-+]?%d+", p)
          or src:match("^%d[%d_]*%.%d[%d_]*", p)
          or src:match("^%d[%d_]*[eE][-+]?%d+", p)
        if num then
          push("float", tonumber((num:gsub("_", ""))), p)
        else
          num = src:match("^%d[%d_]*", p)
          push("int", tonumber((num:gsub("_", ""))), p)
        end
        p = p + #num
      elseif c == "'" or c == '"' then
        local s, after = read_string(p)
        push("string", s, p)
        p = after
      else
        local two = src:sub(p, p + 1)
        local op = OPS2[two] and two or (OPS1[c] and c)
        if not op then
          fail(p, "unexpected char '%s'", c)
        end
        if OPEN[op] then
          depth = depth + 1
        elseif CLOSE[op] then
          depth = depth - 1
          if depth < 0 then
            fail(p, "unexpected '%s'", op)
          end
        end
        push("op", op, p)
        p = p + #op
      end
    end
  end

  while true do
    local s = src:find("{[{%%#]", pos)
    if not s then
      push_data(src:sub(pos), pos)
      break
    end
    local kind = src:sub(s + 1, s + 1)
    local mod = src:sub(s + 2, s + 2)
    local inner = s + 2
    if mod == "-" or (mod == "+" and kind ~= "{") then
      inner = inner + 1
    else
      mod = nil
    end
    push_data(data_before(s, mod, kind == "{"), pos)

    if kind == "#" then
      local e = src:find("#}", inner, true)
      if not e then
        fail(s, "missing end of comment tag")
      end
      pos = e + 2
      if src:sub(e - 1, e - 1) == "-" then
        strip_next = true
      elseif src:sub(pos, pos) == "\n" then
        pos = pos + 1
      end
    elseif kind == "{" then
      push("var_begin", nil, s)
      local after, endmod = lex_expr(inner, "{")
      push("var_end", nil, after - 2)
      pos = after
      strip_next = endmod == "-"
    else
      local first = #toks + 1
      push("block_begin", nil, s)
      local after, endmod = lex_expr(inner, "%")
      push("block_end", nil, after - 2)
      pos = after
      local t = toks[first + 1]
      if #toks == first + 2 and t.t == "name" and t.v == "raw" then
        -- {% raw %}: everything up to {% endraw %} is literal data.
        for k = #toks, first, -1 do
          toks[k] = nil
        end
        local es, ee, m1, m2 = src:find("{%%([-+]?)%s*endraw%s*([-+]?)%%}", pos)
        if not es then
          fail(s, "missing {%% endraw %%}")
        end
        strip_next = endmod == "-"
        local content = src:sub(pos, es - 1)
        if m1 == "-" then
          content = content:gsub("%s+$", "")
        elseif m1 ~= "+" then
          local l = lc(es)
          local ls = starts[l]
          if ls >= pos and src:sub(ls, es - 1):match("^[ \t]*$") then
            content = src:sub(pos, ls - 1)
          end
        end
        push_data(content, pos)
        pos = ee + 1
        endmod = m2 ~= "" and m2 or nil
      end
      if endmod == "-" then
        strip_next = true
      elseif endmod == nil and src:sub(pos, pos) == "\n" then
        pos = pos + 1 -- trim_blocks
      end
    end
  end
  local l, c = lc(#src + 1)
  toks[#toks + 1] = { t = "eof", line = l, col = c }
  return toks
end

return M
