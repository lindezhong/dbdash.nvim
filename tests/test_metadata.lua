-- Dashboards give templates and Lua code two names: args.<name> (the arguments) and
-- meta.<name> (metadata such as meta.config_dir and meta.os).
local sched = require("dbdash.dashboard")
local metadata = require("dbdash.metadata")
local template = require("dbdash.template")
local eq = MiniTest.expect.equality

local dir, notes
local real_notify = vim.notify
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      require("dbdash").setup({ lua = { confirm = false } }) -- trust is tested in test_trust.lua
      notes = {}
      vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
      end
    end,
    post_case = function()
      vim.notify = real_notify
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
    end,
  },
})

---Start a dashboard from config lines; wait for the first result of every panel.
local function run(name, lines)
  local path = dir .. "/" .. name .. ".yaml"
  vim.fn.writefile(lines, path)
  require("dbdash.view.dashboard").start(path, { no_show = true })
  local d = assert(sched.get(sched.normalize(path)), "dashboard did not start")
  vim.wait(10000, function()
    for _, p in ipairs(d.panels) do
      if not (p.rs or p.error) or p.running then
        return false
      end
    end
    return true
  end, 10)
  return d.panels[1], d
end

T["every name has a value of the right type"] = function()
  local p = run("board", {
    "database: { url: 'sqlite:///:memory:' }",
    "query: { sql: SELECT 1 AS x }",
    "show: { type: table, title: Board, interval: 7s }",
  })
  local v = p.meta
  local strings = {
    "cwd",
    "config_file",
    "config_dir",
    "config_name",
    "db_type",
    "db_name",
    "db_url",
    "panel_title",
    "chart_type",
    "now",
    "today",
    "hostname",
    "user",
    "nvim_version",
    "os",
    "arch",
  }
  for _, n in ipairs(strings) do
    eq({ n, type(v[n]) }, { n, "string" })
  end
  for _, n in ipairs({ "panel_index", "interval", "max_rows", "timeout", "refresh_count" }) do
    eq({ n, type(v[n]) }, { n, "number" })
  end
  eq({ v.config_file, v.config_dir, v.config_name }, { dir .. "/board.yaml", dir, "board" })
  eq(
    { v.db_type, v.db_name, v.panel_index, v.panel_title, v.chart_type, v.interval },
    { "sqlite", ":memory:", 1, "Board", "table", 7000 }
  )
  eq(v.today, os.date("%Y-%m-%d"))
  eq(v.now:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[+-]%d%d:%d%d$") ~= nil, true)
  eq(v.os, jit.os == "Windows" and "windows" or jit.os == "OSX" and "macos" or jit.os:lower())
  eq(v.refresh_count, 1)
  -- every documented name is known
  table.sort(strings)
  eq(#metadata.NAMES, 31)
end

T["db_*: from the URL as written, without the password or expanded ${NAME}"] = function()
  vim.env.DBDASH_TEST_SECRET = "s3cret"
  local p = run("pg", {
    "database: { url: 'postgres://app:${DBDASH_TEST_SECRET}@db.internal/shop?tls=require' }",
    "query: { sql: SELECT 1 }",
  })
  local v = p.meta
  eq(
    { v.db_type, v.db_host, v.db_port, v.db_name, v.db_user },
    { "postgres", "db.internal", 5432, "shop", "app" }
  )
  eq(v.db_url, "postgres://app:***@db.internal/shop?tls=require")
  local l = run("lua", { "database: { url: 'lua://' }", "query: { sql: 'return { { x = 1 } }' }" })
  eq({ l.meta.db_type, l.meta.db_host, l.meta.db_port }, { "lua", nil, nil })
end

T["db_*: each panel's own database, else the top-level default"] = function()
  local _, d = run("mixed", {
    "database: { url: 'postgres://app@db.internal/shop' }",
    "panels:",
    "  - database: { url: 'sqlite:///:memory:' }",
    "    query: { sql: 'SELECT {{ meta.db_type | sql_quote }} AS t' }",
    "  - database: { url: 'lua://' }",
    "    query: { sql: 'return { { t = meta.db_type, url = meta.db_url } }' }",
  })
  local p1, p2 = d.panels[1], d.panels[2]
  eq({ p1.meta.db_type, p1.meta.db_name, p1.rs.rows[1][1] }, { "sqlite", ":memory:", "sqlite" })
  eq({ p2.meta.db_type, p2.meta.db_url, p2.meta.db_host }, { "lua", "lua://", nil })
  eq(p2.rs.rows[1][1], "lua")
  -- A panel without its own database reports the top-level one.
  local _, d2 = run("shared", {
    "database: { url: 'sqlite:///:memory:' }",
    "panels:",
    "  - query: { sql: SELECT 1 }",
    "  - database: { url: 'lua://' }",
    "    query: { sql: 'return { { x = 1 } }' }",
  })
  eq({ d2.panels[1].meta.db_type, d2.panels[2].meta.db_type }, { "sqlite", "lua" })
end

T["args and meta in query.sql, query.transform, lua:// and imported templates"] = function()
  vim.fn.writefile({
    "{% macro where_dir() %}{{ meta.config_name | sql_quote }} AS cfg, {{ args.n }} AS n2{% endmacro %}",
  }, dir .. "/m.sql")
  local p = run("ctx", {
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  args: [{ name: n, type: int, default: 4 }]",
    "  sql: |",
    "    {% import 'm.sql' as m %}",
    "    SELECT {{ args.n }} AS n, {{ meta.panel_index }} AS idx, {{ m.where_dir() }}",
    "  transform: |",
    "    return { { n = rs.rows[1][1], idx = rs.rows[1][2], cfg = rs.rows[1][3], n2 = rs.rows[1][4],",
    "               lua_n = args.n, lua_cfg = meta.config_name, tpl_n = {{ args.n }} } }",
  })
  eq(p.error, nil)
  eq(p.rs.columns[1].name, "cfg")
  local row = {}
  for i, c in ipairs(p.rs.columns) do
    row[c.name] = p.rs.rows[1][i]
  end
  eq(row, { n = 4, idx = 1, cfg = "ctx", n2 = 4, lua_n = 4, lua_cfg = "ctx", tpl_n = 4 })
  local l = run("luactx", {
    "database: { url: 'lua://' }",
    "query:",
    "  args: [{ name: os, default: x }, { name: table, default: y }]",
    "  sql: |",
    "    return { { a = args.os, b = args.table, os = meta.os, today = os.date('%Y-%m-%d'),",
    "               n = table.concat({ 'p', 'q' }) } }",
  })
  eq(l.error, nil)
  -- arguments named os / table do not hide Lua's libraries
  eq(l.rs.rows[1], { "x", "y", "pq", metadata.os_name(), os.date("%Y-%m-%d") })
end

T["{% lua %} blocks in query.sql and query.transform see the same args and meta"] = function()
  local p = run("blocks", {
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  args: [{ name: n, type: int, default: 6 }]",
    "  sql: |",
    "    SELECT {% lua %}return args.n * 2{% endlua %} AS n,",
    "           '{% lua %}return meta.config_name{% endlua %}' AS cfg",
    "  transform: |",
    "    return { { n = rs.rows[1][1], cfg = rs.rows[1][2],",
    "               t = '{% lua %}return meta.config_name .. args.n{% endlua %}' } }",
  })
  eq(p.error, nil)
  eq(p.rs.rows, { { "blocks", 12, "blocks6" } })
  -- an error in a block points at the YAML line
  p = run("blockerr", {
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  sql: |",
    "    SELECT 1",
    "    {% lua %}",
    "    return nil + 1",
    "    {% endlua %}",
  })
  eq(
    sched
      .format_error(p.error)
      :find("blockerr.yaml:6: attempt to perform arithmetic on a nil value", 1, true) ~= nil,
    true
  )
end

T["meta.refresh_count and meta.now change per refresh"] = function()
  local p = run("count", {
    "database: { url: 'sqlite:///:memory:' }",
    "query: { sql: 'SELECT {{ meta.refresh_count }} AS c' }",
  })
  eq(p.rs.rows[1][1], 1)
  p:refresh()
  vim.wait(5000, function()
    return not p.running and p.rs.rows[1][1] == 2
  end, 10)
  eq(p.rs.rows[1][1], 2)
end

T["bare argument names, assigning args/meta and writing meta are errors"] = function()
  local p = run("bare", {
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  args: [{ name: days, type: int, default: 3 }]",
    "  sql: |",
    "    SELECT 1",
    "    WHERE {{ days }} > 0",
  })
  eq(
    sched
      .format_error(p.error)
      :find("bare.yaml:6: 'days' is undefined; arguments are written args.days", 1, true)
      ~= nil,
    true
  )
  local _, err = template.render("{% set args = 1 %}{{ args }}", {})
  eq(err.message, "'args' is reserved (dashboard arguments) and cannot be assigned")
  _, err = template.render("{% for meta in [1] %}{% endfor %}", {})
  eq(err.message, "'meta' is reserved (dashboard metadata) and cannot be assigned")
  local l = run("ro", { "database: { url: 'lua://' }", "query: { sql: 'meta.os = 1; return {}' }" })
  eq(l.error.message:find("meta is read-only (meta.os)", 1, true) ~= nil, true)
end

T["iso_now carries the UTC offset"] = function()
  local s = metadata.iso_now(0)
  eq(s:match("[+-]%d%d:%d%d$") ~= nil, true)
end

return T
