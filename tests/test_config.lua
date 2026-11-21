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
  eq(cfg.query.args_show, false)
  eq(cfg.query.args, {})
  eq(cfg.show.type, "table")
  eq(cfg.show.interval, 30000)
  eq(cfg.show.show_countdown, false)
  eq(cfg.show.countdown_format, "Next update: {time}s")
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

T["legacy key: in args is rejected with a hint"] = function()
  local msg = err_of(MINIMAL .. "  args:\n    - key: x\n      default: 1\n")
  eq(msg:find("rename it to 'name:'", 1, true) ~= nil, true)
  eq(msg:find(":7:", 1, true) ~= nil, true)
end

T["validation errors name the field and position"] = function()
  eq(err_of("database:\n  url: oracle://h/x\nquery:\n  sql: x\n"):find("Oracle is not supported") ~= nil, true)
  eq(err_of("database:\n  url: foo://h\nquery:\n  sql: x\n"):find("unsupported database type 'foo'") ~= nil, true)
  eq(err_of(MINIMAL .. "show:\n  type: radar\n"):find(":7:9: unknown chart type 'radar'", 1, true) ~= nil, true)
  eq(err_of(MINIMAL .. "show:\n  interval: soon\n"):find("invalid duration") ~= nil, true)
  eq(err_of("database:\n  url: x\n"):find("missing required field 'database.url'") == nil, true)
  eq(err_of("query:\n  sql: x\n"):find("missing required field 'database'") ~= nil, true)
  eq(err_of("a: [1\n"):find("unterminated flow collection") ~= nil, true)
end

T["top-level interval is honored like the old plugin"] = function()
  local cfg = assert(load(MINIMAL .. "interval: 2m\n"))
  eq(cfg.show.interval, 120000)
end

T["single-chart configs become one panel"] = function()
  local cfg = assert(load(MINIMAL .. "args:\n  - name: top\n"))
  eq({ cfg.multi, #cfg.panels, cfg.panels[1].query == cfg.query }, { false, 1, true })
  eq(vim.tbl_map(function(a)
    return a.name
  end, cfg.args), { "top" })
end

local MULTI = [[
database:
  url: "sqlite:///:memory:"
interval: 5m
args:
  - name: region
    default: Asia
layout:
  columns: 2
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
      span: 2
  - database:
      url: "redis://localhost"
    query:
      sql: GET k
]]

T["multi-panel configs"] = function()
  local cfg = assert(load(MULTI))
  eq({ cfg.multi, #cfg.panels, cfg.layout.columns, cfg.layout.gap, cfg.interval }, { true, 2, 2, 2, 300000 })
  eq(vim.tbl_map(function(a)
    return a.name
  end, cfg.args), { "region", "n" })
  local p1, p2 = cfg.panels[1], cfg.panels[2]
  eq({ p1.show.interval, p1.show.own_interval, p1.show.span, p1.database.type }, { 30000, true, 2, "sqlite" })
  eq({ p2.show.interval, p2.show.own_interval, p2.database.type, p2.query.sql_line }, { 300000, false, "redis", 24 })
end

T["multi-panel errors point at the panel"] = function()
  local msg = err_of(MULTI:gsub("        %- name: region\n          default: Asia\n", "        - name: region\n          default: EU\n"))
  eq(msg:find("argument 'region' is declared differently at args%[1%]%.name") ~= nil, true)
  eq(err_of("panels:\n  - query:\n      sql: x\n"):find("panels%[1%]%.database: missing database") ~= nil, true)
  eq(err_of("database:\n  url: sqlite:///:memory:\nquery:\n  sql: x\npanels:\n  - query:\n      sql: y\n"):find("not both") ~= nil, true)
  eq(err_of(MULTI .. "    show:\n      type: radar\n"):find(":%d+:%d+: unknown chart type 'radar'") ~= nil, true)
end

return T
