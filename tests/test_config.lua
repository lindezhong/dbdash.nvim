local config = require("dbdash.config")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function write(text)
  local path = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile(vim.split(text, "\n"), path)
  return path
end

local function load(text)
  return config.load(write(text))
end

local function err_of(text)
  local cfg, err = load(text)
  eq(cfg, nil)
  return err.message
end

local MINIMAL = [[
database:
  url: "sqlite:///:memory:"
query:
  sql: |
    SELECT 1
]]

T["parse_duration"] = function()
  eq(config.parse_duration("30s"), 30000)
  eq(config.parse_duration("5m"), 300000)
  eq(config.parse_duration("1h"), 3600000)
  eq(config.parse_duration("250ms"), 250)
  eq(config.parse_duration(10), 10000)
  eq(config.parse_duration("1.5s"), 1500)
  eq(config.parse_duration(nil), nil)
  eq(select(2, config.parse_duration("soon")) ~= nil, true)
end

T["scheme_of"] = function()
  eq(config.scheme_of("postgresql://h/db"), "postgres")
  eq(config.scheme_of("mongodb+srv://h"), "mongodb")
  eq(config.scheme_of("sqlite:///:memory:"), "sqlite")
  eq(config.scheme_of("nope"), nil)
end

T["minimal config gets defaults"] = function()
  local cfg = assert(load(MINIMAL))
  eq(cfg.database.type, "sqlite")
  eq(cfg.query.sql, "SELECT 1\n")
  eq(cfg.query.sql_line, 5)
  eq(cfg.query.max_rows, 10000)
  eq(cfg.query.autoescape, false)
  eq(cfg.show.args_show, false)
  eq(cfg.query.args, {})
  eq(cfg.show.type, "table")
  eq(cfg.show.interval, 30000)
  eq(cfg.style_rules, nil)
end

T["args are normalized"] = function()
  local cfg = assert(load(MINIMAL .. [[
  args:
    - name: min_age
      type: number
      default: 18
      required: true
      choices: [18, 30]
    - name: label
]]))
  eq(cfg.query.args[1], {
    key = "min_age", -- a local argument of panel 1; its name is unique
    panel = 1,
    panel_id = "1",
    name = "min_age",
    type = "number",
    default = 18,
    required = true,
    show = true,
    choices = { 18, 30 },
  })
  eq(cfg.query.args[2].type, "string")
  eq(cfg.query.args[2].default, nil)
end

T["key: in args is rejected with a hint"] = function()
  local msg = err_of(MINIMAL .. "  args:\n    - key: x\n      default: 1\n")
  eq(msg:find("rename it to 'name:'", 1, true) ~= nil, true)
  eq(msg:find(":7:", 1, true) ~= nil, true)
end

T["validation errors name the field and position"] = function()
  eq(
    err_of("database:\n  url: oracle://h/x\nquery:\n  sql: x\n"):find("Oracle is not supported")
      ~= nil,
    true
  )
  eq(
    err_of("database:\n  url: foo://h\nquery:\n  sql: x\n"):find("unsupported database type 'foo'")
      ~= nil,
    true
  )
  eq(
    err_of(MINIMAL .. "show:\n  type: radar\n"):find(":7:9: unknown chart type 'radar'", 1, true)
      ~= nil,
    true
  )
  eq(err_of(MINIMAL .. "show:\n  interval: soon\n"):find("invalid duration") ~= nil, true)
  eq(err_of("database:\n  url: x\n"):find("missing required field 'database.url'") == nil, true)
  eq(err_of("query:\n  sql: x\n"):find("missing required field 'database'") ~= nil, true)
  eq(err_of("a: [1\n"):find("unterminated flow collection") ~= nil, true)
end

T["the top-level interval is the panel's interval without its own"] = function()
  local cfg = assert(load(MINIMAL .. "interval: 2m\n"))
  eq(cfg.show.interval, 120000)
end

T["single-chart configs become one panel"] = function()
  local cfg = assert(load(MINIMAL .. "args:\n  - name: top\n"))
  eq({ cfg.grid, #cfg.panels, cfg.panels[1].query == cfg.query }, { false, 1, true })
  eq(
    vim.tbl_map(function(a)
      return a.key
    end, cfg.args),
    { "top" }
  )
end

local MULTI = [[
database:
  url: "sqlite:///:memory:"
interval: 5m
args:
  - name: region
    default: Asia
style:
  dashboard: { grid-template-columns: 2 }
panels:
  - query:
      sql: SELECT 1
      args:
        - name: region
          default: Asia
        - name: n
          type: int
    show:
      type: line
      interval: 30s
    style:
      panel: { grid-column: span 2 }
  - database:
      url: "redis://localhost"
    query:
      sql: GET k
]]

T["multi-panel configs"] = function()
  local cfg = assert(load(MULTI))
  eq({ cfg.grid, #cfg.panels, #cfg.style_rules, cfg.refresh_all }, { true, 2, 1, 300000 })
  -- Shared arguments, then each panel's local ones (keyed <panel id>.<name>).
  eq(
    vim.tbl_map(function(a)
      return a.key
    end, cfg.args),
    { "region", "1.region", "n" }
  )
  local p1, p2 = cfg.panels[1], cfg.panels[2]
  eq({
    p1.show.interval,
    p1.follows_global,
    p1.style_rules[1].decls["grid-column"],
    p1.database.type,
  }, { 30000, false, "span 2", "sqlite" })
  eq(
    { p2.show.interval, p2.follows_global, p2.database.type, p2.query.sql_line, p2.style_rules },
    { 300000, true, "redis", 25, nil }
  )
end

T["the top-level database is only a default: a panel's own wins, either is enough"] = function()
  -- Every panel sets its own: no top-level database needed.
  local cfg = assert(load([[
panels:
  - database: { url: "sqlite:///:memory:" }
    query: { sql: SELECT 1 }
  - database: { url: "lua://" }
    query: { sql: "return {}" }
]]))
  eq(
    { cfg.database, cfg.panels[1].database.type, cfg.panels[2].database.type },
    { nil, "sqlite", "lua" }
  )
  -- Panels without one use the top-level default; cfg.database is that default.
  cfg = assert(load(MULTI))
  eq(
    { cfg.database.type, cfg.panels[1].database == cfg.database, cfg.panels[2].database.type },
    { "sqlite", true, "redis" }
  )
  -- Single-chart configs: the top-level database is the panel's.
  cfg = assert(load(MINIMAL))
  eq(cfg.panels[1].database == cfg.database, true)
  -- Only a panel with neither is an error, pointing at that panel.
  local msg = err_of(
    "panels:\n  - database: { url: 'lua://' }\n    query: { sql: x }\n  - query: { sql: y }\n"
  )
  eq(
    msg:find(
      "missing required field 'panels%[2%]%.database' %(set it in the panel or at the top level%)"
    ) ~= nil,
    true
  )
end

T["multi-panel errors point at the panel"] = function()
  eq(
    err_of("panels:\n  - query:\n      sql: x\n"):find(
      "missing required field 'panels%[1%]%.database'"
    ) ~= nil,
    true
  )
  eq(
    err_of(MULTI .. "    show:\n      type: radar\n"):find(":%d+:%d+: unknown chart type 'radar'")
      ~= nil,
    true
  )
end

-- One panel as a one-chart config and as panels[1]: same result, same errors.
local PANEL = [[
  database: { url: "sqlite:///:memory:" }
  query:
    sql: SELECT 1
    timeout: 5s
    args: [{ name: n, type: int, default: 3 }]
  show: { type: bar, title: T, interval: 20s, args_show: true }
]]

T["a one-chart config and panels[1] are validated the same way"] = function()
  local single = assert(load(PANEL:gsub("\n  ", "\n"):gsub("^  ", "")))
  local multi = assert(load("panels:\n  -" .. PANEL:sub(2):gsub("\n  ", "\n    ")))
  local a, b = single.panels[1], multi.panels[1]
  eq({
    a.database,
    a.query.sql,
    a.query.timeout,
    a.query.args,
    a.show.type,
    a.show.interval,
    a.show.args_show,
  }, {
    b.database,
    b.query.sql,
    b.query.timeout,
    b.query.args,
    b.show.type,
    b.show.interval,
    b.show.args_show,
  })
  -- The same mistake gives the same message, with the panel's path.
  local e1 = err_of("database: { url: 'sqlite:///:memory:' }\nquery: { sql: x, max_rows: many }\n")
  local e2 = err_of(
    "database: { url: 'sqlite:///:memory:' }\npanels:\n  - query: { sql: x, max_rows: many }\n"
  )
  eq(e1:match(": (.*)$"), "'query.max_rows' must be a integer")
  eq(e2:match(": (.*)$"), "'panels[1].query.max_rows' must be a integer")
end

T["with panels, top-level query and show are defaults"] = function()
  local cfg = assert(load([[
database: { url: "sqlite:///:memory:" }
query: { timeout: 5s, max_rows: 10 }
show:
  axes: { x_axis: { title: t, format: "{}" } }
panels:
  - query: { sql: SELECT 1 }
  - query: { sql: SELECT 2, max_rows: 20 }
    show: { axes: { x_axis: { title: u } } }
]]))
  local p1, p2 = cfg.panels[1], cfg.panels[2]
  eq({ p1.query.timeout, p1.query.max_rows, p1.show.axes.x_axis.title }, { 5000, 10, "t" })
  -- Mappings merge key by key: format is kept, title overridden.
  eq(
    { p2.query.max_rows, p2.show.axes.x_axis.title, p2.show.axes.x_axis.format },
    { 20, "u", "{}" }
  )
  -- An inherited invalid value is reported at the top-level line.
  local msg = err_of(
    "database: { url: 'sqlite:///:memory:' }\nshow:\n  interval: soon\npanels:\n  - query: { sql: x }\n"
  )
  eq(msg:find(":3:13: 'panels%[1%]%.show%.interval'") ~= nil, true)
end

T["fields of one chart cannot be top-level defaults"] = function()
  local base = "database: { url: 'sqlite:///:memory:' }\npanels:\n  - query: { sql: x }\n"
  for _, f in ipairs({
    "show:\n  type: bar\n",
    "show:\n  title: T\n",
    "show:\n  x_column: a\n",
    "show:\n  column_list: []\n",
    "query:\n  sql: y\n",
    "query:\n  transform: y\n",
  }) do
    local msg = err_of(base .. f)
    eq(
      { f, msg:find("belongs to one panel; with panels, set it in each panel") ~= nil },
      { f, true }
    )
  end
  eq(
    err_of(base .. "query:\n  args: []\n"):find("shared arguments go in the top%-level args") ~= nil,
    true
  )
  -- Without panels the top level is the panel: all of them are fine there.
  assert(
    load(
      "database: { url: 'sqlite:///:memory:' }\nquery: { sql: x }\nshow: { type: bar, title: T }\n"
    )
  )
end

T["the database of a panel replaces the default as a whole"] = function()
  local cfg = assert(load([[
database:
  url: "sqlite:///:memory:"
  password_cmd: "pass show db"
  options: { readonly: true }
panels:
  - query: { sql: SELECT 1 }
  - database: { url: "sqlite:///:memory:" }
    query: { sql: SELECT 2 }
]]))
  eq(
    { cfg.panels[1].database.password_cmd, cfg.panels[1].database.options.readonly },
    { "pass show db", true }
  )
  eq({ cfg.panels[2].database.password_cmd, cfg.panels[2].database.options.readonly }, { nil, nil })
end

T["interval: show.interval, top-level show.interval, top-level interval, setup default"] = function()
  local function intervals(text)
    local cfg = assert(load(text))
    return vim.tbl_map(function(p)
      return { p.show.interval, p.follows_global }
    end, cfg.panels),
      cfg.refresh_all
  end
  local db = "database: { url: 'sqlite:///:memory:' }\n"
  -- Global refresh and a panel's own interval: both apply; the panel without one follows.
  local iv, all = intervals(
    db
      .. "interval: 10m\npanels:\n  - { query: { sql: x }, show: { interval: 30s } }\n  - { query: { sql: y } }\n"
  )
  eq({ iv, all }, { { { 30000, false }, { 600000, true } }, 600000 })
  -- The top-level show.interval comes before the top-level interval.
  iv =
    intervals(db .. "interval: 10m\nshow: { interval: 1m }\npanels:\n  - { query: { sql: x } }\n")
  eq(iv, { { 60000, false } })
  -- No global refresh: the panel's interval, else setup's default.
  iv, all = intervals(
    db .. "panels:\n  - { query: { sql: x }, show: { interval: 30s } }\n  - { query: { sql: y } }\n"
  )
  eq({ iv, all }, { { { 30000, false }, { 30000, false } }, nil })
  -- One-chart configs are the same: the top-level interval refreshes as well.
  iv, all = intervals(db .. "interval: 2m\nquery: { sql: x }\nshow: { interval: 30s }\n")
  eq({ iv, all }, { { { 30000, false } }, 120000 })
end

T["arguments: shared at the top level, local in a panel, a local one shadows"] = function()
  local cfg = assert(load([[
database: { url: "sqlite:///:memory:" }
args:
  - { name: region, default: EU }
  - { name: hours, type: int, default: 24 }
panels:
  - id: orders
    query:
      sql: "SELECT {{ args.region }}"
      args: [{ name: region, default: US }, { name: limit, type: int, default: 5 }]
  - query:
      sql: "SELECT {{ args.region }}"
      args: [{ name: limit, type: int, default: 9 }]
]]))
  local function visible(p)
    return vim.tbl_map(function(a)
      return a.key
    end, p.visible_args)
  end
  eq(visible(cfg.panels[1]), { "orders.region", "hours", "orders.limit" })
  -- (a local name nothing else has is its own key; panel 2's limit clashes with panel 1's)
  eq(visible(cfg.panels[2]), { "region", "hours", "2.limit" })
  local state = require("dbdash.args").new_state()
  local a = require("dbdash.args")
  eq(
    { a.resolve_panel(cfg.panels[1], state).region, a.resolve_panel(cfg.panels[2], state).region },
    { "US", "EU" }
  )
  -- Duplicates within one scope and bad panel ids are errors.
  local db = "database: { url: 'sqlite:///:memory:' }\n"
  eq(
    err_of(db .. "args: [{ name: a }, { name: a }]\nquery: { sql: x }\n"):find(
      "duplicate argument 'a'"
    ) ~= nil,
    true
  )
  eq(
    err_of(db .. "panels:\n  - { id: x, query: { sql: x } }\n  - { id: x, query: { sql: y } }\n"):find(
      "duplicate panel id 'x'"
    ) ~= nil,
    true
  )
  eq(
    err_of(db .. "panels:\n  - { id: 'a b', query: { sql: x } }\n"):find("must be an identifier")
      ~= nil,
    true
  )
end

T["args_show: show.args_show lists the arguments the panel reads"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "{% macro f() %}{{ args.days }}{% endmacro %}" }, dir .. "/m.sql")
  local path = dir .. "/c.yaml"
  vim.fn.writefile(
    vim.split(
      [[
database: { url: "sqlite:///:memory:" }
args:
  - { name: region }
  - { name: days, type: int }
  - { name: secret, show: false }
  - { name: unused }
show: { args_show: true }
panels:
  - query:
      sql: "{% import 'm.sql' as m %}SELECT {{ args.region }}, {{ args['secret'] }}, {{ m.f() }}"
  - query: { sql: "SELECT {% for k, v in args.items() %}{{ v }}{% endfor %}" }
  - query: { sql: SELECT 1, args: [{ name: own }] }
    show: { args_show: [unused, own] }
  - query: { sql: "SELECT {{ args.region }}" }
    show: { args_show: false }
]],
      "\n"
    ),
    path
  )
  local cfg = assert(config.load(path))
  local function shown(i)
    return vim.tbl_map(function(a)
      return a.key
    end, cfg.panels[i].shown_args)
  end
  eq(shown(1), { "region", "days" }) -- read directly and through the import; not show: false
  eq(shown(2), { "region", "days", "unused" }) -- args as a whole
  eq(shown(3), { "unused", "own" })
  eq(shown(4), {})
  eq(
    err_of(
      "database: { url: 'sqlite:///:memory:' }\nquery: { sql: x }\nshow: { args_show: [nope] }\n"
    ):find("unknown argument 'nope'") ~= nil,
    true
  )
  -- The old places are errors.
  eq(
    err_of(MINIMAL .. "  args_show: true\n"):find("'args_show' moved to show.args_show") ~= nil,
    true
  )
  eq(
    err_of(MINIMAL .. "args_show: true\n"):find("'args_show' moved to show.args_show") ~= nil,
    true
  )
end

T["arg_refs finds the argument names a template or Lua code reads"] = function()
  local function refs(t)
    local n, all = config.arg_refs(t)
    local names = vim.tbl_keys(n)
    table.sort(names)
    return { names, all }
  end
  eq(
    refs("{{ args.a }} {{ args [ 'b' ] }} {{ args[\"c\"] }} meta.args.x"),
    { { "a", "b", "c" }, false }
  )
  eq(refs("-- args: values as Lua numbers\nlocal x = args.n"), { { "n" }, false })
  eq(refs("{% for k in args %}"), { {}, true })
  eq(refs("f(args)"), { {}, true })
  eq(refs("args[k]"), { {}, true })
  eq(refs("{{ args.filters.items() }}"), { { "filters" }, false })
end

T["show.refresh_hidden is a boolean, with a top-level default"] = function()
  eq(
    err_of(MINIMAL .. "show: { refresh_hidden: 1 }\n"):find(
      "'show.refresh_hidden' must be a boolean"
    ) ~= nil,
    true
  )
  local cfg = assert(
    load(
      "database: { url: 'sqlite:///:memory:' }\nshow: { refresh_hidden: true }\npanels:\n  - query: { sql: x }\n  - query: { sql: y }\n    show: { refresh_hidden: false }\n"
    )
  )
  eq({ cfg.panels[1].show.refresh_hidden, cfg.panels[2].show.refresh_hidden }, { true, false })
end

T["appearance fields moved into style sheets say where"] = function()
  local function moved(yaml, want)
    local msg = err_of(yaml)
    eq({ yaml, msg:find(want, 1, true) ~= nil }, { yaml, true })
  end
  moved(
    MINIMAL .. "layout: { columns: 3 }\n",
    "'layout' is appearance and moved to style: dashboard {"
  )
  moved(MINIMAL .. "show_countdown: true\n", "header countdown { display: block }")
  moved(MINIMAL .. "show: { style: { border: true } }\n", "'show.style' is appearance")
  moved(MINIMAL .. "show: { height: 5 }\n", "plot { height: N }")
  moved(MINIMAL .. "show: { colors: [red] }\n", "series")
  moved(
    "database: { url: 'sqlite:///:memory:' }\npanels:\n  - query: { sql: x }\n    show: { span: 2 }\n",
    "'panels[1].show.span' is appearance"
  )
  moved(MINIMAL .. "show: { axes: { x_axis: { grid: true } } }\n", 'grid.x" { display: block }')
end

T["style sheets: parsed in order, errors name the declaration's line"] = function()
  local cfg =
    assert(load(MINIMAL .. "style:\n  title: { color: Error }\n  chart:\n    renderer: x\n"))
  eq(
    { #cfg.style_rules, cfg.style_rules[1].selector.text, cfg.style_rules[2].decls.renderer },
    { 2, "title", "x" }
  )
  local msg = err_of(MINIMAL .. "style:\n  title:\n    colour: red\n")
  eq(msg:find(":%d+:%d+: .*unknown property 'colour'") ~= nil, true)
  msg = err_of(MINIMAL .. "style:\n  'a >> b': { color: red }\n")
  eq(msg:find('selector "a >> b"', 1, true) ~= nil, true)
end

local GRID = "database: { url: 'sqlite:///:memory:' }\n"

---A dashboard's grid from its sheets, placed as layout does (from computed styles).
local function grid_of(yaml)
  local d = require("dbdash.dom.build").from_config(assert(load(yaml)))
  local style = require("dbdash.css.style")
  local items = {}
  for i, p in ipairs(d.panels) do
    items[i] = style.get(p.node)
  end
  return assert(require("dbdash.layout.grid").from_styles(style.get(d.doc.root), items))
end

T["grid: CSS Grid tracks, areas and placement from the style sheets"] = function()
  local lay = grid_of(GRID .. [[
style:
  dashboard:
    grid-template-columns: "1fr 30 25%"
    grid-template-rows: [auto, 12]
    grid-auto-rows: 1fr
    row-gap: 0
    grid-template-areas: ["a a b", "c . b"]
  "#p3": { grid-row: 3, grid-column: "2 / span 2" }
panels:
  - query: { sql: x }
    style: { panel: { grid-area: b } }
  - query: { sql: x }
    style: { panel: { grid-area: a } }
  - id: p3
    query: { sql: x }
  - query: { sql: x }
]])
  eq({ #lay.columns, #lay.rows, lay.auto_row.max, lay.row_gap }, { 3, 2, { "fr", 1 }, 0 })
  eq(lay.places[1], { row = 1, col = 3, span = 1, row_span = 2 })
  eq(lay.places[2], { row = 1, col = 1, span = 2, row_span = 1 })
  eq(lay.places[3], { row = 3, col = 2, span = 2, row_span = 1 })
  eq(lay.places[4], { row = 2, col = 1, span = 1, row_span = 1 }) -- the first free cell
  -- columns from the areas when not given
  lay = grid_of(
    GRID
      .. "style:\n  dashboard: { grid-template-areas: ['x y'] }\npanels:\n  - query: { sql: x }\n"
  )
  eq(#lay.columns, 2)
end

T["grid: errors name the declaration's line"] = function()
  local function grid_err(dashboard, panel)
    return err_of(
      GRID
        .. "style:\n  dashboard: "
        .. dashboard
        .. "\npanels:\n  - query: { sql: x }\n    style:\n      panel: "
        .. (panel or "{}")
        .. "\n  - query: { sql: y }\n    style:\n      panel: { grid-row: 1, grid-column: 1 }\n"
    )
  end
  eq(grid_err("{ grid-template-columns: [1fr, '10%%x'] }"):find(":3:.*invalid track") ~= nil, true)
  eq(grid_err("{ grid-template-rows: [max-content, '5%'] }"):find("invalid track") ~= nil, true)
  eq(
    grid_err("{ grid-template-areas: ['a b', 'b b'] }"):find('area "b" is not a rectangle') ~= nil,
    true
  )
  eq(
    grid_err("{ grid-template-columns: 3, grid-template-areas: ['a b'] }"):find(
      "3 columns, but grid%-template%-areas has 2"
    ) ~= nil,
    true
  )
  eq(
    grid_err("{ grid-template-columns: 2 }", "{ grid-row: 1, grid-column: 1 }"):find(
      ":10:.*overlaps panel 1"
    ) ~= nil,
    true
  )
  eq(
    grid_err("{ grid-template-columns: 2, grid-template-areas: ['a b'] }", "{ grid-area: zz }"):find(
      ":7:.*no area named"
    ) ~= nil,
    true
  )
  eq(
    grid_err("{ grid-template-columns: 2 }", "{ grid-row: '1 / span 0' }"):find("grid%-row") ~= nil,
    true
  )
  eq(grid_err("{ row-gap: -1 }"):find("at least 0") ~= nil, true)
end

T["every driver URL scheme is accepted, with drivers not loaded yet"] = function()
  local mods = { "sqlite", "redis", "postgres", "mysql", "cassandra", "mongodb", "mssql", "lua" }
  for _, m in ipairs(mods) do
    local drv = require("dbdash.db.drivers." .. m)
    for _, scheme in ipairs(drv.schemes) do
      local url = scheme .. "://h/x"
      local cfg, err = load(("database:\n  url: %q\nquery:\n  sql: x\n"):format(url))
      eq({ url, err and err.message, cfg and cfg.database.type }, { url, nil, drv.name })
      -- A fresh data layer (as on the first query of a session) resolves the alias too.
      for k in pairs(package.loaded) do
        if k:match("^dbdash%.db") and not k:match("^dbdash%.db%.drivers%.") then
          package.loaded[k] = nil
        end
      end
      local fresh = require("dbdash.db")
      eq({ scheme, fresh.driver(scheme).name }, { scheme, drv.name })
    end
  end
end

return T
