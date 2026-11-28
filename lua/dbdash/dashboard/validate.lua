-- [dashboard] (config/types.lua): what every dashboard and every panel has: the top-level
-- title, description and interval (a refresh of every panel); each panel's query (sql,
-- transform, autoescape, max_rows, timeout; a driver may leave sql out) and its show's
-- common fields (title, description, interval, args_show, refresh_hidden); fields of one
-- chart are not top-level defaults when there are panels; fields that moved into style
-- sheets say where. Also the intervals (at least a second) and refresh_hidden (not for a
-- source that sends data).
local map = require("dbdash.util.map")
local nn = require("dbdash.util.null").nn

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

-- Appearance moved into style sheets (:help dbdash-css): where each old field went.
local MOVED = {
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
local function moved(ctx, path)
  ctx:fail(
    path,
    "'%s' is appearance and moved to %s",
    path,
    MOVED[path:gsub("^panels%[%d+%]%.", "")]
  )
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

---With panels, the top-level query and show are defaults: fields of one chart are not.
local function check_defaults(ctx, top_query, top_show)
  for section, m in pairs({ query = top_query, show = top_show }) do
    for k in map.pairs(m or map.new()) do
      if panel_only(section, k) then
        local hint = (section == "query" and k == "args")
            and "; shared arguments go in the top-level args"
          or ""
        ctx:fail(
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

---The dashboard-wide fields: interval, title, description.
local function dashboard_fields(ctx, cfg, data)
  if nn(data.args_show) ~= nil then
    ctx:fail("args_show", "'args_show' moved to show.args_show")
  end
  cfg.refresh_all = ctx:duration("interval", nn(data.interval))
  if cfg.refresh_all and cfg.refresh_all < 1000 then
    ctx:fail("interval", "interval must be at least 1s")
  end
  cfg.title = ctx:expect("title", data.title, "string", true)
  -- The dashboard's description: a template rendered as Markdown (:DbDashDescribe).
  cfg.description = ctx:expect("description", data.description, "string", true)
  cfg.description_line = (ctx.pos["description"] or {}).line or 1
  for _, k in ipairs({ "layout", "show_countdown", "countdown_format" }) do
    if nn(data[k]) ~= nil then
      moved(ctx, k)
    end
  end
end

---A panel's query: what the driver runs (webhook:// has no request; http(s):// needs its
---curl command, `curl` alone being a GET of the URL).
---@return dbdash.ConfigQuery
local function query(ctx, p)
  local prefix = p.prefix
  local optional = require("dbdash.db").driver(p.database.type).query_optional
  local q = p.raw.query
  if optional and nn(q) == nil then
    q = map.new()
  end
  q = ctx:expect(prefix .. "query", q, "map")
  if nn(q.args_show) ~= nil then
    ctx:fail(prefix .. "query.args_show", "'args_show' moved to show.args_show")
  end
  local sql = ctx:expect(prefix .. "query.sql", q.sql, "string", optional) or ""
  local sp = ctx.pos[prefix .. "query.sql"]
  local transform = ctx:expect(prefix .. "query.transform", q.transform, "string", true)
  local tp = ctx.pos[prefix .. "query.transform"]
  local autoescape = ctx:expect(prefix .. "query.autoescape", q.autoescape, "boolean", true)
  return {
    sql = sql,
    sql_line = sp and sp.line or 1,
    transform = transform,
    transform_line = tp and tp.line or 1,
    autoescape = autoescape == true,
    max_rows = ctx:expect(prefix .. "query.max_rows", q.max_rows, "integer", true)
      or DEFAULTS.max_rows,
    timeout = ctx:duration(prefix .. "query.timeout", q.timeout),
    args = p.args, -- its own arguments ([args])
  }
end

---A panel's show: every field kept (a chart type reads its own), the common ones
---normalized in place.
local function show(ctx, s, top_interval, prefix)
  s = ctx:expect(prefix .. "show", s, "map", true) or map.new()
  local out = map.new()
  for k, v in map.pairs(s) do
    map.set(out, k, v)
  end
  out.title = ctx:expect(prefix .. "show.title", s.title, "string", true) or ""
  out.description = ctx:expect(prefix .. "show.description", s.description, "string", true)
  out.description_line = (ctx.pos[prefix .. "show.description"] or {}).line or 1
  -- show.interval (the panel's, else the top-level show.interval), else the top-level
  -- interval, else setup's default.
  out.interval = ctx:duration(prefix .. "show.interval", nn(s.interval))
    or ctx:duration("interval", top_interval)
    or DEFAULTS.interval
  if nn(s.interval) == nil and top_interval ~= nil then
    -- the top-level interval's line for the panel's
    ctx.pos[prefix .. "show.interval"] = ctx.pos["interval"]
  end
  if out.interval < 1000 then
    ctx:fail(prefix .. "show.interval", "interval must be at least 1s")
  end
  for k in pairs(MOVED) do
    local field = k:match("^show%.(.+)$")
    if field and nn(s[field]) ~= nil then
      moved(ctx, prefix .. k)
    end
  end
  for _, axis in ipairs({ "x_axis", "y_axis" }) do
    local a = nn((nn(s.axes) or {})[axis])
    if a and nn(a.grid) ~= nil then
      ctx:fail(
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
      ctx:fail(
        prefix .. "show.args_show",
        "args_show must be true, false or a list of argument names"
      )
    end
  end
  out.args_show = as or false
  out.refresh_hidden = ctx:expect(
    prefix .. "show.refresh_hidden",
    s.refresh_hidden,
    "boolean",
    true
  ) == true
  return out
end

---Arguments a panel's query reads: query.sql, query.transform and the files they import.
---@return table<string, boolean> names, boolean all
local function used_args(dir, q)
  local trust = require("dbdash.trust")
  local arg_refs = require("dbdash.args").arg_refs
  local used, all = {}, false
  local seen = {}
  local function scan(text)
    local names, a = arg_refs(text)
    all = all or a
    for n in pairs(names) do
      used[n] = true
    end
  end
  for _, text in ipairs({ q.sql or "", q.transform or "" }) do
    scan(text)
    for _, f in ipairs(trust.reachable(dir, text, seen)) do
      scan(f.text)
    end
  end
  return used, all
end

---The args_show line: the listed names, or (true) the arguments the panel reads.
local function shown_args(ctx, cfg, p)
  local by_name = {}
  for _, s in ipairs(p.visible_args) do
    by_name[s.name] = s
  end
  local as = p.show.args_show
  p.shown_args = {}
  if type(as) == "table" then
    for i, name in ipairs(as) do
      local s = by_name[name]
      if not s then
        ctx:fail(("%sshow.args_show[%d]"):format(p.prefix, i - 1), "unknown argument '%s'", name)
      end
      p.shown_args[#p.shown_args + 1] = s
    end
  elseif as == true then
    local used, all = used_args(cfg.dir, p.query)
    for _, s in ipairs(p.visible_args) do
      if s.show and (all or used[s.name] or s.panel == p.index) then
        p.shown_args[#p.shown_args + 1] = s
      end
    end
  end
end

local M = {
  name = "dashboard",
  checks = "the top-level fields, each panel's query and show's common fields, intervals",
  after = { "db", "args" },
  validate = function(cfg, ctx)
    local data = cfg.raw
    dashboard_fields(ctx, cfg, data)
    if cfg.listed then
      check_defaults(
        ctx,
        ctx:expect("query", data.query, "map", true),
        ctx:expect("show", data.show, "map", true)
      )
    end
    local top_interval = nn(data.interval)
    for _, p in ipairs(cfg.panels) do
      p.query = query(ctx, p)
      p.show = show(ctx, p.raw.show, top_interval, p.prefix)
      p.follows_global = cfg.refresh_all ~= nil and p.show.interval >= cfg.refresh_all
      if p.show.refresh_hidden and require("dbdash.db").driver(p.database.type).produce then
        ctx:fail(
          p.prefix .. "show.refresh_hidden",
          "refresh_hidden does not apply to %s:// (push sources keep receiving while hidden)",
          p.database.type
        )
      end
      shown_args(ctx, cfg, p)
    end
  end,
}

return M
