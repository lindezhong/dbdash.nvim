-- Load and validate a dashboard config file (ARCHITECTURE.md#startup-and-configuration), applying
-- defaults.
local yaml = require("dbdash.yaml")
local map = require("dbdash.util.map")

local M = {}

-- Values a config does not set come from setup({ defaults = ... }).
local DEFAULTS = setmetatable({}, {
  __index = function(_, k)
    local options = require("dbdash.options")
    if k == "interval" then
      return options.default_ms("interval")
    end
    return options.current.defaults[k]
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
---@field key string? the key of its value: the name, or <panel id>.<name>
---@field panel integer? the panel of a local argument
---@field panel_id string?
---@field path string? where it is written (while the config loads)

---@class dbdash.ConfigDatabase
---@field type string
---@field url string
---@field options table
---@field password_cmd (string|string[])?

---@class dbdash.ConfigQuery
---@field sql string
---@field sql_line integer
---@field transform string?
---@field transform_line integer
---@field autoescape boolean
---@field max_rows integer
---@field timeout integer?
---@field args_show boolean
---@field args dbdash.ArgSpec[]

---@class dbdash.Config
---@field path string absolute path of the YAML file
---@field dir string directory containing the file
---@field database dbdash.ConfigDatabase? top-level database: the default of every panel
---@field panels dbdash.PanelConfig[] the panels (one when the config has no `panels:`)
---@field positions table<string, {line: integer, col: integer}>
---@field refresh_all integer? ms: the top-level interval, a refresh of every panel
---@field title string? the dashboard's title (top-level `title`)
---@field description string? the dashboard's description (a template, shown as Markdown)
---@field description_line integer
---@field shared_args dbdash.ArgSpec[] top-level args
---@field args dbdash.ArgSpec[] shared and local arguments, each with its `key`
---@field style_rules dbdash.css.Rule[]? the dashboard's style sheet

local nn = require("dbdash.util.null").nn

---Parse a duration such as 30, "30s", "5m", "1h", "500ms" into milliseconds.
M.parse_duration = require("dbdash.util.duration").parse

---The reading of one config: its file and the line of every path (dbdash.config.Ctx).
---@class dbdash.config.Ctx
---@field file string
---@field pos table<string, { line: integer, col: integer }>
---@field listed boolean? the config lists its panels (`panels:`): where its fields are
local Ctx = {}
Ctx.__index = Ctx

---Run the rules other modules have for this part of the config (config/validators.lua),
---in the list's order; a rule may return the value normalized (a parsed style sheet, a
---database with its type), which the next ones get.
function Ctx:validate(field, value, path)
  for _, mod in ipairs(require("dbdash.config.validators")) do
    for _, v in ipairs(require(mod).validators or {}) do
      if v.field == field then
        local out = v.validate(value, self, path)
        if out ~= nil then
          value = out
        end
      end
    end
  end
  return value
end

---The document of the config as a dashboard would have it (dashboard/document.lua), for
---rules that need computed styles (the grid).
function Ctx:document(cfg)
  return require("dbdash.dashboard.document").from_config(cfg)
end

---Raise a config error at the line of `path` (or of its nearest parent with one). It never
---returns (`return ctx:fail(...)` and `x or ctx:fail(...)` keep their code's types).
---@return any
function Ctx:fail(path, msg, ...)
  -- Keys inside a flow mapping ({ a: 1 }) have no position: use the nearest parent's.
  local p, at = self.pos[path], path
  while not p do
    local parent = at:gsub("%[%d+%]$", "", 1)
    if parent == at then
      parent = at:gsub("%.[^.%[]*$", "", 1)
    end
    if parent == at then
      break
    end
    at = parent
    p = self.pos[at]
  end
  local where = p and (":%d:%d"):format(p.line, p.col) or ""
  require("dbdash.util.error").raise(
    "config",
    ("%s%s: %s"):format(self.file, where, msg:format(...))
  )
end

---The value at `path` when it is a `kind` ("map", "list", "integer" or a Lua type); nil
---when it is missing and optional, else an error.
---@param kind string
---@param optional boolean?
---@return any
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

---A database: the URL, type, options and password_cmd as written; its rules (the driver,
---the URL, the options) are the data layer's (db.validators), which gives the type.
function Ctx:database(db, prefix)
  local path = (prefix or "") .. "database"
  db = self:expect(path, db, "map")
  local typ = self:expect(path .. ".type", db.type, "string", true)
  return self:validate("database", {
    type = typ,
    url = self:expect(path .. ".url", db.url, "string"),
    password_cmd = nn(db.password_cmd),
    options = self:expect(path .. ".options", db.options, "map", true) or map.new(),
  }, path)
end

function Ctx:arg(a, i, base)
  local path = ("%s[%d]"):format(base or "query.args", i)
  a = self:expect(path, a, "map")
  if nn(a.key) ~= nil and nn(a.name) == nil then
    self:fail(path .. ".key", "'key:' is no longer supported in args; rename it to 'name:'")
  end
  local show = nn(a.show)
  local required = nn(a.required)
  return self:validate("arg", {
    name = self:expect(path .. ".name", a.name, "string"),
    type = self:expect(path .. ".type", a.type, "string", true) or "string",
    default = nn(a.default),
    required = required == true,
    show = show == nil or show == true,
    description = self:expect(path .. ".description", a.description, "string", true),
    choices = self:expect(path .. ".choices", a.choices, "list", true),
  }, path)
end

---Argument specs from a list at `base` (e.g. "query.args", "args").
function Ctx:args_list(list, base)
  local raw = self:expect(base, list, "list", true) or {}
  local out = {}
  for i, a in ipairs(raw) do
    local spec = self:arg(a, i, base)
    spec.path = ("%s[%d].name"):format(base, i)
    out[i] = spec
  end
  return self:validate("args", out, base)
end

---@param db table the panel's database (webhook:// has no request; http(s):// needs its
---curl command, `curl` alone being a GET of the URL)
function Ctx:query(q, prefix, db)
  prefix = prefix or ""
  local optional = db and require("dbdash.db").driver(db.type).query_optional
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
    max_rows = self:expect(prefix .. "query.max_rows", q.max_rows, "integer", true)
      or DEFAULTS.max_rows,
    timeout = self:duration(prefix .. "query.timeout", q.timeout),
    args = self:args_list(q.args, prefix .. "query.args"),
  }
end

function Ctx:show(s, top_interval, prefix)
  prefix = prefix or ""
  s = self:expect(prefix .. "show", s, "map", true) or map.new()
  local typ = self:expect(prefix .. "show.type", s.type, "string", true) or "table"
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
  if nn(s.interval) == nil and top_interval ~= nil then
    -- the top-level interval's line for the panel's
    self.pos[prefix .. "show.interval"] = self.pos["interval"]
  end
  for k in pairs(M.MOVED) do
    local field = k:match("^show%.(.+)$")
    if field and nn(s[field]) ~= nil then
      self:moved(prefix .. k)
    end
  end
  for _, axis in ipairs({ "x_axis", "y_axis" }) do
    local a = nn((nn(s.axes) or {})[axis])
    if a and nn(a.grid) ~= nil then
      self:fail(
        ("%sshow.axes.%s.grid"):format(prefix, axis),
        'grid lines are appearance: style: "grid.%s" { display: block }',
        axis:sub(1, 1)
      )
    end
  end
  local as = nn(s.args_show)
  if as ~= nil and type(as) ~= "boolean" then
    local ok = map.is_list(as)
    for _, n in ipairs(ok and as or {}) do
      ok = ok and type(n) == "string"
    end
    if not ok then
      self:fail(
        prefix .. "show.args_show",
        "args_show must be true, false or a list of argument names"
      )
    end
  end
  out.args_show = as or false
  out.refresh_hidden = self:expect(
    prefix .. "show.refresh_hidden",
    s.refresh_hidden,
    "boolean",
    true
  ) == true
  return self:validate("show", out, prefix .. "show")
end

---@class dbdash.PanelConfig
---@field index integer
---@field id string `id:` or the index; local arguments are given as <id>.<name>
---@field database { type: string, url: string, options: table, password_cmd: (string|string[])? }
---@field query dbdash.ConfigQuery
---@field show table
---@field args dbdash.ArgSpec[] local arguments (query.args), only for this panel
---@field visible_args dbdash.ArgSpec[] what `args` holds in this panel: the shared arguments,
---  each shadowed by a local one of the same name
---@field shown_args dbdash.ArgSpec[] the arguments on this panel's args_show line
---@field follows_global boolean no timer of its own: the global refresh (cfg.refresh_all)
---  comes as often or more often than show.interval
---@field style_rules dbdash.css.Rule[]? the panel's style sheet (inline, scoped)

-- Appearance moved into style sheets (:help dbdash-css): where each old field went.
M.MOVED = {
  ["layout"] = "style: dashboard { grid-template-columns, grid-template-rows, grid-template-areas, column-gap, row-gap }",
  ["show_countdown"] = "style: header countdown { display: block }",
  ["countdown_format"] = 'style: countdown { content: "Next update: {time}s" }',
  ["show.style"] = "style (a style sheet: selector -> properties; per panel: panels[].style)",
  ["show.span"] = 'style: panel { grid-column: "span N" }',
  ["show.area"] = "style: panel { grid-area: name }",
  ["show.row"] = "style: panel { grid-row: N }",
  ["show.column"] = "style: panel { grid-column: N }",
  ["show.row_span"] = 'style: panel { grid-row: "N / span M" }',
  ["show.height"] = "style: plot { height: N }",
  ["show.min_height"] = "style: plot { min-height: N }",
  ["show.width"] = "style: chart { max-width: N }",
  ["show.renderer"] = "style: chart { renderer: name }",
  ["show.canvas"] = "style: chart { canvas: name }",
  ["show.colors"] = 'style: "series.<name>" or "series:nth-child(N)" { color }',
  ["show.palette"] = "style: chart { palette: name }",
  ["show.legend"] = "style: legend { display: none } / legend { position: bottom }",
  ["show.line_style"] = "style: series { curve, fill }, point { display, content }; show.span_gaps",
  ["show.show_countdown"] = "style: countdown { display: block } (in the panel's style)",
  ["show.countdown_format"] = 'style: countdown { content: "..." }',
  ["show.color_mode"] = 'style: "value.<class>" { background-color } (thresholds give classes)',
  ["show.text_size"] = "style: value { font-size: normal }",
  ["show.delta"] = "style: delta { display: none }",
  ["show.sparkline"] = "style: sparkline { display: none }",
}

---Report a field that moved into style sheets.
function Ctx:moved(path)
  self:fail(
    path,
    "'%s' is appearance and moved to %s",
    path,
    M.MOVED[path:gsub("^panels%[%d+%]%.", "")]
  )
end

---A style sheet (selector -> properties) as written; css.validators parses it (the rules
---in the order written). `scope`: "author" (the top level) or "inline" (a panel).
---@return dbdash.css.Rule[]?
function Ctx:style(raw, path)
  local m = self:expect(path, raw, "map", true)
  if not m then
    return nil
  end
  return self:validate("style", m, path)
end

-- Fields that describe one chart: with panels they cannot be top-level defaults.
local PANEL_ONLY = {
  query = { sql = true, transform = true, args = true },
  show = {
    type = true,
    title = true,
    subtitle = true,
    description = true,
    column_list = true,
    x_label = true,
    y_label = true,
  },
}

local function panel_only(section, key)
  return PANEL_ONLY[section][key]
    or (section == "show" and type(key) == "string" and key:match("_columns?$") ~= nil)
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
      local key = after:match("^%s*%[%s*'([%a_][%w_]*)'%s*%]")
        or after:match('^%s*%[%s*"([%a_][%w_]*)"%s*%]')
      if name then
        if after:match("^%s*%.%s*[%a_][%w_]*%s*%(") then -- args.items(), args.keys()
          all = true
        else
          names[name] = true
        end
      elseif key then
        names[key] = true
      elseif
        after:match("^%s*%[")
        or after:match("^%s*[,)]")
        or before:match("[(,]%s*$")
        or before:match("%f[%w_]in%s+$")
      then
        all = true
      end
    end
  end
  return names, all
end

---Validate parsed YAML data.
---
---With panels, the top-level query and show are defaults: fields of one chart are not.
function Ctx:check_defaults(top_query, top_show)
  for section, m in pairs({ query = top_query, show = top_show }) do
    for k in map.pairs(m or map.new()) do
      if panel_only(section, k) then
        local hint = (section == "query" and k == "args")
            and "; shared arguments go in the top-level args"
          or ""
        self:fail(
          ("%s.%s"):format(section, k),
          "'%s.%s' belongs to one panel; with panels, set it in each panel%s",
          section,
          k,
          hint
        )
      end
    end
  end
end

---Panel i's id (`id:`, else its index), unique.
function Ctx:panel_id(raw, i, prefix, ids)
  local id = tostring(i)
  if self.listed and nn(raw.id) ~= nil then
    id = self:expect(prefix .. "id", raw.id, "string")
    if not id:match("^[%a_][%w_]*$") then
      self:fail(prefix .. "id", "panel id '%s' must be an identifier", id)
    end
  end
  if ids[id] then
    self:fail(prefix .. "id", "duplicate panel id '%s' (panels[%d])", id, ids[id])
  end
  ids[id] = i
  return id
end

---The panels: each one's raw fields over the top-level defaults.
function Ctx:panels(cfg, panels_raw, top_query, top_show, top_interval)
  local ids = {}
  for i, raw in ipairs(panels_raw) do
    local prefix = self.listed and ("panels[%d]."):format(i) or ""
    if self.listed then
      self:expect(("panels[%d]"):format(i), raw, "map")
      -- Inherited fields report the line of the top-level default.
      for path, p in pairs(self.pos) do
        if
          (path:match("^query%.") or path:match("^show%.")) and self.pos[prefix .. path] == nil
        then
          self.pos[prefix .. path] = p
        end
      end
    end
    local id = self:panel_id(raw, i, prefix, ids)
    local panel = self:panel({
      database = nn(raw.database),
      query = merge(top_query, nn(raw.query)),
      show = merge(top_show, nn(raw.show)),
    }, prefix, cfg, i, id, top_interval)
    panel.style_rules = self.listed and self:style(raw.style, prefix .. "style") or nil
    cfg.panels[i] = panel
  end
end

---Every argument (shared, then each panel's) with the key of its value: the name, or
---<panel id>.<name> for a local argument whose name another argument has too.
local function argument_keys(cfg)
  cfg.args = vim.list_extend({}, cfg.shared_args)
  for _, p in ipairs(cfg.panels) do
    vim.list_extend(cfg.args, p.args)
  end
  local count = {}
  for _, spec in ipairs(cfg.args) do
    count[spec.name] = (count[spec.name] or 0) + 1
  end
  for _, spec in ipairs(cfg.args) do
    spec.path = nil
    spec.key = (spec.panel and count[spec.name] > 1) and (spec.panel_id .. "." .. spec.name)
      or spec.name
  end
end

---The dashboard-wide fields: interval, title, description, the style sheet.
function Ctx:dashboard_fields(cfg, data)
  cfg.refresh_all = self:duration("interval", nn(data.interval))
  cfg.title = self:expect("title", data.title, "string", true)
  -- The dashboard's description: a template rendered as Markdown (:DbDashDescribe).
  cfg.description = self:expect("description", data.description, "string", true)
  cfg.description_line = (self.pos["description"] or {}).line or 1
  for _, k in ipairs({ "layout", "show_countdown", "countdown_format" }) do
    if nn(data[k]) ~= nil then
      self:moved(k)
    end
  end
  -- the dashboard's style sheet (author origin); panels have their own (inline, scoped)
  cfg.style_rules = self:style(data.style, "style")
end

---A dashboard is a list of panels (cfg.panels); a config without `panels:` writes its
---only panel at the top level. Top-level bare fields are dashboard-wide: `interval` (a
---refresh of every panel, cfg.refresh_all), `args` (shared arguments), `style`. The
---top-level `database`, `query` and `show` sections are the panels' defaults: without
---`panels:` they are the only panel; with `panels:` each panel is merged over them (the
---database is replaced as a whole) and fields describing one chart may not be top-level.
---Every panel is then validated the same way (Ctx:panel).
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
  local cfg = { path = file, dir = vim.fs.dirname(file), positions = ctx.pos, panels = {} }
  ctx:dashboard_fields(cfg, data)
  -- `panels:` lists the panels; without it the top level is the only panel (the same
  -- dashboard, written shorter): only where things are written differs (ctx.listed)
  local panels_raw = nn(data.panels)
  ctx.listed = panels_raw ~= nil
  local top_query = ctx:expect("query", data.query, "map", true)
  local top_show = ctx:expect("show", data.show, "map", true)
  if ctx.listed then
    ctx:expect("panels", panels_raw, "list")
    if #panels_raw == 0 then
      ctx:fail("panels", "panels must not be empty")
    end
    ctx:check_defaults(top_query, top_show)
  else
    -- The top level is the only panel.
    panels_raw = { { query = top_query, show = top_show } }
    top_query, top_show = nil, nil
  end
  cfg.database = nn(data.database) ~= nil and ctx:database(data.database) or nil
  cfg.shared_args = ctx:args_list(data.args, "args")
  for _, spec in ipairs(cfg.shared_args) do
    spec.key = spec.name
  end
  ctx:panels(cfg, panels_raw, top_query, top_show, nn(data.interval))
  argument_keys(cfg)
  return ctx:validate("dashboard", cfg, "")
end

---@class dbdash.LayoutConfig
---@field columns dbdash.layout.Track[]
---@field rows dbdash.layout.Track[] declared rows
---@field auto_row dbdash.layout.Track rows past the declared ones
---@field gap integer
---@field row_gap integer
---@field places dbdash.layout.Place[] where each panel goes

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
      self.listed
          and "missing required field '%sdatabase' (set it in the panel or at the top level)"
        or "missing required field '%sdatabase'",
      prefix
    )
  end
  local query = self:query(raw.query, prefix, db)
  local show = self:show(raw.show, top_interval, prefix)
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
  return self:validate("panel", panel, prefix)
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
    local e = res ---@type any (the error)
    if type(e) == "table" and e.phase then
      return nil, res
    end
    error(res, 0)
  end
  return res
end

return M
