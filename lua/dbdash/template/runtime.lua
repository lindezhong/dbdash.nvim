-- Template runtime: Python/Jinja value semantics for compiled templates.
--
-- Value model: none = vim.NIL, lists = plain tables, tuples = tables with the Tuple
-- metatable, mappings = dbdash.util.map tables, undefined = Undefined objects
-- (StrictUndefined: any use other than `is defined` and `default` raises). Numbers: a Lua
-- number is an int when it is integral and a float otherwise; a float with an integral
-- value (2.0) is boxed (Float), so it prints as Python does.
local markup = require("dbdash.util.markup")
local number = require("dbdash.util.number")
local pystr = require("dbdash.util.pystr")
local map = require("dbdash.util.map")
local errors = require("dbdash.template.errors")

local M = {}

M.NONE = vim.NIL
M.MISSING = setmetatable({}, {
  __tostring = function()
    return "<missing>"
  end,
})

local raise = errors.raise

-- Undefined -------------------------------------------------------------------------------

local Undefined = {}
Undefined.__index = Undefined

---@param hint string message raised when the value is used
function M.undef(hint)
  return setmetatable({ hint = hint }, Undefined)
end

function M.is_undef(v)
  return getmetatable(v) == Undefined
end

---Raise if `v` is undefined; otherwise return it.
function M.check(v)
  if getmetatable(v) == Undefined then
    raise("undefined", v.hint)
  end
  return v
end
local check = M.check

-- Safe strings (output verbatim even with autoescape) -------------------------------------

local Safe = markup.Safe
M.safe = markup.safe
M.is_safe = markup.is_safe

---The text of a string or safe string; nil for other values.
local function as_str(v)
  if type(v) == "string" then
    return v
  elseif getmetatable(v) == Safe then
    return v.s
  end
end

-- Loop object ------------------------------------------------------------------------------

local Loop = {}
Loop.__index = Loop

-- Macro objects (defined with the other value types so typename/str can see them).
local Macro = {}

---The state of one loop: its items, depth (recursive loops) and loop.changed() memory.
---@param rec function? the recursive loop's function (loop(items) renders it again)
function M.loop_state(items, depth, rec)
  return { items = items, depth = depth, rec = rec }
end

---The `loop` variable of iteration `i`.
function M.loop(state, i)
  local items = state.items
  local n = #items
  return setmetatable({
    index = i,
    index0 = i - 1,
    revindex = n - i + 1,
    revindex0 = n - i,
    first = i == 1,
    last = i == n,
    length = n,
    depth = state.depth,
    depth0 = state.depth - 1,
    previtem = i > 1 and items[i - 1] or M.undef("there is no previous item"),
    nextitem = i < n and items[i + 1] or M.undef("there is no next item"),
    cycle = function(args)
      if #args == 0 then
        raise("type", "no items for cycling given")
      end
      return args[(i - 1) % #args + 1]
    end,
    changed = function(args)
      local changed = state.last == nil or not M.eq(args, state.last)
      state.last = args
      return changed
    end,
    _state = state,
  }, Loop)
end

---{% for x in xs if test %}: the items for which `keep(item)` is true.
function M.loop_filter(items, keep)
  local out = {}
  for _, item in ipairs(items) do
    if keep(item) then
      out[#out + 1] = item
    end
  end
  return out
end

-- loop(items) in a recursive loop: the loop body for `items`, one level deeper.
Loop.__call = function(self, args, _, env)
  local state = self._state
  if not state.rec then
    raise("type", "Tried to call non recursive loop. Maybe you forgot the 'recursive' modifier.")
  end
  return M.markup(env, state.rec(args[1], state.depth + 1))
end

-- Floats with an integral value ------------------------------------------------------------

local Float = number.Float
M.float = number.float
M.is_float_box = number.is_float_box

---True for any float (boxed, non-integral, inf or nan).
function M.is_float(v)
  if type(v) == "number" then
    return v ~= math.floor(v) or v ~= v or v == math.huge or v == -math.huge
  end
  return getmetatable(v) == Float
end

---A number result: a float when `isf` (or not integral), else an int.
local function mknum(x, isf)
  if isf then
    return M.float(x)
  end
  return x
end
M.mknum = mknum

-- Tuples -----------------------------------------------------------------------------------

local Tuple = {}
Tuple.__index = Tuple

---Mark a Lua array as a tuple.
function M.tuple(t)
  return setmetatable(t, Tuple)
end

function M.is_tuple(v)
  return getmetatable(v) == Tuple
end

-- Named tuples (groupby's (grouper, list)): fields readable as attributes.
local tuple_names = setmetatable({}, { __mode = "k" })

---A tuple whose items are also attributes `fields` (it prints as a tuple).
function M.named_tuple(name, fields, values)
  tuple_names[values] = { name = name, fields = fields }
  return M.tuple(values)
end

-- Dictionary views (d.keys(), d.values(), d.items()): sequences shown as dict_keys([...])

local View = {}
View.__index = View
local view_names = setmetatable({}, { __mode = "k" })

function M.view(list, name)
  view_names[list] = name
  return setmetatable(list, View)
end

-- Read-only values (args, meta): mutating methods refuse them --------------------------

M.frozen = setmetatable({}, { __mode = "k" }) -- table -> name shown in the error

---Mark `v` and the tables in it read-only (`name` for messages).
function M.freeze(v, name)
  if type(v) == "table" and v ~= vim.NIL and not M.frozen[v] then
    M.frozen[v] = name
    for _, x in pairs(v) do
      M.freeze(x, name)
    end
  end
  return v
end

-- Type helpers -----------------------------------------------------------------------------

-- Type names of other values (namespace, cycler, ...).
M.typenames = setmetatable({}, { __mode = "k" })

---Python type name used in error messages.
function M.typename(v)
  local t = type(v)
  if t == "table" and M.typenames[v] then
    return M.typenames[v]
  end
  if v == M.NONE then
    return "NoneType"
  elseif t == "boolean" then
    return "bool"
  elseif t == "number" then
    return M.is_float(v) and "float" or "int"
  elseif getmetatable(v) == Float then
    return "float"
  elseif getmetatable(v) == Tuple then
    return "tuple"
  elseif getmetatable(v) == View then
    return view_names[v] or "dict_keys"
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
local typename = M.typename

---Lists and tuples (sequences of values).
local function is_list(v)
  if type(v) ~= "table" or v == M.NONE then
    return false
  end
  local mt = getmetatable(v)
  return mt == nil or mt == Tuple or mt == View
end
M.is_list = is_list

---Numbers, with booleans as 0/1 like Python. Returns nil for non-numbers; the second
---value is true for floats.
local function num(v)
  local t = type(v)
  if t == "number" then
    return v, v ~= math.floor(v) or v ~= v or v == math.huge or v == -math.huge
  elseif t == "boolean" then
    return v and 1 or 0, false
  elseif getmetatable(v) == Float then
    return v.v, true
  end
end
M.num = num

local CHAR = "[%z\1-\127\192-\247][\128-\191]*"

---Split a string into UTF-8 characters (Python indexes code points).
function M.chars(s)
  local out = {}
  for ch in s:gmatch(CHAR) do
    out[#out + 1] = ch
  end
  return out
end

-- Truthiness and string conversion --------------------------------------------------------

function M.truthy(v)
  check(v)
  if v == nil or v == false or v == M.NONE then
    return false
  elseif v == 0 or v == "" then
    return false
  elseif type(v) == "table" then
    if getmetatable(v) == Float then
      return v.v ~= 0
    elseif getmetatable(v) == Safe then
      return v.s ~= ""
    elseif getmetatable(v) == Loop then
      return true
    end
    return next(v) ~= nil
  end
  return true
end

M.floatstr = number.floatstr
M.numstr = number.numstr

M.strrepr = pystr.strrepr

---Python repr(): template values here (tuples, dict views, namespaces, ...), plain data
---in util.pystr.
function M.repr(v)
  local mt = getmetatable(v)
  if mt == Tuple or mt == View then
    local parts = {}
    for i = 1, #v do
      parts[i] = M.repr(v[i])
    end
    if mt == Tuple then
      return "(" .. table.concat(parts, ", ") .. (#v == 1 and ",)" or ")")
    end
    return (view_names[v] or "dict_keys") .. "([" .. table.concat(parts, ", ") .. "])"
  elseif M.repr_hook[mt or false] then
    return M.repr_hook[mt](v)
  elseif type(v) == "string" or mt == Safe or map.is_map(v) or is_list(v) then
    return pystr.repr(v, M.repr)
  end
  return M.str(v)
end

---repr() of other value types by metatable (namespace, cycler, ...).
M.repr_hook = {}

---Python str(): template values here (loops, macros), the rest in util.pystr.
function M.str(v)
  check(v)
  local mt = getmetatable(v)
  if mt == Loop then
    return "<LoopContext>"
  elseif mt == Macro then
    return ("<Macro '%s'>"):format(v.name)
  elseif type(v) == "table" and v ~= M.NONE and mt ~= Safe and mt ~= Float then
    return M.repr(v)
  end
  return pystr.str(v)
end

---HTML escaping (Jinja's escape / autoescape outside SQL).
function M.html_escape(s)
  return (
    s:gsub(
      "[&<>\"']",
      { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&#34;", ["'"] = "&#39;" }
    )
  )
end

---Value written for {{ expr }}: with autoescape, the dialect's literal in SQL (env.escape),
---HTML escaping elsewhere.
function M.out(env, v)
  check(v)
  if getmetatable(v) == Safe then
    return v.s
  elseif env.autoescape then
    if env.escape then
      return env.escape(v)
    end
    return M.html_escape(M.str(v))
  end
  return M.str(v)
end

---Template output as a value: marked safe with autoescape (Jinja's Markup), so it is not
---escaped again.
function M.markup(env, s)
  if env.autoescape then
    return M.safe(s)
  end
  return s
end

-- Lookup and access ------------------------------------------------------------------------

M.globals = {}

-- Set by the engine (template/init.lua) from modules that require this one:
---Call a Python method of a value ("a".upper()): found, result.
---@type fun(obj: any, name: string, args: any[], kwargs: table): boolean, any
M.call_method = nil
---printf-style formatting: "x=%s" % value.
---@type fun(s: string, values: any): string
M.percent = nil

---A context with `vars` (template variables: name -> value, M.MISSING skipped) over `ctx`:
---what an include or an import "with context" sees.
function M.layer(ctx, vars)
  local t = {}
  for k, v in pairs(vars) do
    if v ~= M.MISSING then
      t[k] = v
    end
  end
  return setmetatable(t, { __index = ctx })
end

function M.lookup(ctx, name)
  local v = ctx[name]
  if v ~= nil then
    return v
  end
  v = M.globals[name]
  if v ~= nil then
    return v
  end
  local args = ctx.args
  if map.is_map(args) and args[name] ~= nil then
    -- Dashboards pass their arguments as args.<name> (and metadata as meta.<name>).
    return M.undef(("'%s' is undefined; arguments are written args.%s"):format(name, name))
  end
  return M.undef(("'%s' is undefined"):format(name))
end

---{% set args.name = value %}: assign a dashboard argument through env.set_arg (the
---dashboard checks it, updates `args` and keeps the value).
function M.set_arg(env, name, value)
  if not env.set_arg then
    raise("value", "args can only be assigned in a dashboard (args.%s)", name)
  end
  local ok, err = pcall(env.set_arg, name, M.to_lua(value))
  if not ok then
    if type(err) == "table" then
      error(err, 0)
    end
    raise("value", "%s", tostring(err))
  end
end

---Read a template-local variable, falling back to the context when it was never assigned.
function M.v(val, ctx, name)
  if val == M.MISSING then
    return M.lookup(ctx, name)
  end
  return val
end

local function index(seq_len, i)
  local n, isf = num(i)
  if not n or isf then
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
---A mapping key: floats with an integral value are the same key as the int (2.0 == 2).
local function key_of(k)
  if getmetatable(k) == Float then
    return k.v
  end
  return k
end
M.key_of = key_of

function M.getitem(obj, key)
  check(obj)
  check(key)
  if map.is_map(obj) then
    key = key_of(key)
    local v = obj[key]
    if v == nil and type(key) == "boolean" then
      v = obj[num(key)]
    end
    if v ~= nil then
      return v
    end
    return M.undef(("'dict object' has no attribute %s"):format(M.repr(key)))
  elseif getmetatable(obj) == Loop then
    return M.getattr(obj, key)
  elseif is_list(obj) then
    local i = index(#obj, key)
    if i then
      return obj[i]
    end
    return M.undef(("list object has no element %s"):format(M.repr(key)))
  elseif type(obj) == "string" then
    local cs = M.chars(obj)
    local i = index(#cs, key)
    if i then
      return cs[i]
    end
    return M.undef(("str object has no element %s"):format(M.repr(key)))
  end
  return M.undef(("'%s' object has no attribute %s"):format(typename(obj), M.repr(key)))
end

---obj.name
function M.getattr(obj, name)
  check(obj)
  local mt = getmetatable(obj)
  if mt == Macro then
    local v = obj[name]
    if v ~= nil and name ~= "fn" then
      return v
    end
  elseif M.getattr_hook[mt or false] then
    local v = M.getattr_hook[mt](obj, name)
    if v ~= nil then
      return v
    end
  end
  if getmetatable(obj) == Loop then
    local v = obj[name]
    if v ~= nil then
      return v
    end
  elseif map.is_map(obj) and obj[name] ~= nil then
    return obj[name]
  end
  return M.undef(("'%s object' has no attribute '%s'"):format(typename(obj), name))
end

---Attributes of other value types by metatable (namespace, cycler, self, ...).
M.getattr_hook = {}

M.getattr_hook[Tuple] = function(t, name)
  local named = tuple_names[t]
  for i, f in ipairs(named and named.fields or {}) do
    if f == name then
      return t[i]
    end
  end
end

-- Methods ------------------------------------------------------------------------------------

---Python str.upper(): like toupper, but "ß" becomes "SS".
function M.upper(s)
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
M.strip_chars = strip_chars

---obj.name(args): a macro or function in a mapping (imported template, .lua module), a
---method of the value (dbdash.template.methods: Python's str, dict, list methods), or a
---callable attribute (namespace, cycler, ...).
function M.call_attr(env, obj, name, args, kwargs)
  check(obj)
  if map.is_map(obj) and (getmetatable(obj[name]) == Macro or type(obj[name]) == "function") then
    return M.call(env, obj[name], args, kwargs) -- a macro, or a function of a .lua module
  end
  for i = 1, #args do
    check(args[i])
  end
  local found, out = M.call_method(obj, name, args, kwargs)
  if found then
    return out
  end
  local attr = M.getattr(obj, name)
  if not M.is_undef(attr) then
    return M.call(env, attr, args, kwargs)
  end
  raise("undefined", "'%s object' has no attribute '%s'", typename(obj), name)
end

-- Keyword arguments keep their order (a side table: they are plain Lua tables).
local kw_order = setmetatable({}, { __mode = "k" })

---Keyword arguments `t` written in the order `names`.
function M.kw(t, names)
  kw_order[t] = names
  return t
end

---Names of keyword arguments in the order they were written.
function M.kw_keys(t)
  local out, seen = {}, {}
  for _, k in ipairs(kw_order[t] or {}) do
    if t[k] ~= nil and not seen[k] then
      out[#out + 1] = k
      seen[k] = true
    end
  end
  local rest = {}
  for k in pairs(t) do
    if not seen[k] then
      rest[#rest + 1] = k
    end
  end
  table.sort(rest)
  return vim.list_extend(out, rest)
end

---*list in a call: extra positional arguments.
function M.dyn_args(args, extra)
  check(extra)
  local out = vim.list_extend({}, args)
  for _, v in ipairs(M.iter(extra)) do
    out[#out + 1] = v
  end
  return out
end

---**mapping in a call: extra keyword arguments.
function M.dyn_kwargs(kwargs, extra)
  check(extra)
  if not map.is_map(extra) then
    raise("type", "argument after ** must be a mapping, not %s", typename(extra))
  end
  local out, names = {}, {}
  for _, k in ipairs(M.kw_keys(kwargs)) do
    out[k] = kwargs[k]
    names[#names + 1] = k
  end
  for k, v in map.pairs(extra) do
    if out[k] ~= nil then
      raise("type", "got multiple values for keyword argument '%s'", tostring(k))
    end
    out[k] = v
    names[#names + 1] = k
  end
  return M.kw(out, names)
end

---Call a global function value: fn(args, kwargs, env).
function M.call(env, fn, args, kwargs)
  check(fn)
  local mt = getmetatable(fn)
  if
    type(fn) ~= "function"
    and mt ~= Macro
    and mt ~= Loop
    and not (mt and mt.__call and M.callable_types[mt])
  then
    raise("type", "'%s' object is not callable", typename(fn))
  end
  for i = 1, #args do
    check(args[i])
  end
  return fn(args, kwargs, env)
end

---Metatables of other callable values (joiner, cycler methods, ...).
M.callable_types = {}

-- Lua in templates ------------------------------------------------------------------------

local module_raw = setmetatable({}, { __mode = "k" }) -- template mapping -> Lua table

---A template value as Lua data: none / undefined / missing -> nil, safe -> its string,
---lists and mappings element by element (mappings stay util.map tables).
function M.to_lua(v)
  if v == M.NONE or v == M.MISSING or M.is_undef(v) then
    return nil
  elseif module_raw[v] then
    return module_raw[v] -- an imported .lua module: its own table
  elseif M.is_safe(v) then
    return v.s
  elseif getmetatable(v) == Float then
    return v.v
  elseif map.is_map(v) then
    local out = map.new()
    for k, x in map.pairs(v) do
      map.set(out, k, M.to_lua(x))
    end
    return out
  elseif is_list(v) then
    local out = {}
    for i = 1, #v do
      out[i] = M.to_lua(v[i])
    end
    return out
  end
  return v
end

---Lua data as a template value: nil -> none, arrays -> lists, other tables -> mappings
---(keys sorted), safe strings and callables kept.
function M.from_lua(v)
  if v == nil then
    return M.NONE
  elseif type(v) ~= "table" or getmetatable(v) ~= nil and not map.is_map(v) then
    return v -- strings, numbers, booleans, functions, safe strings, macros
  elseif map.is_map(v) then
    local out = map.new()
    for k, x in map.pairs(v) do
      map.set(out, k, M.from_lua(x))
    end
    return out
  elseif vim.islist(v) then
    local out = {}
    for i = 1, #v do
      out[i] = M.from_lua(v[i])
    end
    return out
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local out = map.new()
  for _, k in ipairs(keys) do
    map.set(out, k, M.from_lua(v[k]))
  end
  return out
end

---The Lua environment of template code: the globals plus args, meta, store and the dbdash
---helpers (env.lua: { args, meta, store, helpers } from the dashboard; without helpers,
---those of util/sandbox.lua), and `extra` names.
function M.lua_env(env, extra)
  local g = env.lua or {}
  local t = setmetatable({
    args = g.args or {},
    meta = g.meta or require("dbdash.util.readonly").proxy({}, "meta"),
    store = g.store or {},
    dbdash = g.helpers or require("dbdash.util.sandbox").helpers,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do
    t[k] = v
  end
  return t
end

---Run Lua with env.timeout; Lua errors become template errors at their own line when they
---come from this template's code (chunk `chunk_name`), else at the current line.
function M.run_lua(env, fn, chunk_name, source)
  local ok, ret = require("dbdash.util.sandbox").guard(fn, env.timeout, env.cancel)
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
function M.lua_module(env, path, text)
  local name = vim.fn.fnamemodify(path, ":~:.")
  local chunk, err = load(text, "=" .. name, "t", M.lua_env(env))
  if not chunk then
    local l, rest = tostring(err):match(":(%d+): (.*)$")
    local e = errors.new("lua", "syntax error: " .. (rest or tostring(err)), tonumber(l))
    e.source = name
    error(e, 0)
  end
  local t = M.run_lua(env, chunk, name, name)
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
          lua_args[i] = M.to_lua(args[i])
        end
        local n = #args
        return M.from_lua(M.run_lua(call_env, function()
          return fn(unpack(lua_args, 1, n))
        end, name, name))
      end)
    else
      map.set(mod, k, M.from_lua(v))
    end
  end
  module_raw[mod] = t
  return mod
end

---{% lua %} ... {% endlua %}: run the code; its return value is output like {{ }}.
---@param line integer template line where the code starts
---@param vars_fn fun(): table the template variables visible here (set, for, macro args)
function M.lua_block(env, code, line, vars_fn)
  local name = env.source or "template"
  local vars = {}
  for k, v in pairs(vars_fn()) do
    vars[k] = M.to_lua(v)
  end
  local view = setmetatable({}, {
    __index = vars,
    __newindex = function(_, k)
      error(("vars is read-only (vars.%s)"):format(tostring(k)), 2)
    end,
  })
  -- Compiled for each run with its own environment: two renders may run the same block
  -- at once (each waiting inside it on a dbdash helper).
  local chunk, err =
    load(string.rep("\n", line - 1) .. code, "=" .. name, "t", M.lua_env(env, { vars = view }))
  if not chunk then
    local l, rest = tostring(err):match(":(%d+): (.*)$")
    error(errors.new("lua", "syntax error: " .. (rest or tostring(err)), tonumber(l) or line), 0)
  end
  local ret = M.run_lua(env, chunk, name)
  if ret == nil then
    return ""
  end
  return M.out(env, M.from_lua(ret))
end

-- Macros and imports ------------------------------------------------------------------------

Macro.__index = Macro
Macro.__call = function(self, args, kwargs, env)
  return M.markup(env, self.fn(args, kwargs, env)) -- like Jinja's Markup: not escaped again
end

---Wrap a compiled macro body as a callable value. Its attributes are those of Jinja's
---Macro: name, arguments, catch_varargs, catch_kwargs, caller.
function M.macro(name, fn, params, flags)
  flags = flags or {}
  return setmetatable({
    name = name,
    fn = fn,
    arguments = M.tuple(vim.list_extend({}, params or {})),
    catch_varargs = flags.catch_varargs == true,
    catch_kwargs = flags.catch_kwargs == true,
    caller = flags.caller == true,
  }, Macro)
end

function M.is_macro(v)
  return getmetatable(v) == Macro
end

---Check a macro call's arguments against its parameters: surplus positional arguments
---become varargs (or are an error), unknown keyword arguments kwargs (or an error), and a
---caller is only taken by macros that use it. Returns { varargs, kwargs, caller }.
function M.check_args(name, args, kwargs, params, flags)
  local info = {}
  if #args > #params then
    if not flags.catch_varargs then
      raise("type", "macro '%s' takes not more than %d argument(s)", name, #params)
    end
  end
  if flags.catch_varargs then
    local extra = {}
    for i = #params + 1, #args do
      extra[#extra + 1] = args[i]
    end
    info.varargs = M.tuple(extra)
  end
  local known = {}
  for i, p in ipairs(params) do
    known[p] = true
    if args[i] ~= nil and kwargs[p] ~= nil then
      raise("type", "macro '%s' got multiple values for argument '%s'", name, p)
    end
  end
  local extra_kw = map.new()
  for _, k in ipairs(M.kw_keys(kwargs)) do
    if k == "caller" and flags.caller then
      info.caller = kwargs[k]
    elseif not known[k] then
      if not flags.catch_kwargs then
        if k == "caller" then
          raise(
            "type",
            "macro '%s' was invoked with two values for the special caller argument. This is most likely a bug.",
            name
          )
        end
        raise("type", "macro '%s' takes no keyword argument '%s'", name, k)
      end
      map.set(extra_kw, k, kwargs[k])
    end
  end
  if flags.catch_kwargs then
    info.kwargs = extra_kw
  end
  if flags.caller and info.caller == nil then
    info.caller = M.undef("No caller defined")
  end
  return info
end

local module_names = setmetatable({}, { __mode = "k" })

---Run another template and return its top-level variables and macros as a mapping.
---Without `wctx` it sees the globals only (a dashboard's args and meta; cached per
---render); "with context" passes `wctx`, the caller's context and variables.
function M.import(env, target, wctx)
  check(target)
  if type(target) ~= "string" then
    raise("type", "import target must be a string, not %s", typename(target))
  end
  if not env.load_template then
    raise("value", "{%% import %%} needs a template loader (base directory)")
  end
  env._modules = env._modules or {}
  if env._modules[target] and not wctx then
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
    local mod = M.lua_module(env, path or target, text or "")
    env._importing[target] = nil
    module_names[mod] = target
    env._modules[target] = mod
    return mod
  end
  local L = { l = nil }
  local outer_source = env.source
  env.source = path or target -- Lua in the imported file reports its own name
  -- Imported templates see env.context (dashboards: args and meta), and with context the
  -- caller's variables too.
  local ok, out, exports = pcall(tpl.fn, wctx or env.context or {}, env, L)
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
    if e[2] ~= M.MISSING then
      map.set(mod, e[1], e[2])
    end
  end
  module_names[mod] = target
  if not wctx then
    env._modules[target] = mod
  end
  return mod
end

---A name from an imported module; missing names stay undefined until used (like Jinja).
function M.import_name(mod, name)
  local v = mod[name]
  if v == nil then
    return M.undef(
      ("the template '%s' does not export the requested name '%s'"):format(
        module_names[mod] or "?",
        name
      )
    )
  end
  return v
end

-- Include, extends and blocks ----------------------------------------------------------------

---Load template `name` (trust checked for dashboards). Returns nil for a missing file
---when `missing_ok`.
local function load_named(env, name, missing_ok)
  if type(name) ~= "string" then
    raise("type", "template name must be a string, not %s", typename(name))
  end
  if not env.load_template then
    raise("value", "loading templates needs a template loader (base directory)")
  end
  local ok, tpl, path, text = pcall(env.load_template, name)
  if not ok then
    if missing_ok and type(tpl) == "table" and tpl.not_found then
      return nil
    end
    error(tpl, 0)
  end
  if tpl.lua then
    raise("value", "'%s' is a Lua module: import it, it cannot be included or extended", name)
  end
  if env.check_file then
    env.check_file(path or name, text or "", "template")
  end
  return tpl, path or name
end

---Render a loaded template with `ctx` (and the block registry of a child), reporting
---errors at its own file and line.
local function run_template(env, tpl, path, ctx, reg)
  env._depth = (env._depth or 0) + 1
  if env._depth > 50 then
    env._depth = 0
    raise("value", "templates include or extend each other too deeply (a loop?)")
  end
  local L = { l = nil }
  local outer_source = env.source
  env.source = path -- Lua in the file reports its own name
  local ok, out = pcall(tpl.fn, ctx, env, L, reg)
  env.source = outer_source
  env._depth = env._depth - 1
  if not ok then
    if errors.is(out) then
      out.line = out.line or L.l
      out.source = out.source or path
    end
    error(out, 0)
  end
  return out
end

---{% include target %}: the output of another template (the first that exists of a list),
---with the caller's context and variables (`wctx`), or only the globals.
function M.include(env, target, ignore_missing, wctx)
  check(target)
  local names = is_list(target) and target or { target }
  for _, name in ipairs(names) do
    local tpl, path = load_named(env, check(name), ignore_missing or #names > 1)
    if tpl then
      return run_template(env, tpl, path, wctx or env.context or {}, nil)
    end
  end
  if ignore_missing then
    return ""
  end
  raise("value", "template not found: %s", table.concat(vim.tbl_map(M.str, names), ", "))
end

---The block registry of a render: block name -> implementations, the most derived first.
function M.blocks(reg)
  return { chains = reg and reg.chains or {}, required = reg and reg.required or {} }
end

---Register a template's blocks (a child's run first, so its blocks come first).
function M.add_blocks(reg, fns, required)
  for name, fn in pairs(fns) do
    reg.chains[name] = reg.chains[name] or {}
    table.insert(reg.chains[name], { fn = fn, required = required[name] })
  end
end

---{% extends target %}: remember the parent; the output so far (`cut` parts) is kept,
---the rest of this template only defines blocks.
function M.extends(_env, reg, target, cut)
  check(target)
  if reg.parent then
    raise("value", "extended multiple times")
  end
  reg.parent, reg.cut = target, cut
end

---Render implementation `i` of block `name`; super() renders the next one.
local function call_block(env, reg, name, i, bctx)
  local chain = reg.chains[name]
  local impl = chain and chain[i]
  if not impl then
    raise("undefined", "there is no parent block called '%s'.", name)
  end
  if impl.required and i == 1 then
    raise("value", "Required block '%s' not found", name)
  end
  local super = function()
    return M.markup(env, call_block(env, reg, name, i + 1, bctx))
  end
  return impl.fn(bctx, super)
end

---{% block name %}: the most derived implementation of the block (none after extends:
---the parent renders it).
function M.render_block(env, reg, name, bctx)
  if reg.parent then
    return ""
  end
  return call_block(env, reg, name, 1, bctx)
end

---The output of a template that extends `reg.parent`: its text before the extends tag,
---then the parent rendered with this template's blocks and top-level variables.
function M.render_parent(env, reg, ctx, top, o)
  local tpl, path = load_named(env, reg.parent, false)
  local before = table.concat(o, "", 1, reg.cut)
  return before .. run_template(env, tpl, path, M.layer(ctx, top), M.blocks(reg))
end

-- `self`: self.name() renders block `name`.
local SelfRef = {}
SelfRef.__index = SelfRef

function M.self_ref(env, reg, ctx)
  return setmetatable({ env = env, reg = reg, ctx = ctx }, SelfRef)
end

M.getattr_hook[SelfRef] = function(obj, name)
  if obj.reg.chains[name] then
    return function()
      return M.markup(obj.env, call_block(obj.env, obj.reg, name, 1, obj.ctx))
    end
  end
end

-- Collections ----------------------------------------------------------------------------

function M.dict(flat)
  local d = map.new()
  for i = 1, #flat, 2 do
    map.set(d, key_of(check(flat[i])), flat[i + 1])
  end
  return d
end

---Python slice bounds for a sequence of `n` items: start, stop, step (0-based indexes).
local function slice_bounds(n, start, stop, step)
  local function int(v, default)
    if v == nil or v == M.NONE then
      return default
    end
    local x, isf = num(check(v))
    if not x or isf then
      raise("type", "slice indices must be integers or None")
    end
    return x
  end
  step = int(step, 1)
  if step == 0 then
    raise("value", "slice step cannot be zero")
  end
  local lower, upper = 0, n
  if step < 0 then
    lower, upper = -1, n - 1
  end
  local function clamp(i, default)
    if i == nil then
      return default
    end
    if i < 0 then
      i = i + n
      return i < lower and lower or i
    end
    return i > upper and upper or i
  end
  return clamp(int(start, nil), step > 0 and lower or upper),
    clamp(int(stop, nil), step > 0 and upper or lower),
    step
end

---obj[start:stop:step] of a string (code points), list or tuple.
function M.slice(obj, start, stop, step)
  check(obj)
  local seq
  local str = as_str(obj)
  if str then
    seq = M.chars(str)
  elseif is_list(obj) then
    seq = obj
  else
    raise("type", "'%s' object is not subscriptable", typename(obj))
  end
  local a, b, c = slice_bounds(#seq, start, stop, step)
  local out = {}
  local i = a
  while (c > 0 and i < b) or (c < 0 and i > b) do
    out[#out + 1] = seq[i + 1]
    i = i + c
  end
  if str then
    return table.concat(out)
  elseif M.is_tuple(obj) then
    return M.tuple(out)
  end
  return out
end

---Items to iterate over in a for loop.
function M.iter(v)
  check(v)
  if map.is_map(v) then
    return map.keys(v)
  elseif is_list(v) then
    return v
  elseif type(v) == "string" then
    return M.chars(v)
  elseif getmetatable(v) == Safe then
    return M.chars(v.s)
  end
  raise("type", "'%s' object is not iterable", typename(v))
end

---Unpack an item into `n` loop/set targets.
function M.unpack(item, n)
  check(item)
  local seq = is_list(item) and item or (type(item) == "string" and M.chars(item)) or nil
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

function M.add(a, b)
  check(a)
  check(b)
  local x, fx = num(a)
  local y, fy = num(b)
  if x and y then
    return mknum(x + y, fx or fy)
  end
  local s, t = as_str(a), as_str(b)
  if s and t then
    return s .. t
  end
  if is_list(a) and is_list(b) and M.is_tuple(a) == M.is_tuple(b) then
    local out = {}
    vim.list_extend(out, a)
    vim.list_extend(out, b)
    return M.is_tuple(a) and M.tuple(out) or out
  end
  op_error("+", a, b)
end

function M.sub(a, b)
  local x, fx = num(check(a))
  local y, fy = num(check(b))
  if not (x and y) then
    op_error("-", a, b)
  end
  return mknum(x - y, fx or fy)
end

function M.mul(a, b)
  check(a)
  check(b)
  local x, fx = num(a)
  local y, fy = num(b)
  if x and y then
    return mknum(x * y, fx or fy)
  end
  local seq, n, nf = a, y, fy
  if x and not y then
    seq, n, nf = b, x, fx
  end
  if n and not nf then
    local s = as_str(seq)
    if s then
      return n > 0 and s:rep(n) or ""
    elseif is_list(seq) then
      local out = {}
      for _ = 1, n do
        vim.list_extend(out, seq)
      end
      return M.is_tuple(seq) and M.tuple(out) or out
    end
  end
  op_error("*", a, b)
end

function M.div(a, b)
  local x = num(check(a))
  local y = num(check(b))
  if not (x and y) then
    op_error("/", a, b)
  end
  if y == 0 then
    raise("value", "division by zero")
  end
  return M.float(x / y)
end

function M.floordiv(a, b)
  local x, fx = num(check(a))
  local y, fy = num(check(b))
  if not (x and y) then
    op_error("//", a, b)
  end
  if y == 0 then
    raise("value", "integer division or modulo by zero")
  end
  return mknum(math.floor(x / y), fx or fy)
end

function M.mod(a, b)
  check(a)
  check(b)
  local x, fx = num(a)
  local y, fy = num(b)
  if not (x and y) then
    local s = as_str(a)
    if s then
      -- printf-style formatting: 'x=%s' % value
      local out = M.percent(s, b)
      return M.is_safe(a) and M.safe(out) or out
    end
    op_error("%", a, b)
  end
  if y == 0 then
    raise("value", "integer division or modulo by zero")
  end
  return mknum(x - math.floor(x / y) * y, fx or fy)
end

function M.pow(a, b)
  local x, fx = num(check(a))
  local y, fy = num(check(b))
  if not (x and y) then
    op_error("** or pow()", a, b)
  end
  return mknum(x ^ y, fx or fy or y < 0)
end

function M.concat(a, b)
  return M.str(a) .. M.str(b)
end

function M.neg(a)
  local x, fx = num(check(a))
  if not x then
    raise("type", "bad operand type for unary -: '%s'", typename(a))
  end
  return mknum(-x, fx)
end

function M.pos(a)
  local x, fx = num(check(a))
  if not x then
    raise("type", "bad operand type for unary +: '%s'", typename(a))
  end
  return mknum(x, fx)
end

-- Comparison ------------------------------------------------------------------------------

function M.eq(a, b)
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
      if b[k] == nil or not M.eq(v, b[k]) then
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
    if #a ~= #b or M.is_tuple(a) ~= M.is_tuple(b) then
      return false
    end
    for i = 1, #a do
      if not M.eq(a[i], b[i]) then
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
      if not M.eq(a[i], b[i]) then
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

---Python's sorted(): stable, by `key(item)` (default: the item), raising on values that
---cannot be compared.
---@param key (fun(v: any): any)?
function M.sorted(seq, key, reverse)
  local items = {}
  for i, v in ipairs(seq) do
    items[i] = { v = v, k = key and key(v) or v, i = i }
  end
  table.sort(items, function(a, b)
    local x, y = a.k, b.k
    if reverse then
      x, y = y, x
    end
    if lt(x, y, "<") then
      return true
    elseif lt(y, x, "<") then
      return false
    end
    return a.i < b.i
  end)
  local out = {}
  for i, it in ipairs(items) do
    out[i] = it.v
  end
  return out
end

function M.contains(container, item)
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
    return container[key_of(item)] ~= nil
  elseif is_list(container) then
    for _, v in ipairs(container) do
      if M.eq(v, item) then
        return true
      end
    end
    return false
  end
  raise("type", "argument of type '%s' is not iterable", typename(container))
end

function M.cmp(op, a, b)
  check(a)
  check(b)
  if op == "==" then
    return M.eq(a, b)
  elseif op == "!=" then
    return not M.eq(a, b)
  elseif op == "<" then
    return lt(a, b, op)
  elseif op == ">" then
    return lt(b, a, op)
  elseif op == "<=" then
    return M.eq(a, b) or lt(a, b, op)
  elseif op == ">=" then
    return M.eq(a, b) or lt(b, a, op)
  elseif op == "in" then
    return M.contains(b, a)
  elseif op == "notin" then
    return not M.contains(b, a)
  end
  error("unknown comparison " .. op)
end

-- Filters and tests -----------------------------------------------------------------------

M.filters = {}
M.tests = {}

function M.filter(env, name, v, args, kwargs)
  local f = M.filters[name]
  if name ~= "default" and name ~= "d" and name ~= "items" then
    check(v) -- (default and items take an undefined value)
  end
  for i = 1, #args do
    check(args[i])
  end
  return f(env, v, args, kwargs)
end

function M.test(env, name, v, args)
  return M.tests[name](env, v, args)
end

return M
