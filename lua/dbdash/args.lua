-- Query arguments (:help dbdash-arguments): typed parsing of "key=value" input and precedence
-- merging.
--
-- Precedence (high to low): command line > edited in the dashboard > interactive input >
-- YAML default. Values only live for the session. Declared arguments without a value are
-- `none` in templates.
--
-- Text forms: list "a,b,c"; map "k:v,k2:v2"; boolean true/false/1/0/yes/no/on/off.
-- Commas and colons inside values are escaped with a backslash or quoted ('a,b' / "a:b").
local map = require("dbdash.util.map")

local M = {}

local function fail(msg, ...)
  error({ phase = "args", message = msg:format(...) }, 0)
end

---Split on unescaped, unquoted separator characters.
---@param s string
---@param seps string set of separator chars, e.g. ","
---@param max integer? maximum number of parts
---@param raw boolean? keep escapes and quotes in the parts (for nested splitting)
---@return string[] parts (unescaped and unquoted unless raw)
function M.split(s, seps, max, raw)
  local parts, cur, q = {}, {}, nil
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" and i < #s then
      cur[#cur + 1] = raw and s:sub(i, i + 1) or s:sub(i + 1, i + 1)
      i = i + 2
    elseif q then
      if c == q then
        q = nil
        if raw then
          cur[#cur + 1] = c
        end
      else
        cur[#cur + 1] = c
      end
      i = i + 1
    elseif c == "'" or c == '"' then
      q = c
      if raw then
        cur[#cur + 1] = c
      end
      i = i + 1
    elseif seps:find(c, 1, true) and (not max or #parts < max - 1) then
      parts[#parts + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  if q then
    fail("unterminated quote in %q", s)
  end
  parts[#parts + 1] = table.concat(cur)
  return parts
end

local function escape(s)
  return (tostring(s):gsub("[\\,:'\"]", "\\%0"))
end

local BOOL = {
  ["true"] = true,
  ["1"] = true,
  yes = true,
  on = true,
  y = true,
  ["false"] = false,
  ["0"] = false,
  no = false,
  off = false,
  n = false,
}

---Infer how list/map elements should be typed from the default value and choices.
local function element_kind(spec)
  local samples = {}
  local d = spec.default
  if map.is_map(d) then
    for _, v in map.pairs(d) do
      samples[#samples + 1] = v
    end
  elseif type(d) == "table" then
    for _, v in ipairs(d) do
      samples[#samples + 1] = v
    end
  end
  for _, v in ipairs(spec.choices or {}) do
    if type(v) ~= "table" then
      samples[#samples + 1] = v
    end
  end
  if #samples == 0 then
    return "string"
  end
  for _, v in ipairs(samples) do
    if type(v) ~= "number" then
      return "string"
    end
  end
  return "number"
end

local function scalar(kind, s, name)
  s = vim.trim(s)
  if kind == "number" then
    local n = tonumber(s)
    if not n then
      fail("argument '%s': %q is not a number", name, s)
    end
    return n
  end
  return s
end

---Parse a text value according to the argument's declared type.
---@param spec dbdash.ArgSpec
---@param s string
---@return any
function M.parse_value(spec, s)
  local t = spec.type
  if t == "string" then
    return s
  elseif t == "number" or t == "int" then
    local n = tonumber(vim.trim(s))
    if not n then
      fail("argument '%s': %q is not a number", spec.name, s)
    end
    if t == "int" and n ~= math.floor(n) then
      fail("argument '%s': %q is not an integer", spec.name, s)
    end
    return n
  elseif t == "boolean" then
    local b = BOOL[vim.trim(s):lower()]
    if b == nil then
      fail("argument '%s': %q is not a boolean (true/false/1/0/yes/no)", spec.name, s)
    end
    return b
  elseif t == "list" then
    local kind = element_kind(spec)
    local out = {}
    if vim.trim(s) == "" then
      return out
    end
    for i, part in ipairs(M.split(s, ",")) do
      out[i] = scalar(kind, part, spec.name)
    end
    return out
  elseif t == "map" then
    local kind = element_kind(spec)
    local out = map.new()
    if vim.trim(s) == "" then
      return out
    end
    for _, pair in ipairs(M.split(s, ",", nil, true)) do
      local kv = M.split(pair, ":", 2)
      if #kv ~= 2 then
        fail("argument '%s': %q is not key:value", spec.name, pair)
      end
      map.set(out, vim.trim(kv[1]), scalar(kind, kv[2], spec.name))
    end
    return out
  end
  fail("argument '%s': unknown type %s", spec.name, tostring(t))
end

---Text form of a value (inverse of parse_value), used for prompts and display.
---@param v any
---@return string
function M.format_value(v)
  if v == nil or v == vim.NIL then
    return ""
  elseif type(v) == "boolean" then
    return v and "true" or "false"
  elseif type(v) == "number" then
    return require("dbdash.util.number").numstr(v)
  elseif map.is_map(v) then
    local parts = {}
    for k, x in map.pairs(v) do
      parts[#parts + 1] = escape(k) .. ":" .. escape(M.format_value(x))
    end
    return table.concat(parts, ",")
  elseif type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = escape(M.format_value(x))
    end
    return table.concat(parts, ",")
  end
  return tostring(v)
end

---Find an argument spec by key: "name" for a shared argument, "<panel id>.name" for a
---panel's local one (a spec without a key is found by name).
function M.find(specs, key)
  for _, s in ipairs(specs) do
    if (s.key or s.name) == key then
      return s
    end
  end
end

---The arguments a command-line key sets: "<panel>.name" that panel's local argument;
---a bare "name" every argument of that name (the shared one and every local one).
---@return dbdash.ArgSpec[]
function M.match(specs, key)
  if key:find(".", 1, true) then
    for _, s in ipairs(specs) do
      if s.key == key or (s.panel_id and (s.panel_id .. "." .. s.name) == key) then
        return { s }
      end
    end
    return {}
  end
  local out = {}
  for _, s in ipairs(specs) do
    if s.name == key then
      out[#out + 1] = s
    end
  end
  return out
end

---Keys for completion: bare names (each once) and "<panel>.name" of local arguments.
function M.keys(specs)
  local out, seen = {}, {}
  for _, s in ipairs(specs) do
    for _, k in ipairs({ s.name, s.key }) do
      if k and not seen[k] then
        seen[k] = true
        out[#out + 1] = k
      end
    end
  end
  return out
end

---Parse command-line "name=value" / "<panel>.name=value" tokens into values by key. An
---explicit <panel>.name wins over a bare name, whatever the order.
---@param specs dbdash.ArgSpec[]
---@param tokens string[]
---@return table<string, any>
function M.parse_cli(specs, tokens)
  local out, given, explicit = {}, {}, {}
  for _, tok in ipairs(tokens) do
    local key, value = tok:match("^([%w_]+%.[%a_][%w_]*)=(.*)$")
    if not key then
      key, value = tok:match("^([%a_][%w_]*)=(.*)$")
    end
    if not key then
      fail("expected name=value, got %q", tok)
    end
    if given[key] then
      fail("argument '%s' given twice", key)
    end
    given[key] = true
    local targets = M.match(specs, key)
    if #targets == 0 then
      local panel, name = key:match("^(.-)%.(.*)$")
      if panel and M.find(specs, name) then
        fail(
          "panel '%s' has no local argument '%s' (use %s= for the shared one)",
          panel,
          name,
          name
        )
      end
      local keys = M.keys(specs)
      fail(
        "unknown argument '%s'%s",
        key,
        #keys > 0 and (" (known: " .. table.concat(keys, ", ") .. ")")
          or " (this config has no args)"
      )
    end
    local is_explicit = key:find(".", 1, true) ~= nil
    for _, spec in ipairs(targets) do
      local k = spec.key or spec.name
      if is_explicit or not explicit[k] then
        out[k] = M.parse_value(spec, value)
        explicit[k] = explicit[k] or is_explicit
      end
    end
  end
  return out
end

---@class dbdash.ArgState
---@field cli table<string, any>
---@field modified table<string, any>
---@field interactive table<string, any>

---@return dbdash.ArgState
function M.new_state(cli)
  return { cli = cli or {}, modified = {}, interactive = {} }
end

---Effective value of one argument, or nil when it has none.
function M.value(spec, state)
  local key = spec.key or spec.name
  for _, layer in ipairs({ state.cli, state.modified, state.interactive }) do
    if layer[key] ~= nil then
      return layer[key]
    end
  end
  return spec.default
end

---Template variables for the current state. Every declared argument is defined; one
---without any value is `none`.
---@param specs dbdash.ArgSpec[]
---@param state dbdash.ArgState
---@return table<string, any>
function M.resolve(specs, state)
  local vars = {}
  for _, spec in ipairs(specs) do
    local v = M.value(spec, state)
    vars[spec.name] = v == nil and vim.NIL or v
  end
  return vars
end

---Check a value set from Lua or a template for an argument's declared type (nil is none);
---returns an error message or nil. Lists and mappings are checked as tables.
function M.check_value(spec, v)
  if v == nil or v == vim.NIL then
    return nil
  end
  local t, ok = spec.type, true
  if t == "string" then
    ok = type(v) == "string"
  elseif t == "number" then
    ok = type(v) == "number"
  elseif t == "int" then
    ok = type(v) == "number" and v == math.floor(v)
  elseif t == "boolean" then
    ok = type(v) == "boolean"
  elseif t == "list" then
    ok = type(v) == "table" and (vim.islist(v) or next(v) == nil)
  elseif t == "map" then
    ok = type(v) == "table"
      and (require("dbdash.util.map").is_map(v) or not vim.islist(v) or next(v) == nil)
  end
  if not ok then
    local what = type(v) == "table" and (vim.islist(v) and "a list" or "a mapping")
      or ("a " .. type(v))
    return ("argument '%s' is %s, got %s"):format(
      spec.name,
      t == "int" and "an int" or ("a " .. t),
      what
    )
  end
end

---Template variables of one panel: its visible arguments (shared ones, each shadowed by
---a local one of the same name), by name.
---@param panel dbdash.PanelConfig
---@param state dbdash.ArgState
function M.resolve_panel(panel, state)
  return M.resolve(panel.visible_args, state)
end

---Required arguments that still have no value.
---@return dbdash.ArgSpec[]
function M.missing_required(specs, state)
  local out = {}
  for _, spec in ipairs(specs) do
    if spec.required and M.value(spec, state) == nil then
      out[#out + 1] = spec
    end
  end
  return out
end

---Set a value edited in the dashboard. It overrides interactive input and defaults,
---and also replaces a command-line value so the edit is visible.
---@param key string the spec's key
function M.set_modified(state, key, value)
  state.modified[key] = value
  state.cli[key] = nil
end

---Back to YAML defaults (drops command-line, edited and interactive values).
function M.reset(state)
  state.cli, state.modified, state.interactive = {}, {}, {}
end

return M
