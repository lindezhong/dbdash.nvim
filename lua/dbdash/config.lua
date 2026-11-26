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
  -- push sources (:help dbdash-push)
  luastream = true,
  exec = true,
  webhook = true,
}

---Database types whose data is pushed (a stream) instead of queried on an interval.
M.PUSH_TYPES = { luastream = true, exec = true, webhook = true }
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
---@field database { type: string, url: string, options: table }? top-level database: the default of every panel
---@field panels dbdash.PanelConfig[]
---@field query { sql: string, sql_line: integer, transform: string?, transform_line: integer, autoescape: boolean, max_rows: integer, timeout: integer?, args_show: boolean, args: dbdash.ArgSpec[] }
---@field show table show section, with interval (ms), title, show_countdown, countdown_format
---@field positions table<string, {line: integer, col: integer}>
---@field grid boolean `panels:` (a grid, even of one panel)
---@field refresh_all integer? ms: the top-level interval, a refresh of every panel
---@field title string? the dashboard's title (top-level `title`)
---@field description string? the dashboard's description (a template, shown as Markdown)
---@field description_line integer
---@field show_countdown boolean countdown to the next refresh_all in the header
---@field countdown_format string
---@field shared_args dbdash.ArgSpec[] top-level args
---@field args dbdash.ArgSpec[] shared and local arguments, each with its `key`
---@field panels dbdash.PanelConfig[]

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
  local optional = db and (db.type == "http" or db.type == "webhook")
  if optional and nn(q) == nil then
    q = map.new()
  end
  q = self:expect(prefix .. "query", q, "map")
  if nn(q.args_show) ~= nil then
    self:fail(prefix .. "query.args_show", "'args_show' moved to show.args_show")
  end
  local sql = self:expect(prefix .. "query.sql", q.sql, "string", optional) or ""
  local p = self.pos[prefix .. "query.sql"]
  local transform = self:expect(prefix .. "query.transform", q.transform, "string", true)
  local tp = self.pos[prefix .. "query.transform"]
  local autoescape = self:expect(prefix .. "query.autoescape", q.autoescape, "boolean", true)
  return {
    sql = sql,
    sql_line = p and p.line or 1,
    transform = transform,
    transform_line = tp and tp.line or 1,
    autoescape = autoescape == true,
    max_rows = self:expect(prefix .. "query.max_rows", q.max_rows, "integer", true) or DEFAULTS.max_rows,
    timeout = self:duration(prefix .. "query.timeout", q.timeout),
    args = self:args_list(q.args, prefix .. "query.args"),
  }
end

function Ctx:show(s, top_interval, prefix)
  prefix = prefix or ""
  s = self:expect(prefix .. "show", s, "map", true) or map.new()
  local typ = self:expect(prefix .. "show.type", s.type, "string", true) or "table"
  if not M.CHART_TYPES[typ] then
    self:fail(prefix .. "show.type", "unknown chart type '%s'", typ)
  end
  -- Keep every field (chart-specific ones are read by the renderers) and normalize the
  -- common ones in place. Fields no renderer reads are simply ignored downstream.
  local out = map.new()
  for k, v in map.pairs(s) do
    map.set(out, k, v)
  end
  out.type = typ
  out.title = self:expect(prefix .. "show.title", s.title, "string", true) or ""
  out.description = self:expect(prefix .. "show.description", s.description, "string", true)
  out.description_line = (self.pos[prefix .. "show.description"] or {}).line or 1
  -- show.interval (the panel's, else the top-level show.interval), else the top-level
  -- interval, else setup's default.
  out.interval = self:duration(prefix .. "show.interval", nn(s.interval))
    or self:duration("interval", top_interval)
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
  local as = nn(s.args_show)
  if as ~= nil and type(as) ~= "boolean" then
    local ok = map.is_list(as)
    for _, n in ipairs(ok and as or {}) do
      ok = ok and type(n) == "string"
    end
    if not ok then
      self:fail(prefix .. "show.args_show", "args_show must be true, false or a list of argument names")
    end
  end
  out.args_show = as or false
  out.refresh_hidden = self:expect(prefix .. "show.refresh_hidden", s.refresh_hidden, "boolean", true) == true
  out.span = self:expect(prefix .. "show.span", s.span, "integer", true) or 1
  if out.span < 1 then
    self:fail(prefix .. "show.span", "span must be at least 1")
  end
  return out
end

---@class dbdash.PanelConfig
---@field index integer
---@field id string `id:` or the index; local arguments are given as <id>.<name>
---@field database { type: string, url: string, options: table }
---@field query table
---@field show table
---@field args dbdash.ArgSpec[] local arguments (query.args), only for this panel
---@field visible_args dbdash.ArgSpec[] what `args` holds in this panel: the shared arguments,
---  each shadowed by a local one of the same name
---@field shown_args dbdash.ArgSpec[] the arguments on this panel's args_show line
---@field follows_global boolean no timer of its own: the global refresh (cfg.refresh_all)
---  comes as often or more often than show.interval

-- Fields that describe one chart: with panels they cannot be top-level defaults.
local PANEL_ONLY = {
  query = { sql = true, transform = true, args = true },
  show = {
    type = true,
    title = true,
    description = true,
    span = true,
    column_list = true,
    x_label = true,
    y_label = true,
  },
}

local function panel_only(section, key)
  return PANEL_ONLY[section][key] or (section == "show" and type(key) == "string" and key:match("_columns?$") ~= nil)
end

---`b` over `a`: mappings merge key by key (recursively), anything else (lists too) replaces.
local function merge(a, b)
  if b == nil then
    return a
  end
  if not (map.is_map(a) and map.is_map(b)) then
    return b
  end
  local out = map.new()
  for k, v in map.pairs(a) do
    map.set(out, k, v)
  end
  for k, v in map.pairs(b) do
    map.set(out, k, merge(nn(a[k]), v))
  end
  return out
end

---Names of the arguments that template or Lua `text` reads: args.name, args["name"] and
---args['name']. `all` when it uses args as a whole (args.items(), `in args`, args passed on,
---args[expr]) so any argument may matter.
---@return table<string, boolean> names, boolean all
function M.arg_refs(text)
  local names, all = {}, false
  local init = 1
  while true do
    local s, e = text:find("%f[%w_]args%f[^%w_]", init)
    if not s then
      break
    end
    init = e + 1
    local before = text:sub(1, s - 1)
    local after = text:sub(e + 1)
    if not before:match("[%.:]%s*$") then -- not x.args
      local name = after:match("^%s*%.%s*([%a_][%w_]*)")
      local key = after:match("^%s*%[%s*'([%a_][%w_]*)'%s*%]") or after:match('^%s*%[%s*"([%a_][%w_]*)"%s*%]')
      if name then
        if after:match("^%s*%.%s*[%a_][%w_]*%s*%(") then -- args.items(), args.keys()
          all = true
        else
          names[name] = true
        end
      elseif key then
        names[key] = true
      elseif after:match("^%s*%[") or after:match("^%s*[,)]") or before:match("[(,]%s*$") or before:match("%f[%w_]in%s+$") then
        all = true
      end
    end
  end
  return names, all
end

---Validate parsed YAML data.
---
---One-chart configs (database/query/show at the top level) and multi-panel configs
---(`panels:`) are one model. Top-level bare fields are dashboard-wide: `interval` (a refresh
---of every panel, cfg.refresh_all), `args` (shared arguments), `layout`. The top-level
---`database`, `query` and `show` sections are the panels' defaults: without `panels:` they
---are the only panel; with `panels:` each panel is merged over them (the database is
---replaced as a whole) and fields describing one chart may not be top-level. Every panel
---is then validated the same way (Ctx:panel). `cfg.database`, `cfg.query` and `cfg.show`
---are the single panel's in one-chart configs.
---@param data any
---@param file string used in error messages
---@param positions table<string, {line: integer, col: integer}>?
---@return dbdash.Config
function M.validate(data, file, positions)
  local ctx = setmetatable({ file = file, pos = positions or {} }, Ctx)
  if not map.is_map(data) then
    ctx:fail("", "config must be a mapping with database, query and show sections")
  end
  if nn(data.args_show) ~= nil then
    ctx:fail("args_show", "'args_show' moved to show.args_show")
  end
  local cfg = {
    path = file,
    dir = vim.fs.dirname(file),
    positions = ctx.pos,
    refresh_all = ctx:duration("interval", nn(data.interval)),
  }
  if cfg.refresh_all and cfg.refresh_all < 1000 then
    ctx:fail("interval", "interval must be at least 1s")
  end
  -- Dashboard-wide: the title and the countdown to the global refresh.
  cfg.title = ctx:expect("title", data.title, "string", true)
  -- The dashboard's description: a template rendered as Markdown (:DbDashDescribe).
  cfg.description = ctx:expect("description", data.description, "string", true)
  cfg.description_line = (ctx.pos["description"] or {}).line or 1
  cfg.show_countdown = ctx:expect("show_countdown", data.show_countdown, "boolean", true) == true
  cfg.countdown_format = ctx:expect("countdown_format", data.countdown_format, "string", true)
    or DEFAULTS.countdown_format
  if cfg.show_countdown and not cfg.refresh_all then
    ctx:fail("show_countdown", "show_countdown counts down to the top-level interval; set interval")
  end
  local panels_raw = nn(data.panels)
  cfg.grid = panels_raw ~= nil
  local top_query = ctx:expect("query", data.query, "map", true)
  local top_show = ctx:expect("show", data.show, "map", true)
  if cfg.grid then
    ctx:expect("panels", panels_raw, "list")
    if #panels_raw == 0 then
      ctx:fail("panels", "panels must not be empty")
    end
    for section, m in pairs({ query = top_query, show = top_show }) do
      for k in map.pairs(m or map.new()) do
        if panel_only(section, k) then
          local hint = (section == "query" and k == "args") and "; shared arguments go in the top-level args"
            or ""
          ctx:fail(("%s.%s"):format(section, k), "'%s.%s' belongs to one panel; with panels, set it in each panel%s", section, k, hint)
        end
      end
    end
  else
    if nn(data.layout) ~= nil then
      ctx:fail("layout", "layout only applies with panels")
    end
    -- The top level is the only panel.
    panels_raw = { { query = top_query, show = top_show } }
    top_query, top_show = nil, nil
  end
  cfg.database = nn(data.database) ~= nil and ctx:database(data.database) or nil
  cfg.shared_args = ctx:args_list(data.args, "args")
  for _, spec in ipairs(cfg.shared_args) do
    spec.key = spec.name
  end
  cfg.panels = {}
  local ids = {}
  for i, raw in ipairs(panels_raw) do
    local prefix = cfg.grid and ("panels[%d]."):format(i) or ""
    if cfg.grid then
      ctx:expect(("panels[%d]"):format(i), raw, "map")
      -- Inherited fields report the line of the top-level default.
      for path, p in pairs(ctx.pos) do
        if (path:match("^query%.") or path:match("^show%.")) and ctx.pos[prefix .. path] == nil then
          ctx.pos[prefix .. path] = p
        end
      end
    end
    local id = tostring(i)
    if cfg.grid and nn(raw.id) ~= nil then
      id = ctx:expect(prefix .. "id", raw.id, "string")
      if not id:match("^[%a_][%w_]*$") then
        ctx:fail(prefix .. "id", "panel id '%s' must be an identifier", id)
      end
    end
    if ids[id] then
      ctx:fail(prefix .. "id", "duplicate panel id '%s' (panels[%d])", id, ids[id])
    end
    ids[id] = i
    local panel = ctx:panel({
      database = nn(raw.database),
      query = merge(top_query, nn(raw.query)),
      show = merge(top_show, nn(raw.show)),
    }, prefix, cfg, i, id, nn(data.interval))
    cfg.panels[i] = panel
  end
  cfg.args = vim.list_extend({}, cfg.shared_args)
  for _, p in ipairs(cfg.panels) do
    vim.list_extend(cfg.args, p.args)
  end
  -- Keys of the argument values: the name, or <panel id>.<name> for a local argument
  -- whose name another argument has too.
  local count = {}
  for _, spec in ipairs(cfg.args) do
    count[spec.name] = (count[spec.name] or 0) + 1
  end
  for _, spec in ipairs(cfg.args) do
    spec.path = nil
    spec.key = (spec.panel and count[spec.name] > 1) and (spec.panel_id .. "." .. spec.name) or spec.name
  end
  if not cfg.grid then
    local p = cfg.panels[1]
    cfg.query, cfg.show = p.query, p.show
    cfg.layout = { columns = 1, gap = 2 }
    return cfg
  end
  local layout = ctx:expect("layout", data.layout, "map", true) or map.new()
  cfg.layout = {
    columns = ctx:expect("layout.columns", layout.columns, "integer", true) or 1,
    gap = ctx:expect("layout.gap", layout.gap, "integer", true) or 2,
  }
  if cfg.layout.columns < 1 then
    ctx:fail("layout.columns", "columns must be at least 1")
  end
  return cfg
end

---Validate one panel: the same for the only panel of a one-chart config and for panels[i].
---@param raw { database: table?, query: table?, show: table? } after merging the defaults
---@param prefix string "" or "panels[i]."
---@param top_interval any the top-level interval (the last default of show.interval)
---@return dbdash.PanelConfig
function Ctx:panel(raw, prefix, cfg, index, id, top_interval)
  -- A panel's database replaces the default as a whole (no options or password_cmd of
  -- another server).
  local db = raw.database ~= nil and self:database(raw.database, prefix) or cfg.database
  if not db then
    self:fail(
      prefix .. "database",
      cfg.grid and "missing required field '%sdatabase' (set it in the panel or at the top level)"
        or "missing required field '%sdatabase'",
      prefix
    )
  end
  local query = self:query(raw.query, prefix, db)
  local show = self:show(raw.show, top_interval, prefix)
  if M.PUSH_TYPES[db.type] and show.refresh_hidden then
    -- A push source keeps receiving while hidden anyway; only drawing waits.
    self:fail(prefix .. "show.refresh_hidden", "refresh_hidden does not apply to %s:// (push sources keep receiving while hidden)", db.type)
  end
  local panel = {
    index = index,
    id = id,
    database = db,
    query = query,
    show = show,
    args = query.args,
    follows_global = cfg.refresh_all ~= nil and show.interval >= cfg.refresh_all,
  }
  for _, spec in ipairs(panel.args) do
    spec.panel, spec.panel_id = index, id
  end
  -- What `args` holds here: shared arguments, shadowed by local ones of the same name.
  local by_name, visible = {}, {}
  for _, spec in ipairs(cfg.shared_args) do
    by_name[spec.name] = spec
    visible[#visible + 1] = spec.name
  end
  for _, spec in ipairs(panel.args) do
    if not by_name[spec.name] then
      visible[#visible + 1] = spec.name
    end
    by_name[spec.name] = spec
  end
  panel.visible_args = {}
  for i, name in ipairs(visible) do
    panel.visible_args[i] = by_name[name]
  end
  -- The args_show line: the listed names, or (true) the arguments the panel reads.
  local as = show.args_show
  panel.shown_args = {}
  if type(as) == "table" then
    for i, name in ipairs(as) do
      local spec = by_name[name]
      if not spec then
        self:fail(("%sshow.args_show[%d]"):format(prefix, i - 1), "unknown argument '%s'", name)
      end
      panel.shown_args[#panel.shown_args + 1] = spec
    end
  elseif as == true then
    local used, all = M.used_args(cfg.dir, query)
    for _, spec in ipairs(panel.visible_args) do
      if spec.show and (all or used[spec.name] or spec.panel == index) then
        panel.shown_args[#panel.shown_args + 1] = spec
      end
    end
  end
  return panel
end

---Arguments a panel's query reads: query.sql, query.transform and the files they import.
---@return table<string, boolean> names, boolean all
function M.used_args(dir, query)
  local trust = require("dbdash.trust")
  local used, all = {}, false
  local seen = {}
  local function scan(text)
    local names, a = M.arg_refs(text)
    all = all or a
    for n in pairs(names) do
      used[n] = true
    end
  end
  for _, text in ipairs({ query.sql or "", query.transform or "" }) do
    scan(text)
    for _, f in ipairs(trust.reachable(dir, text, seen)) do
      scan(f.text)
    end
  end
  return used, all
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
