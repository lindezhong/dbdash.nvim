-- Thresholds: levels, classes on stat values and table cells (colored by style sheets),
-- config validation.
local T = require("dbdash.render.thresholds")
local render = require("dbdash.render")
local resultset = require("dbdash.db.resultset")
local helpers = require("tests.helpers")
local eq = MiniTest.expect.equality
local S = MiniTest.new_set()

local STEPS =
  { { value = 100, class = "warning" }, { value = 500, class = "danger", notify = true } }

S["levels: highest step reached; below reverses the direction"] = function()
  local up = T.steps(STEPS)
  eq({ T.level(50, up) }, { 0 })
  eq(T.level(100, up), 1)
  eq(T.level(499.9, up), 1)
  local level, step = T.level(800, up)
  assert(step)
  eq({ level, step.class, step.notify }, { 2, "danger", true })
  eq(T.level("650", up), 2) -- numeric text (decimals)
  eq(T.level(vim.NIL, up), 0)
  eq(T.level("n/a", up), 0)
  local down =
    T.steps({ { value = 10, class = "danger" }, { value = 50, class = "warning" } }, true)
  eq(T.level(80, down, true), 0)
  eq(T.level(50, down, true), 1)
  eq(T.level(3, down, true), 2)
end

S["check: config errors"] = function()
  eq(T.check(STEPS), nil)
  eq(T.check({ value = 1 }), "thresholds must be a list of { value, class, notify }")
  eq(T.check({ { class = "danger" } }), "thresholds[0]: value must be a number")
  eq(T.check({ { value = 1, color = "red" } }):find("color is appearance", 1, true) ~= nil, true)
  eq(T.check({ { value = 1, class = "a b" } }), "thresholds[0]: class must be a class name")
  eq(T.check({ { value = 1, notify = "yes" } }), "thresholds[0]: notify must be true or false")
end

S["stat value: its step's class colors it"] = function()
  local rs = resultset.new({ { name = "errors", type = "integer" } }, { { 650 } })
  local out = render.render(
    rs,
    { type = "stat", title = "Errors", thresholds = STEPS },
    { width = 60, height = 10 }
  )
  eq(out.hl[2].group, "DiagnosticError") -- value.danger in the UA sheet
  -- a rule recolors the class (Grafana colorMode: background is a background-color)
  local bg = render.render(
    rs,
    { type = "stat", thresholds = STEPS },
    { width = 60, height = 10, style = { ["value.danger"] = { ["background-color"] = "#400000" } } }
  )
  eq(bg.hl[1].group:match("^DbDashCss_") ~= nil, true)
  helpers.golden("stat/big/thresholds", out)
  rs = resultset.new({ { name = "errors", type = "integer" } }, { { 5 } })
  out = render.render(rs, { type = "stat", thresholds = STEPS }, { width = 60, height = 10 })
  eq(out.hl[1].group, "DbDashStatValue") -- below every step
end

S["table cells: classes per column"] = function()
  local rs = resultset.new({
    { name = "host", type = "string" },
    { name = "errors", type = "integer" },
    { name = "free_gb", type = "integer" },
  }, { { "a", 20, 80 }, { "b", 150, 40 }, { "c", 900, 5 }, { "d", vim.NIL, vim.NIL } })
  local show = {
    type = "table",
    column_list = {
      "host",
      { column = "errors", thresholds = STEPS },
      {
        column = "free_gb",
        thresholds = { { value = 50, class = "warning" }, { value = 10, class = "danger" } },
        thresholds_below = true,
      },
    },
  }
  helpers.golden("table/box/thresholds", render.render(rs, show, { width = 60, height = 20 }))
  local levels = T.levels(rs, show)
  eq(
    { levels.errors.level, levels.errors.value, levels.free_gb.level, levels.free_gb.value },
    { 2, 900, 2, 5 }
  )
end

S["config reports invalid thresholds with their line"] = function()
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile({
    "database: { url: 'sqlite:///:memory:' }",
    "query: { sql: SELECT 1 }",
    "show:",
    "  type: table",
    "  column_list:",
    "    - column: x",
    "      thresholds: [{ class: danger }]",
  }, f)
  local _, err = require("dbdash.config").load(f)
  eq(assert(err).message:find("thresholds%[0%]: value must be a number") ~= nil, true)
end

return S
