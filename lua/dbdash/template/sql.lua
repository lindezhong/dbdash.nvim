-- SQL filters and globals (design §6.3), implemented through the current driver's dialect.
-- Compatible with the legacy plugin except where it produced invalid SQL:
--   * sql_id quotes with the dialect's identifier quotes (legacy: always backticks)
--   * sql_in of an empty list gives "(NULL)" (legacy: bare "NULL")
--   * booleans become dialect literals (legacy: Python "True"/"False")
local R = require("dbdash.template.runtime")
local filters = require("dbdash.template.filters")
local errors = require("dbdash.template.errors")
local map = require("dbdash.util.map")

local M = {}

local NONE = R.NONE
local raise = errors.raise

local function dialect_of(env)
  return env.dialect or require("dbdash.db.dialect").get("sqlite")
end

local function plain(v)
  if R.is_safe(v) then
    return v.s
  end
  return v
end

---Call a dialect function, converting its errors into template errors.
local function call(fn, ...)
  local ok, res = pcall(fn, ...)
  if not ok then
    if type(res) == "table" and res.message then
      raise(res.kind or "value", res.message)
    end
    error(res, 0)
  end
  return res
end

---Escaped string content without the surrounding quotes.
local function escape_string(d, s)
  local q = call(d.quote_string, s)
  q = q:gsub("^N'", "'")
  return q:sub(2, -2)
end

local F = {}

F.sql_escape = function(env, v, args, kw)
  filters.bind("sql_escape", args, kw, {})
  v = plain(v)
  local d = dialect_of(env)
  if v == NONE then
    return d.null
  elseif type(v) == "string" then
    return escape_string(d, v)
  end
  return R.str(v)
end

F.sql_quote = function(env, v, args, kw)
  filters.bind("sql_quote", args, kw, {})
  v = plain(v)
  local d = dialect_of(env)
  if type(v) == "string" or v == NONE or type(v) == "boolean" or type(v) == "number" then
    return call(d.literal, v)
  end
  return R.str(v)
end

F.sql_in = function(env, v, args, kw)
  filters.bind("sql_in", args, kw, {})
  v = plain(v)
  local d = dialect_of(env)
  local items
  if R.is_list(v) then
    items = v
  elseif map.is_map(v) then
    items = map.keys(v)
  elseif v == NONE then
    items = {}
  else
    items = { v }
  end
  local plain_items = {}
  for i, x in ipairs(items) do
    plain_items[i] = plain(x)
  end
  return call(d.literal, plain_items)
end

F.sql_id = function(env, v, args, kw)
  filters.bind("sql_id", args, kw, {})
  v = plain(v)
  if type(v) ~= "string" then
    raise("value", "SQL identifier must be a string")
  end
  return call(dialect_of(env).quote_ident, v)
end

F.sql_limit = function(_, v, args, kw)
  filters.bind("sql_limit", args, kw, {})
  v = plain(v)
  if v == NONE then
    return ""
  end
  local n = type(v) == "number" and v or tonumber(type(v) == "string" and vim.trim(v) or nil)
  if not n or n ~= math.floor(n) then
    raise("value", "Invalid LIMIT value: %s", R.str(v))
  end
  if n <= 0 then
    raise("value", "Invalid LIMIT value: %s (must be positive)", R.str(v))
  end
  return R.numstr(n)
end

local G = {}

---sql_case(conditions, default=None): CASE WHEN <cond> THEN <value> ... ELSE <default> END.
---Conditions and values are inserted verbatim, like the legacy implementation.
G.sql_case = function(args, kw)
  local conditions, default = filters.bind("sql_case", args, kw, { { "conditions" }, { "default", NONE } })
  if not map.is_map(conditions) or next(conditions) == nil then
    if conditions ~= NONE and not map.is_map(conditions) and R.truthy(conditions) then
      raise("type", "sql_case() conditions must be a mapping")
    end
    return default ~= NONE and R.str(default) or "NULL"
  end
  local parts = { "CASE" }
  for cond, value in map.pairs(conditions) do
    parts[#parts + 1] = ("WHEN %s THEN %s"):format(R.str(cond), R.str(value))
  end
  if default ~= NONE then
    parts[#parts + 1] = "ELSE " .. R.str(default)
  end
  parts[#parts + 1] = "END"
  return table.concat(parts, " ")
end

---sql_concat(*args): strings become quoted literals, other values are inserted as text.
G.sql_concat = function(args, kw, env)
  if next(kw) then
    raise("type", "sql_concat() takes no keyword arguments")
  end
  local d = dialect_of(env)
  if #args == 0 then
    return "''"
  end
  local parts = {}
  for i, a in ipairs(args) do
    a = plain(a)
    parts[i] = type(a) == "string" and call(d.quote_string, a) or R.str(a)
  end
  if d.name == "sqlite" then
    return "(" .. table.concat(parts, " || ") .. ")"
  end
  return "CONCAT(" .. table.concat(parts, ", ") .. ")"
end

-- SQL filters and functions produce SQL, so their results are marked safe: autoescape
-- must not quote them again.
function M.install()
  for k, v in pairs(F) do
    R.filters[k] = function(...)
      return R.safe(v(...))
    end
  end
  for k, v in pairs(G) do
    R.globals[k] = function(...)
      return R.safe(v(...))
    end
  end
end

---Build a render env for a dialect.
---@param dialect dbdash.db.Dialect
---@param autoescape boolean?
---@param base_dir string? directory for {% import %} (the config file's directory)
---@return dbdash.template.Env
function M.env(dialect, autoescape, base_dir)
  return {
    dialect = dialect,
    autoescape = autoescape == true,
    escape = function(v)
      return call(dialect.literal, plain(v))
    end,
    load_template = base_dir and require("dbdash.template.loader").files(base_dir) or nil,
  }
end

return M
