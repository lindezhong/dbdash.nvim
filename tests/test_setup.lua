-- setup(): option validation, defaults and global mappings.
local dbdash = require("dbdash")
local eq = MiniTest.expect.equality
local real_notify = vim.notify -- restored after each case (nvim_notify needs 3 arguments)

local notes
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      notes = {}
      vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
      end
    end,
    post_case = function()
      vim.notify = real_notify
      dbdash.setup({})
    end,
  },
})

T["defaults keep the previous behavior"] = function()
  dbdash.setup()
  local o = dbdash.options
  eq(
    { o.sidebar.width, o.sidebar.position, o.dashboard.open, o.popup.border },
    { 30, "left", "current", "rounded" }
  )
  eq(o.sidebar.keys, { select = "<CR>", stop = "t", refresh = "r", close = "q" })
  eq({
    dbdash.default_ms("interval"),
    dbdash.default_ms("timeout"),
    dbdash.default_ms("connect_timeout"),
  }, { 30000, 30000, 10000 })
  eq(#notes, 0)
end

T["nested options merge with the defaults; lists replace them"] = function()
  dbdash.setup({
    sidebar = { width = "30%", keys = { stop = "x", refresh = false }, pattern = { "*.dash.yaml" } },
    defaults = { interval = "1m" },
  })
  local o = dbdash.options
  eq(o.sidebar.width, "30%")
  eq(o.sidebar.keys, { select = "<CR>", stop = "x", refresh = false, close = "q" })
  eq(o.sidebar.pattern, { "*.dash.yaml" })
  eq(o.sidebar.exclude, { "*.schema.yaml", "*.schema.yml" })
  eq(dbdash.default_ms("interval"), 60000)
  eq(#notes, 0)
end

T["invalid values are reported with their path and fall back to the default"] = function()
  dbdash.setup({
    sidebar = { width = "30", position = "top", keys = { open = "o" } },
    dashboard = "vsplit",
    defaults = { interval = "soon", history = 0 },
    colour = "red",
  })
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.ERROR)
  for _, part in ipairs({
    "sidebar.width: invalid size",
    "sidebar.position: must be one of",
    'sidebar.keys: unknown key "open"',
    "dashboard: must be a table",
    "defaults.interval: invalid duration",
    "defaults.history: must be an integer >= 1",
    "colour: unknown option",
  }) do
    eq({ part, notes[1].msg:find(part, 1, true) ~= nil }, { part, true })
  end
  local o = dbdash.options
  eq(
    { o.sidebar.width, o.sidebar.position, o.dashboard.open, o.defaults.history },
    { 30, "left", "current", 20 }
  )
  eq(o.colour, nil)
end

T["mappings: true, false, or per name"] = function()
  local function lhs_of(desc)
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.desc == "dbdash: " .. desc then
        return m.lhs
      end
    end
  end
  local leader = vim.g.mapleader or "\\"
  dbdash.setup({ mappings = true })
  eq(lhs_of("Open the sidebar"), leader .. "dd")
  dbdash.setup({ mappings = { sidebar = "<F5>", stop = false } })
  eq(
    { lhs_of("Open the sidebar"), lhs_of("Stop the dashboard"), lhs_of("List dashboards") },
    { "<F5>", nil, leader .. "dl" }
  )
  eq(vim.fn.maparg(leader .. "dd", "n"), "") -- the previous key is gone
  dbdash.setup({ mappings = false })
  eq(lhs_of("Start a dashboard"), nil)
end

T["defaults apply where a config or URL sets nothing"] = function()
  dbdash.setup({
    defaults = { interval = "2m", max_rows = 5, timeout = "7s", connect_timeout = "3s" },
    style = { plot = { height = 6 } },
  })
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile({
    "database: { url: 'sqlite:///:memory:' }",
    "query: { sql: SELECT 1 }",
    "show: { type: table }",
  }, f)
  local cfg = assert(require("dbdash.config").load(f))
  eq({ cfg.show.interval, cfg.query.max_rows }, { 120000, 5 })
  local u = require("dbdash.db.url").parse("postgres://h/db")
  eq({ u.timeout, u.connect_timeout }, { 7000, 3000 })
  u = require("dbdash.db.url").parse("postgres://h/db?timeout=1s")
  eq(u.timeout, 1000) -- the URL wins

  -- plot height: a line chart is shorter with the user rule plot { height: 6 } than with
  -- its own 15
  local rs =
    require("tests.helpers").ok("sqlite:///:memory:", "SELECT 1 AS x, 2 AS y UNION ALL SELECT 2, 5")
  local show = { type = "line", x_column = "x", y_column = "y", title = "" }
  local short = #require("dbdash.render").render(rs, show, { width = 60, height = 40 }).lines
  dbdash.setup({})
  local tall = #require("dbdash.render").render(rs, show, { width = 60, height = 40 }).lines
  eq(tall - short, 9)
end

return T
