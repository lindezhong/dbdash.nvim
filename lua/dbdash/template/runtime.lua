-- Template runtime: Python/Jinja value semantics for compiled templates.
--
-- Value model: none = vim.NIL, lists = plain tables, mappings = dbdash.util.map tables,
-- undefined = Undefined objects (StrictUndefined: any use other than `is defined` and
-- `default` raises). Lua numbers do not distinguish int from float, so integral floats
-- print without ".0" (a documented deviation from Jinja).
local map = require("dbdash.util.map")
local errors = require("dbdash.template.errors")

local R = {}

R.NONE = vim.NIL
R.MISSING = setmetatable({}, {
  __tostring = function()
    return "<missing>"
  end,
})

local raise = errors.raise

-- Undefined -------------------------------------------------------------------------------

local Undefined = {}
Undefined.__index = Undefined

---@param hint string message raised when the value is used
function R.undef(hint)
  return setmetatable({ hint = hint }, Undefined)
end

function R.is_undef(v)
  return getmetatable(v) == Undefined
end

---Raise if `v` is undefined; otherwise return it.
function R.check(v)
  if getmetatable(v) == Undefined then
    raise("undefined", v.hint)
  end
  return v
end
local check = R.check

-- Safe strings (output verbatim even with autoescape) -------------------------------------

local Safe = {}
Safe.__index = Safe
function R.safe(s)
  return setmetatable({ s = s }, Safe)
end
function R.is_safe(v)
  return getmetatable(v) == Safe
end

-- Loop object ------------------------------------------------------------------------------

local Loop = {}
Loop.__index = Loop

-- Macro objects (defined with the other value types so typename/str can see them).
local Macro = {}
function R.loop(i, n)
  return setmetatable({
    index = i,
    index0 = i - 1,
    revindex = n - i + 1,
    revindex0 = n - i,
    first = i == 1,
    last = i == n,
    length = n,
  }, Loop)
end

-- Type helpers -----------------------------------------------------------------------------

---Python type name used in error messages.
function R.typename(v)
  local t = type(v)
  if v == R.NONE then
    return "NoneType"
  elseif t == "boolean" then
    return "bool"
  elseif t == "number" then
    return v == math.floor(v) and "int" or "float"
  elseif t == "string" then
    return "str"
  elseif getmetatable(v) == Safe then
    return "Markup"
  elseif getmetatable(v) == Loop then
    return "LoopContext"
  elseif getmetatable(v) == Macro then
    return "Macro"
  elseif map.is_map(v) then
    return "dict"
  elseif t == "table" then
    return "list"
  elseif t == "function" then
    return "function"
  end
  return t
end
local typename = R.typename

local function is_list(v)
  return type(v) == "table" and v ~= R.NONE and getmetatable(v) == nil
end
R.is_list = is_list

---Numbers, with booleans as 0/1 like Python. Returns nil for non-numbers.
local function num(v)
  if type(v) == "number" then
    return v
  elseif v == true then
    return 1
  elseif v == false then
    return 0
  end
end

local CHAR = "[%z\1-\127\192-\247][\128-\191]*"

---Split a string into UTF-8 characters (Python indexes code points).
function R.chars(s)
  local out = {}
  for ch in s:gmatch(CHAR) do
    out[#out + 1] = ch
  end
  return out
end

-- Truthiness and string conversion --------------------------------------------------------

function R.truthy(v)
  check(v)
  if v == nil or v == false or v == R.NONE then
    return false
  elseif v == 0 or v == "" then
    return false
  elseif type(v) == "table" then
    if getmetatable(v) == Safe then
      return v.s ~= ""
    elseif getmetatable(v) == Loop then
      return true
    end
    return next(v) ~= nil
  end
  return true
end

---Python repr() of a float/int.
function R.numstr(v)
  if v ~= v then
    return "nan"
  elseif v == math.huge then
    return "inf"
  elseif v == -math.huge then
    return "-inf"
  elseif v == math.floor(v) and math.abs(v) < 1e16 then
    return ("%.0f"):format(v)
  end
  local s
  for p = 1, 17 do
    s = ("%." .. p .. "e"):format(v)
    if tonumber(s) == v then
      break
    end
  end
  -- s looks like "-1.2345e-05": rebuild in Python's repr style.
  local sign, int, frac, exp = s:match("^(-?)(%d)%.?(%d*)e([-+]%d+)$")
  local digits = (int .. frac):gsub("0+$", "")
  if digits == "" then
    digits = "0"
  end
  exp = tonumber(exp)
  if exp >= -4 and exp < 16 then
    if exp < 0 then
      return sign .. "0." .. string.rep("0", -exp - 1) .. digits
    end
    local ip = digits:sub(1, exp + 1)
    ip = ip .. string.rep("0", exp + 1 - #ip)
    local fp = digits:sub(exp + 2)
    return sign .. ip .. "." .. (fp == "" and "0" or fp)
  end
  local m = digits:sub(1, 1) .. (#digits > 1 and ("." .. digits:sub(2)) or "")
  return ("%s%se%s%02d"):format(sign, m, exp < 0 and "-" or "+", math.abs(exp))
end

---Python repr() of a string.
function R.strrepr(s)
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

---Python repr().
function R.repr(v)
  if type(v) == "string" then
    return R.strrepr(v)
  elseif getmetatable(v) == Safe then
    return "Markup(" .. R.strrepr(v.s) .. ")"
  elseif map.is_map(v) then
    local parts = {}
    for k, x in map.pairs(v) do
      parts[#parts + 1] = R.repr(k) .. ": " .. R.repr(x)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif is_list(v) then
    local parts = {}
    for i = 1, #v do
      parts[i] = R.repr(v[i])
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return R.str(v)
end

---Python str().
function R.str(v)
  check(v)
  local t = type(v)
  if t == "string" then
    return v
  elseif t == "number" then
    return R.numstr(v)
  elseif v == true then
    return "True"
  elseif v == false then
    return "False"
  elseif v == R.NONE or v == nil then
    return "None"
  elseif getmetatable(v) == Safe then
    return v.s
  elseif getmetatable(v) == Loop then
    return "<LoopContext>"
  elseif getmetatable(v) == Macro then
    return ("<Macro '%s'>"):format(v.name)
  elseif t == "table" then
    return R.repr(v)
  end
  return tostring(v)
end

---Value written for {{ expr }}.
function R.out(env, v)
  check(v)
  if getmetatable(v) == Safe then
    return v.s
  elseif env.autoescape and env.escape then
    return env.escape(v)
  end
  return R.str(v)
end

-- Lookup and access ------------------------------------------------------------------------

R.globals = {}

function R.lookup(ctx, name)
  local v = ctx[name]
  if v ~= nil then
    return v
  end
  v = R.globals[name]
  if v ~= nil then
    return v
  end
  local args = ctx.args
  if map.is_map(args) and args[name] ~= nil then
    -- Dashboards pass their arguments as args.<name> (and metadata as meta.<name>).
    return R.undef(("'%s' is undefined; arguments are written args.%s"):format(name, name))
  end
  return R.undef(("'%s' is undefined"):format(name))
end

---{% set args.name = value %}: assign a dashboard argument through env.set_arg (the
---dashboard checks it, updates `args` and keeps the value).
function R.set_arg(env, name, value)
  if not env.set_arg then
    raise("value", "args can only be assigned in a dashboard (args.%s)", name)
  end
  local ok, err = pcall(env.set_arg, name, R.to_lua(value))
  if not ok then
    if type(err) == "table" then
      error(err, 0)
    end
    raise("value", "%s", tostring(err))
  end
end

---Read a template-local variable, falling back to the context when it was never assigned.
function R.v(val, ctx, name)
  if val == R.MISSING then
    return R.lookup(ctx, name)
  end
  return val
end

local function index(seq_len, i)
  local n = num(i)
  if not n or n ~= math.floor(n) then
    return nil
  end
  if n < 0 then
    n = seq_len + n
  end
  if n < 0 or n >= seq_len then
    return nil
  end
  return n + 1
end

---obj[key]
function R.getitem(obj, key)
  check(obj)
  check(key)
  if map.is_map(obj) then
    local v = obj[key]
    if v == nil and type(key) == "boolean" then
      v = obj[num(key)]
    end
    if v ~= nil then
      return v
    end
    return R.undef(("'dict object' has no attribute %s"):format(R.repr(key)))
  elseif getmetatable(obj) == Loop then
    return R.getattr(obj, key)
  elseif is_list(obj) then
    local i = index(#obj, key)
    if i then
      return obj[i]
    end
    return R.undef(("list object has no element %s"):format(R.repr(key)))
  elseif type(obj) == "string" then
    local cs = R.chars(obj)
    local i = index(#cs, key)
    if i then
      return cs[i]
    end
    return R.undef(("str object has no element %s"):format(R.repr(key)))
  end
  return R.undef(("'%s' object has no attribute %s"):format(typename(obj), R.repr(key)))
end

---obj.name
function R.getattr(obj, name)
  check(obj)
  if getmetatable(obj) == Loop then
    local v = obj[name]
    if v ~= nil then
      return v
    end
    if name == "cycle" or name == "previtem" or name == "nextitem" or name == "depth" then
      raise("value", "loop.%s is not supported", name)
    end
  elseif map.is_map(obj) and obj[name] ~= nil then
    return obj[name]
  end
  return R.undef(("'%s object' has no attribute '%s'"):format(typename(obj), name))
end

-- Methods (whitelisted) -------------------------------------------------------------------

---Python str.upper(): like toupper, but "ß" becomes "SS".
function R.upper(s)
  return vim.fn.toupper((s:gsub("ß", "SS")))
end

local function strip_chars(s, chars, left, right)
  local set = chars and ("[" .. chars:gsub("[%]%%%^%-]", "%%%0") .. "]") or "%s"
  if left then
    s = s:gsub("^" .. set .. "+", "")
  end
  if right then
    s = s:gsub(set .. "+$", "")
  end
  return s
end
R.strip_chars = strip_chars

local function prefix_any(s, arg, fn)
  check(arg)
  if is_list(arg) then
    for _, p in ipairs(arg) do
      if fn(s, p) then
        return true
      end
    end
    return false
  elseif type(arg) ~= "string" then
    raise("type", "startswith/endswith arg must be str or a tuple of str, not %s", typename(arg))
  end
  return fn(s, arg)
end

local METHODS = {
  dict = {
    items = function(d)
      local out = {}
      for k, v in map.pairs(d) do
        out[#out + 1] = { k, v }
      end
      return out
    end,
    keys = function(d)
      return map.keys(d)
    end,
    values = function(d)
      local out = {}
      for _, v in map.pairs(d) do
        out[#out + 1] = v
      end
      return out
    end,
    get = function(d, k, dflt)
      local v = d[check(k)]
      if v == nil then
        return dflt == nil and R.NONE or dflt
      end
      return v
    end,
  },
  str = {
    upper = function(s)
      return R.upper(s)
    end,
    lower = function(s)
      return vim.fn.tolower(s)
    end,
    strip = function(s, chars)
      return strip_chars(s, chars ~= nil and chars ~= R.NONE and check(chars) or nil, true, true)
    end,
    startswith = function(s, p)
      return prefix_any(s, p, function(a, b)
        return a:sub(1, #b) == b
      end)
    end,
    endswith = function(s, p)
      return prefix_any(s, p, function(a, b)
        return b == "" or a:sub(-#b) == b
      end)
    end,
  },
}

R.METHOD_NAMES = { "items", "keys", "values", "get", "upper", "lower", "strip", "startswith", "endswith" }

---obj.name(args...) for the whitelisted methods.
function R.method(obj, name, ...)
  check(obj)
  local tn = typename(obj)
  local fns = METHODS[tn == "Markup" and "str" or tn]
  local fn = fns and fns[name]
  if not fn then
    raise("undefined", "'%s object' has no attribute '%s'", tn, name)
  end
  if tn == "Markup" then
    obj = obj.s
  end
  return fn(obj, ...)
end

local METHOD_SET = {}
for _, m in ipairs(R.METHOD_NAMES) do
  METHOD_SET[m] = true
end

---obj.name(args): a macro exported by an imported template, or a whitelisted method.
function R.call_attr(env, obj, name, args, kwargs)
  check(obj)
  if map.is_map(obj) and (getmetatable(obj[name]) == Macro or type(obj[name]) == "function") then
    return R.call(env, obj[name], args, kwargs) -- a macro, or a function of a .lua module
  end
  if not METHOD_SET[name] then
    raise("type", "calling '.%s()' is not supported (allowed methods: %s)", name, table.concat(R.METHOD_NAMES, ", "))
  end
  if next(kwargs) then
    raise("type", "keyword arguments are not supported for methods")
  end
  for i = 1, #args do
    check(args[i])
  end
  return R.method(obj, name, unpack(args))
end

---Call a global function value: fn(args, kwargs, env).
function R.call(env, fn, args, kwargs)
  check(fn)
  if type(fn) ~= "function" and getmetatable(fn) ~= Macro then
    raise("type", "'%s' object is not callable", typename(fn))
  end
  for i = 1, #args do
    check(args[i])
  end
  return fn(args, kwargs, env)
end

-- Lua in templates ------------------------------------------------------------------------

local module_raw = setmetatable({}, { __mode = "k" }) -- template mapping -> Lua table

---A template value as Lua data: none / undefined / missing -> nil, safe -> its string,
---lists and mappings element by element (mappings stay util.map tables).
function R.to_lua(v)
  if v == R.NONE or v == R.MISSING or R.is_undef(v) then
    return nil
  elseif module_raw[v] then
    return module_raw[v] -- an imported .lua module: its own table
  elseif R.is_safe(v) then
    return v.s
  elseif map.is_map(v) then
    local out = map.new()
    for k, x in map.pairs(v) do
      map.set(out, k, R.to_lua(x))
    end
    return out
  elseif type(v) == "table" and getmetatable(v) == nil then
    local out = {}
    for i = 1, #v do
      out[i] = R.to_lua(v[i])
    end
    return out
  end
  return v
end

---Lua data as a template value: nil -> none, arrays -> lists, other tables -> mappings
---(keys sorted), safe strings and callables kept.
function R.from_lua(v)
  if v == nil then
    return R.NONE
  elseif type(v) ~= "table" or getmetatable(v) ~= nil and not map.is_map(v) then
    return v -- strings, numbers, booleans, functions, safe strings, macros
  elseif map.is_map(v) then
    local out = map.new()
    for k, x in map.pairs(v) do
      map.set(out, k, R.from_lua(x))
    end
    return out
  elseif vim.islist(v) then
    local out = {}
    for i = 1, #v do
      out[i] = R.from_lua(v[i])
    end
    return out
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local out = map.new()
  for _, k in ipairs(keys) do
    map.set(out, k, R.from_lua(v[k]))
  end
  return out
end

---The Lua environment of template code: the globals plus args, meta, store and the dbdash
---helpers (env.lua: { args, meta, store, helpers } from the dashboard), and `extra` names.
function R.lua_env(env, extra)
  local g = env.lua or {}
  local t = setmetatable({
    args = g.args or {},
    meta = g.meta or require("dbdash.metadata").for_lua({}),
    store = g.store or {},
    dbdash = g.helpers or require("dbdash.db.lua_env").helpers,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do
    t[k] = v
  end
  return t
end

---Run Lua with env.timeout; Lua errors become template errors at their own line when they
---come from this template's code (chunk `chunk_name`), else at the current line.
function R.run_lua(env, fn, chunk_name, source)
  local ok, ret = require("dbdash.db.lua_env").guard(fn, env.timeout, env.cancel)
  if ok then
    -- Arguments the code assigned (args.x = v) apply now: later template text sees them.
    local after = env.lua and env.lua.after
    if after then
      local aok, aerr = pcall(after)
      if not aok then
        if type(aerr) == "table" then
          error(aerr, 0)
        end
        raise("lua", "%s", tostring(aerr))
      end
    end
    return ret
  end
  if type(ret) == "table" then
    if errors.is(ret) or (ret.phase and ret.message and not ret.timeout) then
      error(ret, 0) -- a template error from nested code, or a DbError from dbdash.query
    end
    raise("lua", ret.message or vim.inspect(ret))
  end
  local msg = tostring(ret)
  local file, line, rest = msg:match("^(.-):(%d+): (.*)$")
  if file and file == chunk_name then
    local e = errors.new("lua", rest, tonumber(line))
    e.source = source -- a .lua module: its own file (the template's lines do not apply)
    error(e, 0)
  end
  raise("lua", msg)
end

---Run a .lua module (once per render, so its functions see this render's args and meta)
---and export its table: functions become callable from expressions (h.f(x)), other
---values template values. In {% lua %} blocks vars.h is the module's own table.
function R.lua_module(env, path, text)
  local name = vim.fn.fnamemodify(path, ":~:.")
  local chunk, err = load(text, "=" .. name, "t", R.lua_env(env))
  if not chunk then
    local l, rest = tostring(err):match(":(%d+): (.*)$")
    local e = errors.new("lua", "syntax error: " .. (rest or tostring(err)), tonumber(l))
    e.source = name
    error(e, 0)
  end
  local t = R.run_lua(env, chunk, name, name)
  if type(t) ~= "table" then
    local e = errors.new("lua", ("a module must return a table (got %s)"):format(type(t)))
    e.source = name
    error(e, 0)
  end
  local mod = map.new()
  local keys = vim.tbl_keys(t)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "function" then
      local fn = v
      map.set(mod, k, function(args, kwargs, call_env)
        if next(kwargs) then
          raise("type", "%s.%s() takes no keyword arguments (a Lua function)", name, tostring(k))
        end
        local lua_args = {}
        for i = 1, #args do
          lua_args[i] = R.to_lua(args[i])
        end
        local n = #args
        return R.from_lua(R.run_lua(call_env, function()
          return fn(unpack(lua_args, 1, n))
        end, name, name))
      end)
    else
      map.set(mod, k, R.from_lua(v))
    end
  end
  module_raw[mod] = t
  return mod
end

---{% lua %} ... {% endlua %}: run the code; its return value is output like {{ }}.
---@param line integer template line where the code starts
---@param vars_fn fun(): table the template variables visible here (set, for, macro args)
function R.lua_block(env, code, line, vars_fn)
  local name = env.source or "template"
  local vars = {}
  for k, v in pairs(vars_fn()) do
    vars[k] = R.to_lua(v)
  end
  local view = setmetatable({}, {
    __index = vars,
    __newindex = function(_, k)
      error(("vars is read-only (vars.%s)"):format(tostring(k)), 2)
    end,
  })
  -- Compiled for each run with its own environment: two renders may run the same block
  -- at once (each waiting inside it on a dbdash helper).
  local chunk, err = load(string.rep("\n", line - 1) .. code, "=" .. name, "t", R.lua_env(env, { vars = view }))
  if not chunk then
    local l, rest = tostring(err):match(":(%d+): (.*)$")
    error(errors.new("lua", "syntax error: " .. (rest or tostring(err)), tonumber(l) or line), 0)
  end
  local ret = R.run_lua(env, chunk, name)
  if ret == nil then
    return ""
  end
  return R.out(env, R.from_lua(ret))
end

-- Macros and imports ------------------------------------------------------------------------

Macro.__index = Macro
Macro.__call = function(self, args, kwargs, env)
  local s = self.fn(args, kwargs, env)
  if env.autoescape then
    return R.safe(s) -- like Jinja's Markup: not escaped again
  end
  return s
end

---Wrap a compiled macro body as a callable value.
function R.macro(name, fn)
  return setmetatable({ name = name, fn = fn }, Macro)
end

function R.is_macro(v)
  return getmetatable(v) == Macro
end

---Reject surplus positional or unknown keyword arguments.
function R.check_args(name, args, kwargs, params)
  if #args > #params then
    raise("type", "macro '%s' takes not more than %d argument(s)", name, #params)
  end
  for k in pairs(kwargs) do
    local known = false
    for _, p in ipairs(params) do
      known = known or p == k
    end
    if not known then
      raise("type", "macro '%s' takes no keyword argument '%s'", name, k)
    end
  end
end

local module_names = setmetatable({}, { __mode = "k" })

---Run another template without the caller's context and return its macros as a mapping.
function R.import(env, target)
  check(target)
  if type(target) ~= "string" then
    raise("type", "import target must be a string, not %s", typename(target))
  end
  if not env.load_template then
    raise("value", "{%% import %%} needs a template loader (base directory)")
  end
  env._modules = env._modules or {}
  if env._modules[target] then
    return env._modules[target]
  end
  env._importing = env._importing or {}
  if env._importing[target] then
    raise("value", "circular import of '%s'", target)
  end
  env._importing[target] = true
  local tpl, path, text = env.load_template(target)
  if env.check_file then
    -- Dashboards: a file with Lua must be covered by the config's trust.
    env.check_file(path or target, text or "", tpl.lua and "lua" or "template")
  end
  if tpl.lua then
    local mod = R.lua_module(env, path or target, text or "")
    env._importing[target] = nil
    module_names[mod] = target
    env._modules[target] = mod
    return mod
  end
  local L = { l = nil }
  local outer_source = env.source
  env.source = path or target -- Lua in the imported file reports its own name
  -- Imported templates do not see the caller's variables, only env.context (dashboards:
  -- args and meta).
  local ok, out, exports = pcall(tpl.fn, env.context or {}, env, L)
  env._importing[target] = nil
  env.source = outer_source
  if not ok then
    if errors.is(out) then
      out.line = out.line or L.l
      out.source = out.source or path or target
    end
    error(out, 0)
  end
  local mod = map.new()
  for _, e in ipairs(exports) do
    if e[2] ~= R.MISSING then
      map.set(mod, e[1], e[2])
    end
  end
  module_names[mod] = target
  env._modules[target] = mod
  return mod
end

---A name from an imported module; missing names stay undefined until used (like Jinja).
function R.import_name(mod, name)
  local v = mod[name]
  if v == nil then
    return R.undef(("the template '%s' does not export the requested name '%s'"):format(module_names[mod] or "?", name))
  end
  return v
end

-- Collections ----------------------------------------------------------------------------

function R.dict(flat)
  local d = map.new()
  for i = 1, #flat, 2 do
    map.set(d, check(flat[i]), flat[i + 1])
  end
  return d
end

---Items to iterate over in a for loop.
function R.iter(v)
  check(v)
  if map.is_map(v) then
    return map.keys(v)
  elseif is_list(v) then
    return v
  elseif type(v) == "string" then
    return R.chars(v)
  elseif getmetatable(v) == Safe then
    return R.chars(v.s)
  end
  raise("type", "'%s' object is not iterable", typename(v))
end

---Unpack an item into `n` loop/set targets.
function R.unpack(item, n)
  check(item)
  local seq = is_list(item) and item or (type(item) == "string" and R.chars(item)) or nil
  if not seq then
    raise("type", "cannot unpack non-iterable %s object", typename(item))
  end
  if #seq ~= n then
    raise("value", "expected %d values to unpack, got %d", n, #seq)
  end
  return unpack(seq, 1, n)
end

-- Operators -------------------------------------------------------------------------------

local function op_error(op, a, b)
  raise("type", "unsupported operand type(s) for %s: '%s' and '%s'", op, typename(a), typename(b))
end

local function as_str(v)
  if type(v) == "string" then
    return v
  elseif getmetatable(v) == Safe then
    return v.s
  end
end

function R.add(a, b)
  check(a)
  check(b)
  local x, y = num(a), num(b)
  if x and y then
    return x + y
  end
  local s, t = as_str(a), as_str(b)
  if s and t then
    return s .. t
  end
  if is_list(a) and is_list(b) then
    local out = {}
    vim.list_extend(out, a)
    vim.list_extend(out, b)
    return out
  end
  op_error("+", a, b)
end

function R.sub(a, b)
  local x, y = num(check(a)), num(check(b))
  if not (x and y) then
    op_error("-", a, b)
  end
  return x - y
end

function R.mul(a, b)
  check(a)
  check(b)
  local x, y = num(a), num(b)
  if x and y then
    return x * y
  end
  local seq, n = a, y
  if x and not y then
    seq, n = b, x
  end
  if n and n == math.floor(n) then
    local s = as_str(seq)
    if s then
      return n > 0 and s:rep(n) or ""
    elseif is_list(seq) then
      local out = {}
      for _ = 1, n do
        vim.list_extend(out, seq)
      end
      return out
    end
  end
  op_error("*", a, b)
end

function R.div(a, b)
  local x, y = num(check(a)), num(check(b))
  if not (x and y) then
    op_error("/", a, b)
  end
  if y == 0 then
    raise("value", "division by zero")
  end
  return x / y
end

function R.floordiv(a, b)
  local x, y = num(check(a)), num(check(b))
  if not (x and y) then
    op_error("//", a, b)
  end
  if y == 0 then
    raise("value", "integer division or modulo by zero")
  end
  return math.floor(x / y)
end

function R.mod(a, b)
  check(a)
  check(b)
  local x, y = num(a), num(b)
  if not (x and y) then
    if as_str(a) then
      raise("type", "string formatting with '%%' is not supported; use filters instead")
    end
    op_error("%", a, b)
  end
  if y == 0 then
    raise("value", "integer division or modulo by zero")
  end
  return x - math.floor(x / y) * y
end

function R.pow(a, b)
  local x, y = num(check(a)), num(check(b))
  if not (x and y) then
    op_error("** or pow()", a, b)
  end
  return x ^ y
end

function R.concat(a, b)
  return R.str(a) .. R.str(b)
end

function R.neg(a)
  local x = num(check(a))
  if not x then
    raise("type", "bad operand type for unary -: '%s'", typename(a))
  end
  return -x
end

function R.pos(a)
  local x = num(check(a))
  if not x then
    raise("type", "bad operand type for unary +: '%s'", typename(a))
  end
  return x
end

-- Comparison ------------------------------------------------------------------------------

function R.eq(a, b)
  check(a)
  check(b)
  local x, y = num(a), num(b)
  if x and y then
    return x == y
  end
  local s, t = as_str(a), as_str(b)
  if s or t then
    return s == t
  end
  if map.is_map(a) and map.is_map(b) then
    for k, v in pairs(a) do
      if b[k] == nil or not R.eq(v, b[k]) then
        return false
      end
    end
    for k in pairs(b) do
      if a[k] == nil then
        return false
      end
    end
    return true
  end
  if is_list(a) and is_list(b) then
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if not R.eq(a[i], b[i]) then
        return false
      end
    end
    return true
  end
  return rawequal(a, b)
end

local function lt(a, b, op)
  local x, y = num(a), num(b)
  if x and y then
    return x < y
  end
  local s, t = as_str(a), as_str(b)
  if s and t then
    return s < t
  end
  if is_list(a) and is_list(b) then
    for i = 1, math.min(#a, #b) do
      if not R.eq(a[i], b[i]) then
        return lt(a[i], b[i], op)
      end
    end
    return #a < #b
  end
  raise(
    "type",
    "'%s' not supported between instances of '%s' and '%s'",
    op,
    typename(a),
    typename(b)
  )
end

function R.contains(container, item)
  check(container)
  check(item)
  local s = as_str(container)
  if s then
    local t = as_str(item)
    if not t then
      raise("type", "'in <string>' requires string as left operand, not %s", typename(item))
    end
    return s:find(t, 1, true) ~= nil
  elseif map.is_map(container) then
    return container[item] ~= nil
  elseif is_list(container) then
    for _, v in ipairs(container) do
      if R.eq(v, item) then
        return true
      end
    end
    return false
  end
  raise("type", "argument of type '%s' is not iterable", typename(container))
end

function R.cmp(op, a, b)
  check(a)
  check(b)
  if op == "==" then
    return R.eq(a, b)
  elseif op == "!=" then
    return not R.eq(a, b)
  elseif op == "<" then
    return lt(a, b, op)
  elseif op == ">" then
    return lt(b, a, op)
  elseif op == "<=" then
    return R.eq(a, b) or lt(a, b, op)
  elseif op == ">=" then
    return R.eq(a, b) or lt(b, a, op)
  elseif op == "in" then
    return R.contains(b, a)
  elseif op == "notin" then
    return not R.contains(b, a)
  end
  error("unknown comparison " .. op)
end

-- Filters and tests -----------------------------------------------------------------------

R.filters = {}
R.tests = {}

function R.filter(env, name, v, args, kwargs)
  local f = R.filters[name]
  if name ~= "default" and name ~= "d" then
    check(v)
  end
  for i = 1, #args do
    check(args[i])
  end
  return f(env, v, args, kwargs)
end

function R.test(env, name, v, args)
  return R.tests[name](env, v, args)
end

return R
