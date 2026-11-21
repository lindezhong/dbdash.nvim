local layout = require("dbdash.render.layout")
local helpers = require("tests.helpers")
local W = require("dbdash.util.width")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function box(title, n, group)
  local lines, hl = { title }, { { row = 0, col_s = 0, col_e = #title, group = group or "DbDashTitle" } }
  for i = 1, n do
    lines[#lines + 1] = ("%s line %d"):format(title, i)
  end
  return { lines = lines, hl = hl }
end

T["plan: flow, wrap and span"] = function()
  local cells = layout.plan({ 1, 1, 2, 1 }, 82, 2, 2)
  eq(vim.tbl_map(function(c)
    return { c.row, c.col, c.width, c.x }
  end, cells), { { 1, 0, 40, 0 }, { 1, 1, 40, 42 }, { 2, 0, 82, 0 }, { 3, 0, 40, 0 } })
  -- span wider than the grid is clamped
  eq(layout.plan({ 5 }, 50, 2, 2)[1].width, 50)
end

T["compose: side by side, uneven heights, blank line between rows"] = function()
  local cells = layout.plan({ 1, 1, 2 }, 42, 2, 2)
  local out = layout.compose(cells, { box("中文 A", 1), box("B", 3, "DbDashSeries1"), box("Wide", 0) })
  helpers.golden("layout/grid", out)
  for _, l in ipairs(out.lines) do
    eq(W.width(l) <= 42, true)
  end
  eq(out.regions[1], { row_s = 0, row_e = 3, x = 0, width = 20 })
  eq(out.regions[2], { row_s = 0, row_e = 3, x = 22, width = 20 })
  eq(out.regions[3], { row_s = 5, row_e = 5, x = 0, width = 42 })
  eq(out.lines[5], "")
end

T["compose: long lines are cut and highlights clipped"] = function()
  local cells = layout.plan({ 1, 1 }, 22, 2, 2)
  local long = { lines = { string.rep("x", 30) }, hl = { { row = 0, col_s = 5, col_e = 30, group = "G" } } }
  local out = layout.compose(cells, { long, box("R", 0) })
  eq(out.lines[1], string.rep("x", 10) .. "  R")
  eq(out.hl[1], { row = 0, col_s = 5, col_e = 10, group = "G" })
  eq(out.hl[2], { row = 0, col_s = 12, col_e = 13, group = "DbDashTitle" })
end

return T
