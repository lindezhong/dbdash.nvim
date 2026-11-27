-- Python string formatting for templates: printf-style ('%s-%d' % (a, b), the `format`
-- filter) and str.format() with the format specification mini-language.
local R = require("dbdash.template.runtime")
local map = require("dbdash.util.map")
local errors = require("dbdash.template.errors")

local M = {}

local raise = errors.raise

---Length in code points (Python's len of a str).
local function ulen(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

---Pad `s` to `width` code points: align "<", ">", "^" (centered, extra fill on the right)
---or "=" (after the sign `sign_len` bytes).
local function pad(s, width, align, fill, sign_len)
  local n = ulen(s)
  if not width or n >= width then
    return s
  end
  local total = width - n
  if align == "<" then
    return s .. fill:rep(total)
  elseif align == ">" then
    return fill:rep(total) .. s
  elseif align == "^" then
    local left = math.floor(total / 2)
    return fill:rep(left) .. s .. fill:rep(total - left)
  end
  -- "=": the padding goes between the sign (and prefix) and the digits.
  return s:sub(1, sign_len) .. fill:rep(total) .. s:sub(sign_len + 1)
end

---"1234567.5" -> "1,234,567.5" (the integer digits only).
local function group(digits, sep)
  local int, rest = digits:match("^(%d+)(.*)$")
  if not int then
    return digits
  end
  local out = int:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
  if out:sub(1, #sep) == sep then
    out = out:sub(#sep + 1)
  end
  return out .. rest
end

local function nonfinite(x, upper)
  local s = x ~= x and "nan" or "inf"
  return upper and s:upper() or s
end

---Digits of a number (without sign) for a presentation type. `x` is the absolute value.
---@return string digits, string prefix ("0x" ... for alternate forms)
local function digits_of(x, isf, typ, prec, alt)
  if typ == "d" or typ == "i" or typ == "u" or typ == "n" and not isf then
    return ("%.0f"):format(x), ""
  elseif typ == "x" or typ == "X" or typ == "o" or typ == "b" then
    local base = ({ x = 16, X = 16, o = 8, b = 2 })[typ]
    local n, out = math.floor(x), {}
    repeat
      local d = n % base
      out[#out + 1] = ("0123456789abcdef"):sub(d + 1, d + 1)
      n = math.floor(n / base)
    until n == 0
    local s = table.concat(out):reverse()
    local prefix = alt and ("0" .. typ:lower()) or ""
    if typ == "X" then
      s, prefix = s:upper(), prefix:upper()
    end
    return s, prefix
  end
  if x ~= x or x == math.huge then
    return nonfinite(x, typ == "E" or typ == "F" or typ == "G"), ""
  end
  if typ == "e" or typ == "E" or typ == "f" or typ == "F" then
    local s = ("%" .. (alt and "#" or "") .. "." .. (prec or 6) .. typ:lower()):format(x)
    return typ == "E" and s:upper() or s, ""
  elseif typ == "g" or typ == "G" or typ == "n" then
    local p = prec or 6
    local s = ("%" .. (alt and "#" or "") .. "." .. (p == 0 and 1 or p) .. "g"):format(x)
    return typ == "G" and s:upper() or s, ""
  elseif typ == "%" then
    return ("%" .. (alt and "#" or "") .. "." .. (prec or 6) .. "f"):format(x * 100) .. "%", ""
  elseif typ == "" then
    -- No type: ints as "d", floats as repr (with a precision: like "g", but fixed-point
    -- notation keeps a digit after the point).
    if not isf then
      return ("%.0f"):format(x), ""
    elseif not prec then
      return R.floatstr(x), ""
    end
    local s = ("%." .. (prec == 0 and 1 or prec) .. "g"):format(x)
    if not s:find("[.e]") then
      s = s .. ".0"
    end
    return s, ""
  end
end

---Format a number per a parsed spec { typ, prec, sign, alt, zero, width, align, fill, grouping }.
local function format_number(v, o)
  local x, isf = R.num(v)
  local typ = o.typ or ""
  if
    (typ == "d" or typ == "b" or typ == "o" or typ == "x" or typ == "X" or typ == "c")
    and isf
    and not o.percent
  then
    raise("value", "Unknown format code '%s' for object of type 'float'", typ)
  end
  if typ == "c" then
    return pad(
      require("dbdash.util.utf8").char(math.floor(x)),
      o.width,
      o.align or (o.percent and ">" or "<"),
      o.fill or " ",
      0
    )
  end
  if
    o.percent and (typ == "d" or typ == "i" or typ == "u" or typ == "x" or typ == "X" or typ == "o")
  then
    x = x >= 0 and math.floor(x) or math.ceil(x) -- '%d' % 3.7 -> 3
  end
  local neg = x < 0 or (x == 0 and 1 / x < 0 and isf)
  local digits, prefix = digits_of(math.abs(x), isf, typ, o.prec, o.alt)
  if o.grouping then
    digits = group(digits, o.grouping)
  end
  local sign = neg and "-" or (o.sign == "+" and "+" or o.sign == " " and " " or "")
  local s = sign .. prefix .. digits
  local align, fill = o.align, o.fill or " "
  if o.zero and not align then
    align, fill = "=", "0"
  end
  return pad(s, o.width, align or ">", fill, #sign + #prefix)
end

---Format any value per a spec (the format() mini-language).
local function format_value(v, o)
  R.check(v)
  if
    R.num(v) and type(v) ~= "boolean"
    or (type(v) == "boolean" and o.typ and o.typ ~= "" and o.typ ~= "s")
  then
    if o.typ == "s" then
      raise("value", "Unknown format code 's' for object of type '%s'", R.typename(v))
    end
    return format_number(v, o)
  end
  if o.typ and o.typ ~= "" and o.typ ~= "s" then
    raise("value", "Unknown format code '%s' for object of type '%s'", o.typ, R.typename(v))
  end
  local s = R.str(v)
  if o.prec then
    s = table.concat(R.chars(s), "", 1, math.min(o.prec, ulen(s)))
  end
  if o.align == "=" then
    raise("value", "'=' alignment not allowed in string format specifier")
  end
  return pad(s, o.width, o.align or "<", o.fill or " ", 0)
end

---Parse a format spec ("[[fill]align][sign][#][0][width][grouping][.precision][type]").
local function parse_spec(spec)
  local o = {}
  local cs = R.chars(spec)
  local i = 1
  if cs[2] and cs[2]:match("^[<>=^]$") then
    o.fill, o.align, i = cs[1], cs[2], 3
  elseif cs[1] and cs[1]:match("^[<>=^]$") then
    o.align, i = cs[1], 2
  end
  local rest = table.concat(cs, "", i)
  local sign, alt, zero, width, grouping, prec, typ =
    rest:match("^([-+ ]?)(#?)(0?)(%d*)([,_]?)(%.?%d*)([%a%%]?)$")
  if not sign or prec == "." then
    raise("value", "Invalid format specifier '%s'", spec)
  end
  o.sign = sign ~= "" and sign or nil
  o.alt = alt == "#"
  o.zero = zero == "0"
  o.width = tonumber(width)
  o.grouping = grouping ~= "" and grouping or nil
  o.prec = prec ~= "" and tonumber(prec:sub(2)) or nil
  o.typ = typ
  return o
end

---format(value, spec): Python's format().
function M.format_spec(v, spec)
  return format_value(v, parse_spec(spec))
end

-- str.format ------------------------------------------------------------------------------

---The value of a field name ("0", "name", "x.attr", "x[0]").
local function field_value(name, args, kwargs, auto)
  local first, rest = name:match("^([^.%[]*)(.*)$")
  local v
  if first == "" then
    if auto.manual then
      raise("value", "cannot switch from manual field specification to automatic field numbering")
    end
    auto.n = auto.n + 1
    auto.used = true
    v = args[auto.n]
    if v == nil then
      raise("value", "Replacement index %d out of range for positional args tuple", auto.n - 1)
    end
  elseif first:match("^%d+$") then
    if auto.used then
      raise("value", "cannot switch from automatic field numbering to manual field specification")
    end
    auto.manual = true
    v = args[tonumber(first) + 1]
    if v == nil then
      raise("value", "Replacement index %s out of range for positional args tuple", first)
    end
  else
    v = kwargs[first]
    if v == nil then
      raise("value", "KeyError: %s", R.repr(first))
    end
  end
  for kind, part in rest:gmatch("([.%[])([^.%[%]]*)%]?") do
    if kind == "." then
      -- Python attribute access: a dict's keys are not attributes here.
      if map.is_map(v) then
        raise("value", "'dict' object has no attribute '%s'", part)
      end
      v = R.check(R.getattr(v, part))
    else
      v = R.check(R.getitem(v, part:match("^%d+$") and tonumber(part) or part))
    end
  end
  return v
end

---str.format(*args, **kwargs).
---@param s string
---@param args any[]
---@param kwargs table<string, any>
function M.format(s, args, kwargs)
  local out, i, n = {}, 1, #s
  local auto = { n = 0 }
  while i <= n do
    local c = s:sub(i, i)
    if c == "{" and s:sub(i + 1, i + 1) == "{" then
      out[#out + 1] = "{"
      i = i + 2
    elseif c == "}" and s:sub(i + 1, i + 1) == "}" then
      out[#out + 1] = "}"
      i = i + 2
    elseif c == "}" then
      raise("value", "Single '}' encountered in format string")
    elseif c == "{" then
      -- The field, with one level of nested fields in its spec ("{:{width}}").
      local depth, j = 1, i + 1
      while j <= n and depth > 0 do
        local d = s:sub(j, j)
        if d == "{" then
          depth = depth + 1
        elseif d == "}" then
          depth = depth - 1
        end
        j = j + 1
      end
      if depth > 0 then
        raise("value", "expected '}' before end of string")
      end
      local field = s:sub(i + 1, j - 2)
      local name, conv, spec = field:match("^([^!:]*)!?([rsa]?):?(.*)$")
      if field:find("!") and conv == "" then
        raise("value", "Unknown conversion specifier")
      end
      local v = field_value(name, args, kwargs, auto)
      if conv == "r" or conv == "a" then
        v = R.repr(v)
      elseif conv == "s" then
        v = R.str(v)
      end
      if spec:find("{", 1, true) then
        spec = M.format(spec, args, kwargs)
      end
      out[#out + 1] = format_value(v, parse_spec(spec))
      i = j
    else
      local k = s:find("[{}]", i) or n + 1
      out[#out + 1] = s:sub(i, k - 1)
      i = k
    end
  end
  return table.concat(out)
end

-- printf-style ------------------------------------------------------------------------------

---s % values: values is a tuple (one per conversion), a mapping (with %(name)s), or a
---single value.
function M.percent(s, values)
  R.check(values)
  local list, mapping
  if R.is_tuple(values) then
    list = values
  elseif map.is_map(values) then
    mapping, list = values, { values }
  else
    list = { values }
  end
  local idx = 0
  local function next_arg()
    idx = idx + 1
    local v = list[idx]
    if v == nil then
      raise("type", "not enough arguments for format string")
    end
    return R.check(v)
  end
  local used_mapping = false
  local out, i, n = {}, 1, #s
  while i <= n do
    local k = s:find("%", i, true)
    if not k then
      out[#out + 1] = s:sub(i)
      break
    end
    out[#out + 1] = s:sub(i, k - 1)
    local j = k + 1
    local key
    if s:sub(j, j) == "(" then
      local close = s:find(")", j, true)
      if not close then
        raise("value", "incomplete format key")
      end
      key = s:sub(j + 1, close - 1)
      j = close + 1
    end
    local flags, width, prec, typ
    flags, j = s:match("^([-+ #0]*)()", j)
    width, j = s:match("^(%*?%d*)()", j)
    prec, j = s:match("^(%.?%*?%d*)()", j)
    typ = s:sub(j, j)
    if typ == "" or not typ:match("[diouxXeEfFgGcrsa%%]") then
      raise("value", "unsupported format character '%s'", typ)
    end
    i = j + 1
    out[#out + 1] = M.conversion(typ, key, flags, width, prec, mapping, next_arg, function()
      used_mapping = true
    end)
  end
  if not used_mapping and idx < #list then
    raise("type", "not all arguments converted during string formatting")
  end
  return table.concat(out)
end

---One printf-style conversion.
function M.conversion(typ, key, flags, width, prec, mapping, next_arg, on_mapping)
  if typ == "%" and not key and flags == "" and width == "" and prec == "" then
    return "%"
  end
  local v
  if key then
    if not mapping then
      raise("type", "format requires a mapping")
    end
    on_mapping()
    v = mapping[key]
    if v == nil then
      raise("value", "KeyError: %s", R.repr(key))
    end
    v = R.check(v)
  end
  local o = { percent = true, align = ">" }
  if width == "*" then
    o.width = (R.num(next_arg()))
  else
    o.width = tonumber(width)
  end
  if prec == ".*" then
    o.prec = (R.num(next_arg()))
  elseif prec ~= "" then
    o.prec = tonumber(prec:sub(2)) or 0
  end
  if flags:find("-", 1, true) then
    o.align = "<"
  elseif flags:find("0", 1, true) and typ ~= "s" and typ ~= "r" and typ ~= "a" and typ ~= "c" then
    o.align, o.fill = "=", "0"
  end
  o.sign = flags:find("+", 1, true) and "+" or (flags:find(" ", 1, true) and " " or nil)
  o.alt = flags:find("#", 1, true) ~= nil
  if v == nil then
    v = next_arg()
  end
  if typ == "%" then
    return "%"
  elseif typ == "s" or typ == "r" or typ == "a" then
    local str = typ == "s" and R.str(v) or R.repr(v)
    if o.prec then
      str = table.concat(R.chars(str), "", 1, math.min(o.prec, ulen(str)))
    end
    return pad(str, o.width, o.align == "=" and ">" or o.align, " ", 0)
  elseif typ == "c" and (type(v) == "string" or R.is_safe(v)) then
    return pad(R.str(v), o.width, o.align, " ", 0)
  end
  if not R.num(v) then
    raise("type", "%%%s format: a real number is required, not %s", typ, R.typename(v))
  end
  o.typ = (typ == "i" or typ == "u") and "d" or typ
  return format_number(v, o)
end

return M
