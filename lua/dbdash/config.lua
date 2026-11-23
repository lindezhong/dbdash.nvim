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
  lua = true,
  http = true,
}
-- Alternative URL schemes and type names (keep in sync with the drivers' `schemes`).
local SCHEME_ALIASES = {
  postgresql = "postgres",
  sqlserver = "mssql",
  rediss = "redis",
  mariadb = "mysql",
  cql = "cassandra",
  sqlite3 = "sqlite",
  https = "http",
}
M.SCHEME_ALIASES = SCHEME_ALIASES

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
  stat = true,
  text = true,
}

M.ARG_TYPES = { string = true, number = true, int = true, boolean = true, list = true, map = true }

-- Values a config does not set come from setup({ defaults = ... }).
local DEFAULTS = setmetatable({}, {
  __index = function(_, k)
    local dbdash = require("dbdash")
    if k == "interval" then
      return dbdash.default_ms("interval")
    end
    return dbdash.options.defaults[k]
  end,
})

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
---@field query { sql: string, sql_line: integer, transform: string?, transform_line: integer, autoescape: boolean, max_rows: integer, timeout: integer?, args_show: boolean, args: dbdash.ArgSpec[] }
---@field show table show section, with interval (ms), title, show_countdown, countdown_format
---@field positions table<string, {line: integer, col: integer}>

local function nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---Parse a duration such as 30, "30s", "5m", "1h", "500ms" into milliseconds.
M.parse_duration = require("dbdash.util.duration").parse

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

function Ctx:database(db, prefix)
  prefix = prefix or ""
  db = self:expect(prefix .. "database", db, "map")
  local url = self:expect(prefix .. "database.url", db.url, "string")
  local _, env_err = require("dbdash.db.credentials").expand_env(url)
  if env_err then
    self:fail(prefix .. "database.url", "%s", env_err)
  end
  local password_cmd = nn(db.password_cmd)
  if password_cmd ~= nil then
    local ok = type(password_cmd) == "string" and password_cmd ~= ""
    if type(password_cmd) == "table" then
      ok = #password_cmd > 0
      for _, a in ipairs(password_cmd) do
        ok = ok and type(a) == "string"
      end
    end
    if not ok then
      self:fail(prefix .. "database.password_cmd", "password_cmd must be a command string or a list of strings")
    end
  end
  local scheme = M.scheme_of(url)
  local typ = nn(db.type)
  if typ ~= nil then
    typ = self:expect(prefix .. "database.type", typ, "string"):lower()
    typ = SCHEME_ALIASES[typ] or typ
  else
    typ = scheme
  end
  if typ == "oracle" or scheme == "oracle" then
    self:fail(prefix .. "database.url", "Oracle is not supported by dbdash.nvim")
  end
  if not typ then
    self:fail(prefix .. "database.url", "cannot infer database type from url %q; set database.type", url)
  end
  if not M.DB_TYPES[typ] then
    self:fail(prefix .. "database.type", "unsupported database type '%s'", typ)
  end
  return {
    type = typ,
    url = url,
    password_cmd = password_cmd,
    options = self:expect(prefix .. "database.options", db.options, "map", true) or map.new(),
  }
end

function Ctx:arg(a, i, base)
  local path = ("%s[%d]"):format(base or "query.args", i)
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

---Argument specs from a list at `base` (e.g. "query.args", "args").
function Ctx:args_list(list, base)
  local raw = self:expect(base, list, "list", true) or {}
  local out, seen = {}, {}
  for i, a in ipairs(raw) do
    local spec = self:arg(a, i, base)
    if seen[spec.name] then
      self:fail(("%s[%d].name"):format(base, i), "duplicate argument '%s'", spec.name)
    end
    seen[spec.name] = true
    spec.path = ("%s[%d].name"):format(base, i)
    out[i] = spec
  end
  return out
end

---@param db table the panel's database (http(s):// may leave out the request: a GET of the URL)
function Ctx:query(q, prefix, db)
  prefix = prefix or ""
  local optional = db and db.type == "http"
  if optional and nn(q) == nil then
    q = map.new()
  end
  q = self:expect(prefix .. "query", q, "map")
  local sql = self:expect(prefix .. "query.sql", q.sql, "string", optional) or ""
  local p = self.pos[prefix .. "query.sql"]
  local transform = self:expect(prefix .. "query.transform", q.transform, "string", true)
  local tp = self.pos[prefix .. "query.transform"]
  local autoescape = self:expect(prefix .. "query.autoescape", q.autoescape, "boolean", true)
  local args_show = self:expect(prefix .. "query.args_show", q.args_show, "boolean", true)
  return {
    sql = sql,
    sql_line = p and p.line or 1,
    transform = transform,
    transform_line = tp and tp.line or 1,
    autoescape = autoescape == true,
    max_rows = self:expect(prefix .. "query.max_rows", q.max_rows, "integer", true) or DEFAULTS.max_rows,
    timeout = self:duration(prefix .. "query.timeout", q.timeout),
    args_show = args_show == true,
    args = self:args_list(q.args, prefix .. "query.args"),
  }
end

---Merge argument lists by name; the same name must be declared identically.
function Ctx:merge_args(lists)
  local merged, by_name = {}, {}
  local function key(spec)
    return vim.inspect({ spec.type, spec.default, spec.required, spec.show, spec.description, spec.choices })
  end
  for _, list in ipairs(lists) do
    for _, spec in ipairs(list) do
      local prev = by_name[spec.name]
      if not prev then
        by_name[spec.name] = spec
        merged[#merged + 1] = spec
      elseif key(prev) ~= key(spec) then
        self:fail(spec.path, "argument '%s' is declared differently at %s", spec.name, prev.path)
      end
    end
  end
  -- `path` only serves error messages while merging.
  for _, list in ipairs(lists) do
    for _, spec in ipairs(list) do
      spec.path = nil
    end
  end
  return merged
end

function Ctx:show(s, top_interval, prefix)
  prefix = prefix or ""
  s = self:expect(prefix .. "show", s, "map", true) or map.new()
  local typ = self:expect(prefix .. "show.type", s.type, "string", true) or "table"
  if not M.CHART_TYPES[typ] then
    self:fail(prefix .. "show.type", "unknown chart type '%s'", typ)
  end
  -- Keep every field (chart-specific ones are read by the renderers) and normalize the
  -- common ones in place. Unknown matplotlib-only fields are simply ignored downstream.
  local out = map.new()
  for k, v in map.pairs(s) do
    map.set(out, k, v)
  end
  out.type = typ
  out.title = self:expect(prefix .. "show.title", s.title, "string", true) or ""
  out.own_interval = nn(s.interval) ~= nil
  out.interval = self:duration(prefix .. "show.interval", nn(s.interval) or top_interval)
    or DEFAULTS.interval
  if out.interval < 1000 then
    self:fail(prefix .. "show.interval", "interval must be at least 1s")
  end
  out.show_countdown = self:expect(prefix .. "show.show_countdown", s.show_countdown, "boolean", true)
    == true
  out.countdown_format = self:expect(prefix .. "show.countdown_format", s.countdown_format, "string", true)
    or DEFAULTS.countdown_format
  out.style = self:expect(prefix .. "show.style", s.style, "map", true) or map.new()
  out.renderer = self:expect(prefix .. "show.renderer", s.renderer, "string", true)
  out.canvas = self:expect(prefix .. "show.canvas", s.canvas, "string", true)
  local T = require("dbdash.render.thresholds")
  if nn(s.thresholds) ~= nil then
    local terr = T.check(s.thresholds)
    if terr then
      self:fail(prefix .. "show.thresholds", "%s", terr)
    end
  end
  for i, spec in ipairs(nn(s.column_list) or {}) do
    if type(spec) == "table" and nn(spec.thresholds) ~= nil then
      local terr = T.check(spec.thresholds)
      if terr then
        self:fail(("%sshow.column_list[%d].thresholds"):format(prefix, i - 1), "%s", terr)
      end
    end
  end
  out.span = self:expect(prefix .. "show.span", s.span, "integer", true) or 1
  if out.span < 1 then
    self:fail(prefix .. "show.span", "span must be at least 1")
  end
  return out
end

---@class dbdash.PanelConfig
---@field index integer
---@field database { type: string, url: string, options: table }
---@field query table
---@field show table

---Validate parsed YAML data.
---
---Single-chart configs (database/query/show) become one panel; `cfg.database`, `cfg.query`
---and `cfg.show` then refer to it. Multi-panel configs use `panels:` with a shared
---`database`, `interval` (default interval and forced refresh of every panel), `args`
---and `layout: {columns, gap}`.
---@param data any
---@param file string used in error messages
---@param positions table<string, {line: integer, col: integer}>?
---@return dbdash.Config
function M.validate(data, file, positions)
  local ctx = setmetatable({ file = file, pos = positions or {} }, Ctx)
  if not map.is_map(data) then
    ctx:fail("", "config must be a mapping with database, query and show sections")
  end
  local top_interval = ctx:duration("interval", nn(data.interval))
  local cfg = {
    path = file,
    dir = vim.fs.dirname(file),
    positions = ctx.pos,
    interval = top_interval,
  }
  local panels_raw = nn(data.panels)
  if panels_raw == nil then
    local database = ctx:database(data.database)
    local panel = {
      index = 1,
      database = database,
      query = ctx:query(data.query, nil, database),
      show = ctx:show(data.show, nn(data.interval)),
    }
    cfg.multi = false
    cfg.panels = { panel }
    cfg.database, cfg.query, cfg.show = panel.database, panel.query, panel.show
    cfg.args = ctx:merge_args({ ctx:args_list(data.args, "args"), panel.query.args })
    cfg.args_show = panel.query.args_show or nn(data.args_show) == true
    cfg.layout = { columns = 1, gap = 2 }
    return cfg
  end

  ctx:expect("panels", panels_raw, "list")
  if #panels_raw == 0 then
    ctx:fail("panels", "panels must not be empty")
  end
  if nn(data.query) ~= nil or nn(data.show) ~= nil then
    ctx:fail("panels", "use either query/show or panels, not both")
  end
  local shared_db = nn(data.database) ~= nil and ctx:database(data.database) or nil
  local lists = { ctx:args_list(data.args, "args") }
  local args_show = nn(data.args_show) == true
  cfg.multi = true
  cfg.panels = {}
  for i, raw in ipairs(panels_raw) do
    local prefix = ("panels[%d]."):format(i)
    ctx:expect(("panels[%d]"):format(i), raw, "map")
    local db = nn(raw.database) ~= nil and ctx:database(raw.database, prefix) or shared_db
    if not db then
      ctx:fail(prefix .. "database", "%sdatabase: missing database (set it at the top level or in the panel)", prefix)
    end
    local panel = {
      index = i,
      database = db,
      query = ctx:query(raw.query, prefix, db),
      show = ctx:show(raw.show, nn(data.interval), prefix),
    }
    lists[#lists + 1] = panel.query.args
    args_show = args_show or panel.query.args_show
    cfg.panels[i] = panel
  end
  cfg.args = ctx:merge_args(lists)
  cfg.args_show = args_show
  local layout = ctx:expect("layout", data.layout, "map", true) or map.new()
  cfg.layout = {
    columns = ctx:expect("layout.columns", layout.columns, "integer", true) or 1,
    gap = ctx:expect("layout.gap", layout.gap, "integer", true) or 2,
  }
  if cfg.layout.columns < 1 then
    ctx:fail("layout.columns", "columns must be at least 1")
  end
  cfg.database = shared_db or cfg.panels[1].database
  return cfg
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
