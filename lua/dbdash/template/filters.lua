-- Built-in filters, tests and globals (design §6.3), with Jinja/Python semantics.
-- SQL filters are registered separately (dbdash.template.sql).
local map = require("dbdash.util.map")
local R = require("dbdash.template.runtime")
local errors = require("dbdash.template.errors")

local M = {}

local raise = errors.raise
local NONE = R.NONE

local bind = require("dbdash.template.bind")

local function length(v)
  if type(v) == "string" then
    return #R.chars(v)
  elseif R.is_safe(v) then
    return #R.chars(v.s)
  elseif map.is_map(v) then
    return #map.keys(v)
  elseif R.is_list(v) then
    return #v
  end
  raise("type", "object of type '%s' has no len()", R.typename(v))
end

local function seq_of(v)
  if type(v) == "string" then
    return R.chars(v)
  end
  return R.iter(v)
end

---Python int() of a string, or nil when invalid.
local function parse_int(s, base)
  s = vim.trim(s):gsub("_", "")
  if base == 16 then
    s = s:gsub("^([-+]?)0[xX]", "%1")
  elseif base == 8 then
    s = s:gsub("^([-+]?)0[oO]", "%1")
  elseif base == 2 then
    s = s:gsub("^([-+]?)0[bB]", "%1")
  end
  local sign, digits = s:match("^([-+]?)(%w+)$")
  if not digits then
    return nil
  end
  local n = tonumber(digits, base)
  if not n then
    return nil
  end
  return sign == "-" and -n or n
end

---Python float() of a string, or nil when invalid.
local function parse_float(s)
  s = vim.trim(s):gsub("_", "")
  local l = s:lower():gsub("^[-+]", "")
  if l == "inf" or l == "infinity" then
    return s:sub(1, 1) == "-" and -math.huge or math.huge
  elseif l == "nan" then
    return 0 / 0
  end
  if not s:match("^[-+]?%d*%.?%d*[eE]?[-+]?%d*$") then
    return nil
  end
  return tonumber(s)
end

local function trunc(x)
  return x >= 0 and math.floor(x) or math.ceil(x)
end

---The number of `v` and whether it is a float.
local function as_number(v, fname)
  local n, isf = R.num(v)
  if n then
    return n, isf
  end
  raise("type", "%s: expected a number, got '%s'", fname, R.typename(v))
end

-- Python's round(): round half to even.
local function round_half_even(x, ndigits)
  local m = 10 ^ ndigits
  local y = x * m
  local f = math.floor(y)
  local diff = y - f
  local r
  if diff > 0.5 then
    r = f + 1
  elseif diff < 0.5 then
    r = f
  else
    r = (f % 2 == 0) and f or f + 1
  end
  return r / m
end

-- JSON as produced by Jinja's tojson: sorted keys, ", " / ": " separators, ASCII-only,
-- and <, >, &, ' escaped for HTML safety.
local JSON_ESC = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["<"] = "\\u003c",
  [">"] = "\\u003e",
  ["&"] = "\\u0026",
  ["'"] = "\\u0027",
}

local function json_string(s)
  local out = {}
  for ch in s:gmatch("[%z\1-\127\192-\247][\128-\191]*") do
    local b = ch:byte()
    if JSON_ESC[ch] then
      out[#out + 1] = JSON_ESC[ch]
    elseif #ch == 1 and b < 0x20 then
      out[#out + 1] = ("\\u%04x"):format(b)
    elseif #ch == 1 then
      out[#out + 1] = ch
    else
      local cp = vim.fn.char2nr(ch)
      if cp >= 0x10000 then
        cp = cp - 0x10000
        out[#out + 1] = ("\\u%04x\\u%04x"):format(
          0xD800 + math.floor(cp / 0x400),
          0xDC00 + cp % 0x400
        )
      else
        out[#out + 1] = ("\\u%04x"):format(cp)
      end
    end
  end
  return '"' .. table.concat(out) .. '"'
end

---JSON text of a value; with `indent` (a number of spaces or a string) pretty printed
---like Python's json.dumps(indent=...).
local function to_json(v, indent, level)
  R.check(v)
  level = level or 0
  local nl, pad, pad_end, sep = "", "", "", ", "
  if indent then
    nl = "\n"
    pad = indent:rep(level + 1)
    pad_end = indent:rep(level)
    sep = ","
  end
  local t = type(v)
  if v == NONE or v == nil then
    return "null"
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "number" or R.is_float_box(v) then
    local n = R.num(v)
    if n ~= n then
      return "NaN"
    elseif n == math.huge then
      return "Infinity"
    elseif n == -math.huge then
      return "-Infinity"
    end
    return R.numstr(v)
  elseif t == "string" then
    return json_string(v)
  elseif R.is_safe(v) then
    return json_string(v.s)
  elseif map.is_map(v) then
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = { s = type(k) == "string" and k or R.str(k), k = k }
    end
    table.sort(keys, function(a, b)
      return a.s < b.s
    end)
    local parts = {}
    for i, k in ipairs(keys) do
      parts[i] = pad .. json_string(k.s) .. ": " .. to_json(v[k.k], indent, level + 1)
    end
    if #parts == 0 then
      return "{}"
    end
    return "{" .. nl .. table.concat(parts, sep .. nl) .. nl .. pad_end .. "}"
  elseif R.is_list(v) then
    local parts = {}
    for i = 1, #v do
      parts[i] = pad .. to_json(v[i], indent, level + 1)
    end
    if #parts == 0 then
      return "[]"
    end
    return "[" .. nl .. table.concat(parts, sep .. nl) .. nl .. pad_end .. "]"
  end
  raise("type", "Object of type %s is not JSON serializable", R.typename(v))
end
M.to_json = to_json

local F = {}

F.default = function(_, v, args, kw)
  local dflt, boolean = bind("default", args, kw, { { "default_value", "" }, { "boolean", false } })
  if R.is_undef(v) or (boolean and not R.truthy(v)) then
    return dflt
  end
  return v
end
F.d = F.default

F.length = function(_, v, args, kw)
  bind("length", args, kw, {})
  return length(v)
end
F.count = F.length

F.upper = function(_, v, args, kw)
  bind("upper", args, kw, {})
  return R.upper(R.str(v))
end

F.lower = function(_, v, args, kw)
  bind("lower", args, kw, {})
  return vim.fn.tolower(R.str(v))
end

F.trim = function(_, v, args, kw)
  local chars = bind("trim", args, kw, { { "chars", NONE } })
  return R.strip_chars(R.str(v), chars ~= NONE and R.str(chars) or nil, true, true)
end

F.replace = function(_, v, args, kw)
  local old, new, count = bind("replace", args, kw, { { "old" }, { "new" }, { "count", NONE } })
  local s = R.str(v)
  old, new = R.str(old), R.str(new)
  local limit = count ~= NONE and as_number(count, "replace") or math.huge
  local out, pos, n = {}, 1, 0
  if old == "" then
    -- Python inserts `new` between every character (and at both ends).
    local cs = R.chars(s)
    for i = 0, #cs do
      if n < limit then
        out[#out + 1] = new
        n = n + 1
      end
      out[#out + 1] = cs[i + 1]
    end
    return table.concat(out)
  end
  while n < limit do
    local a, b = s:find(old, pos, true)
    if not a then
      break
    end
    out[#out + 1] = s:sub(pos, a - 1) .. new
    pos = b + 1
    n = n + 1
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

F.join = function(_, v, args, kw)
  local sep, attribute = bind("join", args, kw, { { "d", "" }, { "attribute", NONE } })
  local parts = {}
  for i, item in ipairs(seq_of(v)) do
    if attribute ~= NONE then
      item = R.check(R.getitem(item, attribute))
    end
    parts[i] = R.str(item)
  end
  return table.concat(parts, R.str(sep))
end

F.first = function(_, v, args, kw)
  bind("first", args, kw, {})
  local seq = seq_of(v)
  if #seq == 0 then
    return R.undef("No first item, sequence was empty.")
  end
  return seq[1]
end

F.last = function(_, v, args, kw)
  bind("last", args, kw, {})
  local seq = seq_of(v)
  if #seq == 0 then
    return R.undef("No last item, sequence was empty.")
  end
  return seq[#seq]
end

F.int = function(_, v, args, kw)
  local dflt, base = bind("int", args, kw, { { "default", 0 }, { "base", 10 } })
  if type(v) == "string" or R.is_safe(v) then
    local s = R.str(v)
    local n = parse_int(s, base)
    if n then
      return n
    end
    local f = parse_float(s)
    if f and f == f and f ~= math.huge and f ~= -math.huge then
      return trunc(f)
    end
    return dflt
  elseif R.num(v) then
    local n = R.num(v)
    if n ~= n or n == math.huge or n == -math.huge then
      return dflt
    end
    return trunc(n)
  end
  return dflt
end

F.float = function(_, v, args, kw)
  local dflt = bind("float", args, kw, { { "default", R.float(0) } })
  if R.num(v) then
    return R.float((R.num(v)))
  elseif type(v) == "string" or R.is_safe(v) then
    local f = parse_float(R.str(v))
    if f then
      return R.float(f)
    end
  end
  return dflt
end

F.string = function(_, v, args, kw)
  bind("string", args, kw, {})
  return R.str(v)
end

F.abs = function(_, v, args, kw)
  bind("abs", args, kw, {})
  local n, isf = as_number(v, "abs")
  return R.mknum(math.abs(n), isf)
end

F.round = function(_, v, args, kw)
  local precision, method = bind("round", args, kw, { { "precision", 0 }, { "method", "common" } })
  local x, isf = as_number(v, "round")
  if method == "common" then
    -- Python's round(): an int stays an int, a float gives a float.
    return R.mknum(round_half_even(x, precision), isf)
  elseif method == "ceil" or method == "floor" then
    local m = 10 ^ precision
    return R.float(math[method](x * m) / m)
  end
  raise("value", "method must be 'common', 'ceil' or 'floor'")
end

F.tojson = function(_, v, args, kw)
  local indent = bind("tojson", args, kw, { { "indent", NONE } })
  if indent == NONE then
    return R.safe(to_json(v))
  end
  local ind = (type(indent) == "string" or R.is_safe(indent)) and R.str(indent)
    or (" "):rep((R.num(indent)) or 0)
  return R.safe(to_json(v, ind))
end

F.safe = function(_, v, args, kw)
  bind("safe", args, kw, {})
  if R.is_safe(v) then
    return v
  end
  return R.safe(R.str(v))
end

local T = {}

T.defined = function(_, v)
  return not R.is_undef(v)
end
T.undefined = function(_, v)
  return R.is_undef(v)
end
T.none = function(_, v)
  return R.check(v) == NONE
end
T.number = function(_, v)
  local t = type(R.check(v))
  return t == "number" or t == "boolean" or R.is_float_box(v)
end
T.string = function(_, v)
  return type(R.check(v)) == "string" or R.is_safe(v)
end
T.mapping = function(_, v)
  return map.is_map(R.check(v))
end
T.sequence = function(_, v)
  R.check(v)
  return type(v) == "string" or R.is_safe(v) or map.is_map(v) or R.is_list(v)
end
T["true"] = function(_, v)
  return R.check(v) == true
end
T["false"] = function(_, v)
  return R.check(v) == false
end
T.boolean = function(_, v)
  return type(R.check(v)) == "boolean"
end
T.integer = function(_, v)
  return type(R.check(v)) == "number" and not R.is_float(v)
end
T.float = function(_, v)
  return R.is_float(R.check(v))
end
local function int_mod(v, n)
  local x = R.num(R.check(v))
  if not x then
    raise("type", "unsupported operand type(s) for %%: '%s' and 'int'", R.typename(v))
  end
  return R.num(R.mod(v, n))
end
T.odd = function(_, v)
  return int_mod(v, 2) == 1
end
T.even = function(_, v)
  return int_mod(v, 2) == 0
end
T.divisibleby = function(_, v, args)
  return R.num(R.mod(R.check(v), R.check(args[1]))) == 0
end
T.lower = function(_, v)
  local _, out = require("dbdash.template.methods").call(R.str(v), "islower", {}, {})
  return out
end
T.upper = function(_, v)
  local _, out = require("dbdash.template.methods").call(R.str(v), "isupper", {}, {})
  return out
end
T.iterable = function(_, v)
  R.check(v)
  return type(v) == "string" or R.is_safe(v) or map.is_map(v) or R.is_list(v)
end
T.callable = function(_, v)
  R.check(v)
  if type(v) == "function" or R.is_macro(v) then
    return true
  end
  local mt = getmetatable(v)
  return mt ~= nil and mt.__call ~= nil and (R.callable_types[mt] or R.typename(v) == "LoopContext")
    or false
end
T.sameas = function(_, v, args)
  local o = R.check(args[1])
  R.check(v)
  if R.num(v) and R.num(o) and type(v) ~= "boolean" and type(o) ~= "boolean" then
    return R.num(v) == R.num(o) and R.is_float(v) == R.is_float(o)
  end
  return rawequal(v, o)
end
T.escaped = function(_, v)
  return R.is_safe(R.check(v))
end
T["in"] = function(_, v, args)
  return R.contains(args[1], v)
end
T.filter = function(_, v)
  return R.filters[R.str(v)] ~= nil
end
T.test = function(_, v)
  return R.tests[R.str(v)] ~= nil
end
for names, op in pairs({
  ["eq ==  equalto"] = "==",
  ["ne !="] = "!=",
  ["gt > greaterthan"] = ">",
  ["ge >="] = ">=",
  ["lt < lessthan"] = "<",
  ["le <="] = "<=",
}) do
  for name in names:gmatch("%S+") do
    T[name] = function(_, v, args)
      return R.cmp(op, v, args[1])
    end
  end
end

local G = {}

G.range = function(args, kwargs)
  if next(kwargs) then
    raise("type", "range() takes no keyword arguments")
  end
  local start, stop, step
  if #args == 1 then
    start, stop, step = 0, args[1], 1
  elseif #args == 2 or #args == 3 then
    start, stop, step = args[1], args[2], args[3] or 1
  else
    raise("type", "range expected 1 to 3 arguments, got %d", #args)
  end
  for _, x in ipairs({ start, stop, step }) do
    R.check(x)
    if type(x) ~= "number" or R.is_float(x) then
      raise("type", "'%s' object cannot be interpreted as an integer", R.typename(x))
    end
  end
  if step == 0 then
    raise("value", "range() arg 3 must not be zero")
  end
  local out = {}
  if (stop - start) / step > 100000 then
    raise("value", "range() is limited to 100000 items")
  end
  for i = start, stop - (step > 0 and 1 or -1), step do
    out[#out + 1] = i
  end
  return out
end

---Register everything into the runtime.
function M.install()
  require("dbdash.template.filters_seq").install()
  require("dbdash.template.filters_text").install()
  for k, v in pairs(F) do
    R.filters[k] = v
  end
  for k, v in pairs(T) do
    R.tests[k] = v
  end
  for k, v in pairs(G) do
    R.globals[k] = v
  end
end

return M
