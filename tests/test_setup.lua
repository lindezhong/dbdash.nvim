-- setup(): option validation, defaults and global mappings.
local dbdash = require("dbdash")
local eq = MiniTest.expect.equality

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
      vim.notify = vim.api.nvim_notify
      dbdash.setup({})
    end,
  },
})

T["defaults keep the previous behavior"] = function()
  dbdash.setup()
  local o = dbdash.options
  eq({ o.sidebar.width, o.sidebar.position, o.dashboard.open, o.popup.border }, { 30, "left", "current", "rounded" })
  eq(o.sidebar.keys, { select = "<CR>", stop = "t", refresh = "r", close = "q" })
  eq({ dbdash.default_ms("interval"), dbdash.default_ms("timeout"), dbdash.default_ms("connect_timeout") }, { 30000, 30000, 10000 })
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
    "sidebar.keys: unknown key \"open\"",
    "dashboard: must be a table",
    "defaults.interval: invalid duration",
    "defaults.history: must be an integer >= 1",
    "colour: unknown option",
  }) do
    eq({ part, notes[1].msg:find(part, 1, true) ~= nil }, { part, true })
  end
  local o = dbdash.options
  eq({ o.sidebar.width, o.sidebar.position, o.dashboard.open, o.defaults.history }, { 30, "left", "current", 20 })
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
  eq({ lhs_of("Open the sidebar"), lhs_of("Stop the dashboard"), lhs_of("List dashboards") }, { "<F5>", nil, leader .. "dl" })
  eq(vim.fn.maparg(leader .. "dd", "n"), "") -- the previous key is gone
  dbdash.setup({ mappings = false })
  eq(lhs_of("Start a dashboard"), nil)
end

return T
