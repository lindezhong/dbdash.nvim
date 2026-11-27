local layout = require("dbdash.layout.grid")
local compositor = require("dbdash.compositor")
local helpers = require("tests.helpers")
local W = require("dbdash.util.width")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function box(title, n, group)
  local lines, hl =
    { title }, { { row = 0, col_s = 0, col_e = #title, group = group or "DbDashTitle" } }
  for i = 1, n do
    lines[#lines + 1] = ("%s line %d"):format(title, i)
  end
  return { lines = lines, hl = hl }
end

T["plan: flow, wrap and span"] = function()
  local cells = layout.plan({ 1, 1, 2, 1 }, 82, 2, 2)
  eq(
    vim.tbl_map(function(c)
      return { c.row, c.col, c.width, c.x }
    end, cells),
    { { 1, 0, 40, 0 }, { 1, 1, 40, 42 }, { 2, 0, 82, 0 }, { 3, 0, 40, 0 } }
  )
  -- span wider than the grid is clamped
  eq(layout.plan({ 5 }, 50, 2, 2)[1].width, 50)
end

T["compose: side by side, uneven heights, blank line between rows"] = function()
  local cells = layout.plan({ 1, 1, 2 }, 42, 2, 2)
  local out =
    compositor.compose(cells, { box("中文 A", 1), box("B", 3, "DbDashSeries1"), box("Wide", 0) })
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
  local long =
    { lines = { string.rep("x", 30) }, hl = { { row = 0, col_s = 5, col_e = 30, group = "G" } } }
  local out = compositor.compose(cells, { long, box("R", 0) })
  eq(out.lines[1], string.rep("x", 10) .. "  R")
  eq(out.hl[1], { row = 0, col_s = 5, col_e = 10, group = "G" })
  eq(out.hl[2], { row = 0, col_s = 12, col_e = 13, group = "DbDashTitle" })
end

local function T_(v, axis)
  return assert(layout.parse_tracks(v, axis or "rows"))
end

T["tracks: sizes, fr, auto, minmax, repeat, errors"] = function()
  eq(layout.parse_track(12, "columns"), { min = { "len", 12 }, max = { "len", 12 } })
  eq(layout.parse_track("25%", "columns"), { min = { "pct", 25 }, max = { "pct", 25 } })
  eq(layout.parse_track("2fr", "columns"), { min = { "len", 10 }, max = { "fr", 2 } })
  eq(layout.parse_track("2fr", "rows"), { min = "min", max = { "fr", 2 } })
  eq(layout.parse_track("auto", "rows"), { min = "min", max = "max" })
  eq(layout.parse_track("minmax(5, 1fr)", "rows"), { min = { "len", 5 }, max = { "fr", 1 } })
  eq(layout.parse_track("minmax(min-content, 20)", "rows"), { min = "min", max = { "len", 20 } })
  eq(#T_("repeat(3, 1fr) 30", "columns"), 4)
  eq(#T_({ "1fr", "repeat(2, 10)" }, "columns"), 3)
  eq(#T_(3, "columns"), 3)
  eq(select(2, layout.parse_track("25%", "rows")):find("invalid track") ~= nil, true)
  eq(select(2, layout.parse_track("minmax(1fr, 2)", "rows")):find("cannot be fr") ~= nil, true)
  eq(select(2, layout.parse_track("max-content", "columns")) ~= nil, true)
end

T["areas: rectangles, empty cells, errors"] = function()
  local a, n = layout.parse_areas({ "top top kpi", "tab . kpi" })
  eq(n, 3)
  eq(a.top, { row = 1, col = 1, row_span = 1, span = 2 })
  eq(a.kpi, { row = 1, col = 3, row_span = 2, span = 1 })
  eq(select(3, layout.parse_areas({ "a b", "a" })):find("has 1 cells") ~= nil, true)
  eq(select(3, layout.parse_areas({ "a b a" })):find("not a rectangle") ~= nil, true)
  eq(select(3, layout.parse_areas({ "a b", "b b" })):find('"b" is not a rectangle') ~= nil, true)
end

T["place: areas, explicit, row or column only, auto flow, errors"] = function()
  local areas = layout.parse_areas({ "a a b", "c . b" })
  local p =
    assert(layout.place({ { area = "b" }, {}, { row = 2, column = 1 }, { span = 2 } }, 3, areas))
  eq(p[1], { row = 1, col = 3, span = 1, row_span = 2 })
  eq(p[3], { row = 2, col = 1, span = 1, row_span = 1 })
  eq(p[2], { row = 1, col = 1, span = 1, row_span = 1 }) -- auto: the first free cell
  eq(p[4], { row = 3, col = 1, span = 2, row_span = 1 }) -- (2, 2) is free but the span does not fit
  p = assert(layout.place({ { column = 2, row_span = 2 }, { row = 1 }, {} }, 2, nil))
  eq({ p[1].row, p[1].col, p[2].row, p[2].col, p[3].row, p[3].col }, { 1, 2, 1, 1, 2, 1 })
  local _, err = layout.place({ { row = 1, column = 1 }, { row = 1, column = 1 } }, 2, nil)
  eq(err, { index = 2, field = "row", message = "overlaps panel 1" })
  _, err = layout.place({ { area = "zz" } }, 2, {})
  eq(err.message, 'no area named "zz" in grid-template-areas')
  _, err = layout.place({ { row = 1, column = 2, span = 2 } }, 2, nil)
  eq(err.field, "column")
end

T["columns: fixed, percent and fr share the width"] = function()
  local cols = layout.columns(T_({ 20, "25%", "1fr", "2fr" }, "columns"), 106, 2)
  eq(
    vim.tbl_map(function(c)
      return c.width
    end, cols),
    { 20, 25, 18, 37 }
  )
  eq(cols[2].x, 22)
  -- fr columns keep their minimum width (MIN_COL) on a narrow window
  cols = layout.columns(T_({ "1fr", "1fr" }, "columns"), 12, 2)
  eq({ cols[1].width, cols[2].width }, { 10, 10 })
end

T["rows: min-content first, auto grows to max-content, fr takes the rest, no squeeze"] = function()
  local items = {
    { row = 1, row_span = 1, hmin = 10, hmax = 20 },
    { row = 2, row_span = 1, hmin = 5, hmax = 5 },
  }
  local auto = T_({ "auto", "auto" })
  eq(layout.rows(auto, items, 15), { 10, 5 }) -- just fits
  eq(layout.rows(auto, items, 8), { 10, 5 }) -- too small: scrolls, nothing below min
  eq(layout.rows(auto, items, 20), { 15, 5 }) -- grows toward max-content
  eq(layout.rows(auto, items, 100), { 20, 5 }) -- capped at max-content
  local h, fill = layout.rows(T_({ "1fr", 7 }), items, 100)
  eq(h, { 93, 7 })
  eq(fill, { true, true })
  -- fr in proportion, auto rows first
  items[3] = { row = 3, row_span = 1, hmin = 2, hmax = 2 }
  eq(layout.rows(T_({ "1fr", "auto", "2fr" }), items, 50), { 15, 5, 30 })
  -- minmax with fixed bounds
  eq(layout.rows(T_({ "minmax(3, 12)", "auto", "auto" }), items, 100), { 12, 5, 2 })
end

T["rows: a panel spanning rows adds what they lack"] = function()
  local items = {
    { row = 1, row_span = 1, hmin = 4, hmax = 4 },
    { row = 2, row_span = 1, hmin = 4, hmax = 4 },
    { row = 1, row_span = 2, hmin = 15, hmax = 15 },
  }
  -- 4 + 4 + the gap line (1) = 9: 6 more lines, 3 to each row
  eq(layout.rows(T_({ "auto", "auto" }), items, 0), { 7, 7 })
  -- a fixed row keeps its size: the other row takes it all
  eq(layout.rows(T_({ 4, "auto" }), items, 0), { 4, 10 })
end

T["compose: cells at their lines, a panel across rows"] = function()
  local cells = {
    { x = 0, width = 6, y = 0, height = 2 },
    { x = 8, width = 6, y = 0, height = 5 },
    { x = 0, width = 6, y = 3, height = 2 },
  }
  local out = compositor.compose(cells, { box("A", 1), box("B", 4), box("C", 1) })
  eq(
    out.lines,
    { "A       B", "A line  B line", "        B line", "C       B line", "C line  B line" }
  )
  eq(out.regions[2], { row_s = 0, row_e = 4, x = 8, width = 6 })
end

return T
