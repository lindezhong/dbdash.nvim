-- Methods of template values, as in Python: str, dict, list and tuple methods
-- ('a,b'.split(','), d.items(), l.append(x) ...). Methods that change a value refuse the
-- read-only `args` and `meta` (and the values in them).
local R = require("dbdash.template.runtime")
local map = require("dbdash.util.map")
local errors = require("dbdash.template.errors")

local M = {}

local raise = errors.raise
local NONE = R.NONE
local check = R.check

---Bind arguments to parameters { name, default } (nil default: required).
local function bind(name, args, kwargs, params)
  return require("dbdash.template.filters").bind(name, args, kwargs, params)
end

local function str_arg(v, what)
  v = check(v)
  if R.is_safe(v) then
    return v.s
  elseif type(v) ~= "string" then
    raise("type", "%s must be str, not %s", what, R.typename(v))
  end
  return v
end

local function int_arg(v, what)
  local n, isf = R.num(check(v))
  if not n or isf then
    raise("type", "%s: an integer is required, not '%s'", what, R.typename(v))
  end
  return n
end

local chars = R.chars

---Code point index (0-based) of byte position `pos` in `s`.
local function cp_index(s, pos)
  return #chars(s:sub(1, pos - 1))
end

---Python slice bounds (start, end) of a str of `n` code points, as 1-based char indexes.
local function bounds(n, start, stop)
  local a = (start == nil or start == NONE) and 0 or int_arg(start, "slice index")
  local b = (stop == nil or stop == NONE) and n or int_arg(stop, "slice index")
  if a < 0 then
    a = math.max(0, n + a)
  end
  if b < 0 then
    b = math.max(0, n + b)
  end
  return math.min(a, n), math.min(b, n)
end

---The part of `s` between start and end (code points), and the code point offset.
local function window(s, start, stop)
  local cs = chars(s)
  local a, b = bounds(#cs, start, stop)
  if b < a then
    return "", a
  end
  return table.concat(cs, "", a + 1, b), a
end

local function find(s, sub, start, stop, last)
  local w, off = window(s, start, stop)
  if last then
    local best
    local pos = 1
    while true do
      local i = w:find(sub, pos, true)
      if not i then
        break
      end
      best = i
      pos = i + 1
      if sub == "" and pos > #w + 1 then
        break
      end
    end
    if sub == "" then
      return off + #chars(w)
    end
    return best and off + cp_index(w, best) or -1
  end
  local i = w:find(sub, 1, true)
  return i and off + cp_index(w, i) or -1
end

local WS = "[ \t\n\r\f\v]"

---str.split / rsplit.
local function split(s, sep, maxsplit, from_right)
  local out = {}
  maxsplit = maxsplit or -1
  if sep == nil then
    -- Runs of whitespace, ignoring leading and trailing whitespace.
    local words = {}
    for w in s:gmatch("[^ \t\n\r\f\v]+") do
      words[#words + 1] = w
    end
    if maxsplit < 0 or maxsplit >= #words - 1 then
      return words
    end
    if from_right then
      local keep = #words - maxsplit
      local cut = s:gsub(WS .. "+$", "")
      -- The first `keep` words stay joined as in the original text.
      local pos = #cut + 1
      for _ = 1, maxsplit do
        local i = cut:sub(1, pos - 1):match(".*()" .. WS)
        pos = i
      end
      local head = cut:sub(1, pos - 1):gsub(WS .. "+$", "")
      out[1] = head
      for i = keep + 1, #words do
        out[#out + 1] = words[i]
      end
      return out
    end
    local rest = s:gsub("^" .. WS .. "+", "")
    for _ = 1, maxsplit do
      local w, after = rest:match("^([^ \t\n\r\f\v]+)" .. WS .. "+()")
      out[#out + 1] = w
      rest = rest:sub(after)
    end
    out[#out + 1] = rest
    return out
  end
  if sep == "" then
    raise("value", "empty separator")
  end
  local parts, pos = {}, 1
  while true do
    local i, j = s:find(sep, pos, true)
    if not i then
      break
    end
    parts[#parts + 1] = s:sub(pos, i - 1)
    pos = j + 1
  end
  parts[#parts + 1] = s:sub(pos)
  if maxsplit < 0 or maxsplit >= #parts - 1 then
    return parts
  end
  if from_right then
    local keep = #parts - maxsplit
    out[1] = table.concat(parts, sep, 1, keep)
    for i = keep + 1, #parts do
      out[#out + 1] = parts[i]
    end
  else
    for i = 1, maxsplit do
      out[i] = parts[i]
    end
    out[#out + 1] = table.concat(parts, sep, maxsplit + 1)
  end
  return out
end

local function is_upper(c)
  return c ~= vim.fn.tolower(c)
end
local function is_lower(c)
  return c ~= R.upper(c)
end
local function is_cased(c)
  return is_upper(c) or is_lower(c)
end
local function is_alpha(c)
  return c:match("^%a$") ~= nil or (#c > 1 and is_cased(c))
end

local function all_chars(s, pred)
  local cs = chars(s)
  if #cs == 0 then
    return false
  end
  for _, c in ipairs(cs) do
    if not pred(c) then
      return false
    end
  end
  return true
end

local function title(s)
  local out, prev_cased = {}, false
  for _, c in ipairs(chars(s)) do
    if is_cased(c) then
      out[#out + 1] = prev_cased and vim.fn.tolower(c) or R.upper(c)
      prev_cased = true
    else
      out[#out + 1] = c
      prev_cased = false
    end
  end
  return table.concat(out)
end

local function justify(s, width, fill, how)
  local n = #chars(s)
  if width <= n then
    return s
  end
  local total = width - n
  if how == "l" then
    return s .. fill:rep(total)
  elseif how == "r" then
    return fill:rep(total) .. s
  end
  -- str.center: the extra fill goes left when the width is odd and the margin is odd.
  local left = math.floor(total / 2) + ((total % 2 == 1 and width % 2 == 1) and 1 or 0)
  return fill:rep(left) .. s .. fill:rep(total - left)
end

local function fill_arg(v)
  local f = str_arg(v, "fill character")
  if #chars(f) ~= 1 then
    raise("type", "The fill character must be exactly one character long")
  end
  return f
end

local function prefix_test(s, arg, start, stop, at_end)
  local w = window(s, start, stop)
  local list = R.is_tuple(check(arg)) and arg or { arg }
  if not R.is_tuple(arg) and type(arg) ~= "string" and not R.is_safe(arg) then
    raise("type", "%s arg must be str or a tuple of str, not %s", at_end and "endswith" or "startswith", R.typename(arg))
  end
  for _, p in ipairs(list) do
    p = str_arg(p, "prefix")
    if at_end then
      if p == "" or w:sub(-#p) == p then
        return true
      end
    elseif w:sub(1, #p) == p then
      return true
    end
  end
  return false
end

local STR = {}

STR.capitalize = function(s)
  local cs = chars(s)
  if #cs == 0 then
    return ""
  end
  return R.upper(cs[1]) .. vim.fn.tolower(table.concat(cs, "", 2))
end
STR.casefold = function(s)
  return (vim.fn.tolower(s):gsub("ß", "ss"))
end
STR.lower = function(s)
  return vim.fn.tolower(s)
end
STR.upper = function(s)
  return R.upper(s)
end
STR.swapcase = function(s)
  local out = {}
  for i, c in ipairs(chars(s)) do
    out[i] = is_upper(c) and vim.fn.tolower(c) or R.upper(c)
  end
  return table.concat(out)
end
STR.title = title
STR.center = function(s, args, kw)
  local width, fill = bind("center", args, kw, { { "width" }, { "fillchar", " " } })
  return justify(s, int_arg(width, "center"), fill_arg(fill), "c")
end
STR.ljust = function(s, args, kw)
  local width, fill = bind("ljust", args, kw, { { "width" }, { "fillchar", " " } })
  return justify(s, int_arg(width, "ljust"), fill_arg(fill), "l")
end
STR.rjust = function(s, args, kw)
  local width, fill = bind("rjust", args, kw, { { "width" }, { "fillchar", " " } })
  return justify(s, int_arg(width, "rjust"), fill_arg(fill), "r")
end
STR.zfill = function(s, args, kw)
  local width = int_arg(bind("zfill", args, kw, { { "width" } }), "zfill")
  local sign, rest = s:match("^([-+]?)(.*)$")
  local n = #chars(s)
  if width <= n then
    return s
  end
  return sign .. ("0"):rep(width - n) .. rest
end
STR.count = function(s, args, kw)
  local sub, start, stop = bind("count", args, kw, { { "sub" }, { "start", NONE }, { "end", NONE } })
  sub = str_arg(sub, "count() argument")
  local w = window(s, start, stop)
  if sub == "" then
    return #chars(w) + 1
  end
  local n, pos = 0, 1
  while true do
    local i, j = w:find(sub, pos, true)
    if not i then
      return n
    end
    n, pos = n + 1, j + 1
  end
end
for name, last in pairs({ find = false, rfind = true, index = false, rindex = true }) do
  STR[name] = function(s, args, kw)
    local sub, start, stop = bind(name, args, kw, { { "sub" }, { "start", NONE }, { "end", NONE } })
    local i = find(s, str_arg(sub, name .. "() argument"), start, stop, last)
    if i < 0 and (name == "index" or name == "rindex") then
      raise("value", "substring not found")
    end
    return i
  end
end
STR.startswith = function(s, args, kw)
  local p, start, stop = bind("startswith", args, kw, { { "prefix" }, { "start", NONE }, { "end", NONE } })
  return prefix_test(s, p, start, stop, false)
end
STR.endswith = function(s, args, kw)
  local p, start, stop = bind("endswith", args, kw, { { "suffix" }, { "start", NONE }, { "end", NONE } })
  return prefix_test(s, p, start, stop, true)
end
STR.expandtabs = function(s, args, kw)
  local size = int_arg(bind("expandtabs", args, kw, { { "tabsize", 8 } }), "expandtabs")
  local out, col = {}, 0
  for _, c in ipairs(chars(s)) do
    if c == "\t" then
      local n = size > 0 and size - col % size or 0
      out[#out + 1] = (" "):rep(n)
      col = col + n
    else
      out[#out + 1] = c
      col = (c == "\n" or c == "\r") and 0 or col + 1
    end
  end
  return table.concat(out)
end
STR.format = function(s, args, kw)
  for _, v in pairs(kw) do
    check(v)
  end
  return require("dbdash.template.pyformat").format(s, args, kw)
end
STR.format_map = function(s, args, kw)
  local m = bind("format_map", args, kw, { { "mapping" } })
  if not map.is_map(m) then
    raise("type", "format_map() argument must be a mapping, not %s", R.typename(m))
  end
  return require("dbdash.template.pyformat").format(s, {}, m)
end
STR.isalnum = function(s)
  return all_chars(s, function(c)
    return is_alpha(c) or c:match("^%d$") ~= nil
  end)
end
STR.isalpha = function(s)
  return all_chars(s, is_alpha)
end
STR.isascii = function(s)
  return not s:find("[\128-\255]")
end
local function digits(s)
  return all_chars(s, function(c)
    return c:match("^%d$") ~= nil
  end)
end
STR.isdecimal, STR.isdigit, STR.isnumeric = digits, digits, digits
STR.isidentifier = function(s)
  return s:match("^[%a_][%w_]*$") ~= nil
end
STR.isspace = function(s)
  return s ~= "" and s:match("^" .. WS .. "+$") ~= nil
end
STR.islower = function(s)
  local any = false
  for _, c in ipairs(chars(s)) do
    if is_upper(c) then
      return false
    end
    any = any or is_lower(c)
  end
  return any
end
STR.isupper = function(s)
  local any = false
  for _, c in ipairs(chars(s)) do
    if is_lower(c) then
      return false
    end
    any = any or is_upper(c)
  end
  return any
end
STR.istitle = function(s)
  return s ~= "" and title(s) == s and STR.islower(s) == false and s:find("%a") ~= nil
end
STR.join = function(s, args, kw)
  local it = bind("join", args, kw, { { "iterable" } })
  local parts = {}
  for i, x in ipairs(R.iter(it)) do
    if type(check(x)) ~= "string" and not R.is_safe(x) then
      raise("type", "sequence item %d: expected str instance, %s found", i - 1, R.typename(x))
    end
    parts[i] = R.str(x)
  end
  return table.concat(parts, s)
end
for name, side in pairs({ strip = "lr", lstrip = "l", rstrip = "r" }) do
  STR[name] = function(s, args, kw)
    local cs = bind(name, args, kw, { { "chars", NONE } })
    return R.strip_chars(s, cs ~= NONE and str_arg(cs, name .. " arg") or nil, side:find("l") ~= nil, side:find("r") ~= nil)
  end
end
STR.partition = function(s, args, kw)
  local sep = str_arg(bind("partition", args, kw, { { "sep" } }), "partition() argument")
  local i, j = s:find(sep, 1, true)
  if not i then
    return R.tuple({ s, "", "" })
  end
  return R.tuple({ s:sub(1, i - 1), sep, s:sub(j + 1) })
end
STR.rpartition = function(s, args, kw)
  local sep = str_arg(bind("rpartition", args, kw, { { "sep" } }), "rpartition() argument")
  local last
  local pos = 1
  while true do
    local i = s:find(sep, pos, true)
    if not i then
      break
    end
    last, pos = i, i + 1
  end
  if not last then
    return R.tuple({ "", "", s })
  end
  return R.tuple({ s:sub(1, last - 1), sep, s:sub(last + #sep) })
end
STR.removeprefix = function(s, args, kw)
  local p = str_arg(bind("removeprefix", args, kw, { { "prefix" } }), "removeprefix() argument")
  return s:sub(1, #p) == p and s:sub(#p + 1) or s
end
STR.removesuffix = function(s, args, kw)
  local p = str_arg(bind("removesuffix", args, kw, { { "suffix" } }), "removesuffix() argument")
  return (p ~= "" and s:sub(-#p) == p) and s:sub(1, #s - #p) or s
end
STR.replace = function(s, args, kw)
  local old, new, count = bind("replace", args, kw, { { "old" }, { "new" }, { "count", -1 } })
  local n = int_arg(count, "replace")
  return R.filters.replace({}, s, { str_arg(old, "replace() argument 1"), str_arg(new, "replace() argument 2"), n >= 0 and n or NONE }, {})
end
for name, right in pairs({ split = false, rsplit = true }) do
  STR[name] = function(s, args, kw)
    local sep, maxsplit = bind(name, args, kw, { { "sep", NONE }, { "maxsplit", -1 } })
    return split(s, sep ~= NONE and str_arg(sep, "separator") or nil, int_arg(maxsplit, name), right)
  end
end
STR.splitlines = function(s, args, kw)
  local keep = R.truthy(bind("splitlines", args, kw, { { "keepends", false } }))
  local out, pos = {}, 1
  while pos <= #s do
    local i, j = s:find("\r\n", pos, true)
    local k = s:find("[\n\r\v\f]", pos)
    if k and (not i or k < i) then
      i, j = k, k
    end
    if not i then
      out[#out + 1] = s:sub(pos)
      break
    end
    out[#out + 1] = s:sub(pos, keep and j or i - 1)
    pos = j + 1
  end
  return out
end

-- Mappings ---------------------------------------------------------------------------------

local function writable(v)
  local name = R.frozen[v]
  if name then
    raise("value", "'%s' is read-only (dashboard %s)", name, name == "args" and "arguments; use {% set args.x = ... %}" or "metadata")
  end
end

local DICT = {}

DICT.items = function(d)
  local out = {}
  for k, v in map.pairs(d) do
    out[#out + 1] = R.tuple({ k, v })
  end
  return R.view(out, "dict_items")
end
DICT.keys = function(d)
  return R.view(map.keys(d), "dict_keys")
end
DICT.values = function(d)
  local out = {}
  for _, v in map.pairs(d) do
    out[#out + 1] = v
  end
  return R.view(out, "dict_values")
end
DICT.get = function(d, args, kw)
  local k, dflt = bind("get", args, kw, { { "key" }, { "default", NONE } })
  local v = d[R.key_of(k)]
  if v == nil then
    return dflt
  end
  return v
end
DICT.copy = function(d)
  local out = map.new()
  for k, v in map.pairs(d) do
    map.set(out, k, v)
  end
  return out
end
DICT.update = function(d, args, kw)
  writable(d)
  if #args > 1 then
    raise("type", "update expected at most 1 argument, got %d", #args)
  end
  local other = args[1] and check(args[1])
  if map.is_map(other) then
    for k, v in map.pairs(other) do
      map.set(d, k, v)
    end
  elseif other ~= nil then
    for _, kv in ipairs(R.iter(other)) do
      local k, v = R.unpack(kv, 2)
      map.set(d, R.key_of(k), v)
    end
  end
  for k, v in pairs(kw) do
    map.set(d, k, v)
  end
  return NONE
end
DICT.pop = function(d, args, kw)
  writable(d)
  local k, dflt = bind("pop", args, kw, { { "key" }, { "default", R.MISSING } })
  k = R.key_of(k)
  local v = d[k]
  if v == nil then
    if dflt == R.MISSING then
      raise("value", "KeyError: %s", R.repr(k))
    end
    return dflt
  end
  map.delete(d, k)
  return v
end
DICT.popitem = function(d)
  writable(d)
  local keys = map.keys(d)
  local k = keys[#keys]
  if k == nil then
    raise("value", "KeyError: 'popitem(): dictionary is empty'")
  end
  local v = d[k]
  map.delete(d, k)
  return R.tuple({ k, v })
end
DICT.setdefault = function(d, args, kw)
  local k, dflt = bind("setdefault", args, kw, { { "key" }, { "default", NONE } })
  k = R.key_of(k)
  if d[k] == nil then
    writable(d)
    map.set(d, k, dflt)
  end
  return d[k]
end
DICT.clear = function(d)
  writable(d)
  for _, k in ipairs(map.keys(d)) do
    map.delete(d, k)
  end
  return NONE
end

-- Lists and tuples ------------------------------------------------------------------------

local SEQ = {}

SEQ.index = function(l, args, kw)
  local x = bind("index", args, kw, { { "value" } })
  for i, v in ipairs(l) do
    if R.eq(v, x) then
      return i - 1
    end
  end
  raise("value", "%s is not in list", R.repr(x))
end
SEQ.count = function(l, args, kw)
  local x = bind("count", args, kw, { { "value" } })
  local n = 0
  for _, v in ipairs(l) do
    if R.eq(v, x) then
      n = n + 1
    end
  end
  return n
end

local LIST = setmetatable({}, { __index = SEQ })

LIST.copy = function(l)
  return vim.list_extend({}, l)
end
LIST.append = function(l, args, kw)
  writable(l)
  l[#l + 1] = bind("append", args, kw, { { "object" } })
  return NONE
end
LIST.extend = function(l, args, kw)
  writable(l)
  for _, v in ipairs(R.iter(bind("extend", args, kw, { { "iterable" } }))) do
    l[#l + 1] = v
  end
  return NONE
end
LIST.insert = function(l, args, kw)
  writable(l)
  local i, x = bind("insert", args, kw, { { "index" }, { "object" } })
  i = int_arg(i, "insert")
  if i < 0 then
    i = math.max(0, #l + i)
  end
  table.insert(l, math.min(i, #l) + 1, x)
  return NONE
end
LIST.pop = function(l, args, kw)
  writable(l)
  local i = int_arg(bind("pop", args, kw, { { "index", -1 } }), "pop")
  if #l == 0 then
    raise("value", "pop from empty list")
  end
  if i < 0 then
    i = #l + i
  end
  if i < 0 or i >= #l then
    raise("value", "pop index out of range")
  end
  return table.remove(l, i + 1)
end
LIST.remove = function(l, args, kw)
  writable(l)
  local x = bind("remove", args, kw, { { "value" } })
  for i, v in ipairs(l) do
    if R.eq(v, x) then
      table.remove(l, i)
      return NONE
    end
  end
  raise("value", "list.remove(x): x not in list")
end
LIST.reverse = function(l)
  writable(l)
  local n = #l
  for i = 1, math.floor(n / 2) do
    l[i], l[n - i + 1] = l[n - i + 1], l[i]
  end
  return NONE
end
LIST.sort = function(l, args, kw)
  writable(l)
  local reverse = bind("sort", args, kw, { { "reverse", false } })
  local sorted = R.sorted(l, nil, R.truthy(reverse))
  for i, v in ipairs(sorted) do
    l[i] = v
  end
  return NONE
end
LIST.clear = function(l)
  writable(l)
  for i = #l, 1, -1 do
    l[i] = nil
  end
  return NONE
end

M.by_type = { str = STR, dict = DICT, list = LIST, tuple = SEQ }

---Call method `name` of `obj`; nil when it has no such method.
---@return boolean found, any result
function M.call(obj, name, args, kwargs)
  local tn = R.typename(obj)
  if tn == "Markup" then
    tn = "str"
  elseif tn:match("^dict_") then
    tn = "tuple" -- views: index/count like a tuple
  end
  local fns = M.by_type[tn]
  local fn = fns and fns[name]
  if not fn then
    return false
  end
  if tn == "str" then
    local out = fn(R.str(obj), args, kwargs)
    if R.is_safe(obj) and type(out) == "string" then
      out = R.safe(out) -- Markup methods return Markup
    end
    return true, out
  end
  return true, fn(obj, args, kwargs)
end

return M
