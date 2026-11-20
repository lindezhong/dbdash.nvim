-- Load and validate a dashboard config file (design §4), applying defaults.
local yaml = require("dbdash.yaml")
local map = require("dbdash.util.map")

local M = {}

M.DB_TYPES = {
  sqlite = true,
  redis = true,
  postgres = true,
  mysql = true,
  cassandra = true,
  mongodb = true,
  mssql = true,
}
local SCHEME_ALIASES = { postgresql = "postgres", sqlserver = "mssql" }

M.CHART_TYPES = {
  table = true,
  line = true,
  area = true,
  bar = true,
  histogram = true,
  boxplot = true,
  heatmap = true,
  bubble = true,
  pie = true,
  scatter = true,
}

M.ARG_TYPES = { string = true, number = true, int = true, boolean = true, list = true, map = true }

local DEFAULTS = {
  interval = 30 * 1000,
  max_rows = 10000,
  countdown_format = "Next update: {time}s",
}

---@class dbdash.ArgSpec
---@field name string
---@field type "string"|"number"|"int"|"boolean"|"list"|"map"
---@field default any
---@field required boolean
---@field show boolean
---@field description string?
---@field choices any[]?

---@class dbdash.Config
---@field path string absolute path of the YAML file
---@field dir string directory containing the file
---@field database { type: string, url: string, options: table }
---@field query { sql: string, sql_line: integer, autoescape: boolean, max_rows: integer, timeout: integer?, args_show: boolean, args: dbdash.ArgSpec[] }
---@field show table show section, with interval (ms), title, show_countdown, countdown_format
---@field positions table<string, {line: integer, col: integer}>

local function nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---Parse a duration such as 30, "30s", "5m", "1h", "500ms" into milliseconds.
---@param v any
---@return integer? ms, string? err
function M.parse_duration(v)
  v = nn(v)
  if v == nil then
    return nil
  end
  if type(v) == "number" then
    if v < 0 then
      return nil, "duration must not be negative"
    end
    return math.floor(v * 1000)
  end
  if type(v) ~= "string" then
    return nil, "duration must be a number or a string like 30s"
  end
  local n, unit = vim.trim(v):lower():match("^(%d+%.?%d*)%s*(%a*)$")
  local mult = ({ [""] = 1000, ms = 1, s = 1000, m = 60000, h = 3600000 })[unit or ""]
  if not n or not mult then
    return nil, ("invalid duration %q (use s, m, h or ms)"):format(v)
  end
  return math.floor(tonumber(n) * mult)
end

---Infer the database type from a URL scheme.
---@param url string
---@return string?
function M.scheme_of(url)
  local s = url:match("^([%w+.-]+)://")
  if not s then
    return nil
  end
  s = s:lower():gsub("%+.*$", "") -- mongodb+srv -> mongodb
  return SCHEME_ALIASES[s] or s
end

local Ctx = {}
Ctx.__index = Ctx

function Ctx:fail(path, msg, ...)
  local p = self.pos[path]
  local where = p and (":%d:%d"):format(p.line, p.col) or ""
  error({ phase = "config", message = ("%s%s: %s"):format(self.file, where, msg:format(...)) }, 0)
end

function Ctx:expect(path, v, kind, optional)
  v = nn(v)
  if v == nil then
    if not optional then
      self:fail(path, "missing required field '%s'", path)
    end
    return nil
  end
  local ok
  if kind == "map" then
    ok = map.is_map(v)
  elseif kind == "list" then
    ok = map.is_list(v)
  elseif kind == "integer" then
    ok = type(v) == "number" and v == math.floor(v)
  else
    ok = type(v) == kind
  end
  if not ok then
    self:fail(path, "'%s' must be a %s", path, kind)
  end
  return v
end

function Ctx:duration(path, v)
  local ms, err = M.parse_duration(v)
  if err then
    self:fail(path, "'%s': %s", path, err)
  end
  return ms
end

function Ctx:database(db)
  db = self:expect("database", db, "map")
  local url = self:expect("database.url", db.url, "string")
  local scheme = M.scheme_of(url)
  local typ = nn(db.type)
  if typ ~= nil then
    typ = self:expect("database.type", typ, "string"):lower()
    typ = SCHEME_ALIASES[typ] or typ
  else
    typ = scheme
  end
  if typ == "oracle" or scheme == "oracle" then
    self:fail("database.url", "Oracle is not supported by dbdash.nvim")
  end
  if not typ then
    self:fail("database.url", "cannot infer database type from url %q; set database.type", url)
  end
  if not M.DB_TYPES[typ] then
    self:fail("database.type", "unsupported database type '%s'", typ)
  end
  return {
    type = typ,
    url = url,
    options = self:expect("database.options", db.options, "map", true) or map.new(),
  }
end

function Ctx:arg(a, i)
  local path = ("query.args[%d]"):format(i)
  a = self:expect(path, a, "map")
  if nn(a.key) ~= nil and nn(a.name) == nil then
    self:fail(path .. ".key", "'key:' is no longer supported in args; rename it to 'name:'")
  end
  local name = self:expect(path .. ".name", a.name, "string")
  if not name:match("^[%a_][%w_]*$") then
    self:fail(path .. ".name", "argument name '%s' must be an identifier", name)
  end
  local typ = self:expect(path .. ".type", a.type, "string", true) or "string"
  if not M.ARG_TYPES[typ] then
    self:fail(path .. ".type", "unknown argument type '%s'", typ)
  end
  local show = nn(a.show)
  local required = nn(a.required)
  return {
    name = name,
    type = typ,
    default = nn(a.default),
    required = required == true,
    show = show == nil or show == true,
    description = self:expect(path .. ".description", a.description, "string", true),
    choices = self:expect(path .. ".choices", a.choices, "list", true),
  }
end

function Ctx:query(q)
  q = self:expect("query", q, "map")
  local sql = self:expect("query.sql", q.sql, "string")
  local p = self.pos["query.sql"]
  local raw_args = self:expect("query.args", q.args, "list", true) or {}
  local args, seen = {}, {}
  for i, a in ipairs(raw_args) do
    local spec = self:arg(a, i)
    if seen[spec.name] then
      self:fail(("query.args[%d].name"):format(i), "duplicate argument '%s'", spec.name)
    end
    seen[spec.name] = true
    args[i] = spec
  end
  local autoescape = self:expect("query.autoescape", q.autoescape, "boolean", true)
  local args_show = self:expect("query.args_show", q.args_show, "boolean", true)
  return {
    sql = sql,
    sql_line = p and p.line or 1,
    autoescape = autoescape == true,
    max_rows = self:expect("query.max_rows", q.max_rows, "integer", true) or DEFAULTS.max_rows,
    timeout = self:duration("query.timeout", q.timeout),
    args_show = args_show == true,
    args = args,
  }
end

function Ctx:show(s, top_interval)
  s = self:expect("show", s, "map", true) or map.new()
  local typ = self:expect("show.type", s.type, "string", true) or "table"
  if not M.CHART_TYPES[typ] then
    self:fail("show.type", "unknown chart type '%s'", typ)
  end
  -- Keep every field (chart-specific ones are read by the renderers) and normalize the
  -- common ones in place. Unknown matplotlib-only fields are simply ignored downstream.
  local out = map.new()
  for k, v in map.pairs(s) do
    map.set(out, k, v)
  end
  out.type = typ
  out.title = self:expect("show.title", s.title, "string", true) or ""
  out.interval = self:duration("show.interval", nn(s.interval) or top_interval)
    or DEFAULTS.interval
  if out.interval < 1000 then
    self:fail("show.interval", "interval must be at least 1s")
  end
  out.show_countdown = self:expect("show.show_countdown", s.show_countdown, "boolean", true)
    == true
  out.countdown_format = self:expect("show.countdown_format", s.countdown_format, "string", true)
    or DEFAULTS.countdown_format
  out.style = self:expect("show.style", s.style, "map", true) or map.new()
  out.renderer = self:expect("show.renderer", s.renderer, "string", true)
  out.canvas = self:expect("show.canvas", s.canvas, "string", true)
  return out
end

---Validate parsed YAML data.
---@param data any
---@param file string used in error messages
---@param positions table<string, {line: integer, col: integer}>?
---@return dbdash.Config
function M.validate(data, file, positions)
  local ctx = setmetatable({ file = file, pos = positions or {} }, Ctx)
  if not map.is_map(data) then
    ctx:fail("", "config must be a mapping with database, query and show sections")
  end
  return {
    path = file,
    dir = vim.fs.dirname(file),
    database = ctx:database(data.database),
    query = ctx:query(data.query),
    show = ctx:show(data.show, nn(data.interval)),
    positions = ctx.pos,
  }
end

---Load a config file.
---@param path string
---@return dbdash.Config? cfg, {phase: string, message: string}? err
function M.load(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local data, pos = yaml.parse_file(path)
  if data == nil and pos then
    local where = pos.line > 0 and (":%d:%d"):format(pos.line, pos.col) or ""
    return nil, { phase = "config", message = ("%s%s: %s"):format(path, where, pos.message) }
  end
  local ok, res = pcall(M.validate, data, path, pos)
  if not ok then
    if type(res) == "table" and res.phase then
      return nil, res
    end
    error(res, 0)
  end
  return res
end

return M
