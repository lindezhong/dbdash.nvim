-- Golden tests for every built-in chart style and canvas (design §11.5):
-- tests/golden/<type>/<renderer>[-<canvas>]/<case>.txt
local fx = require("tests.render.fixtures")
local helpers = require("tests.helpers")
local render = require("dbdash.render")
local resultset = require("dbdash.db.resultset")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local SIZE = { width = 72, height = 18 }

local function golden(show, rs, case)
  local renderer, canvas = require("dbdash.render.registry").resolve(show, {})
  local dir = show.type .. "/" .. renderer .. (renderer == "canvas" and ("-" .. canvas) or "")
  helpers.golden(dir .. "/" .. case, render.render(rs, show, SIZE))
end

local LINE = {
  type = "line",
  title = "Hourly visits",
  x_column = "hour",
  y_columns = { "visits", { column = "signups", label = "Signups" } },
}

for _, canvas in ipairs({ "braille", "quadrant", "block", "halfblock", "ascii" }) do
  T["line on " .. canvas] = function()
    golden(vim.tbl_extend("force", LINE, { canvas = canvas }), fx.hourly_visits(), "visits")
  end
end

T["line asciichart"] = function()
  golden(vim.tbl_extend("force", LINE, { renderer = "asciichart" }), fx.hourly_visits(), "visits")
end

T["line with axes, legend at bottom and fill"] = function()
  golden(vim.tbl_extend("force", LINE, {
    axes = { x_axis = { title = "hour" }, y_axis = { title = "count", min_value = 0, max_value = 200 } },
    legend = { position = "bottom" },
    line_style = { fill_area = true },
  }), fx.hourly_visits(), "options")
end

T["area stacked and overlapping"] = function()
  local show = { type = "area", x_column = "hour", y_columns = { "visits", "signups" } }
  golden(show, fx.hourly_visits(), "overlap")
  show.style = { stacked = true }
  golden(show, fx.hourly_visits(), "stacked")
end

T["scatter colored by category"] = function()
  golden({ type = "scatter", x_column = "revenue", y_column = "margin", color_column = "segment", colors = { Large = "#e74c3c" } }, fx.companies(), "segments")
  golden({ type = "scatter", x_column = "revenue", y_column = "margin", canvas = "quadrant" }, fx.companies(), "plain")
end

T["bubble sizes and labels"] = function()
  golden({ type = "bubble", x_column = "revenue", y_column = "margin", size_column = "size", color_column = "segment", label_column = "company" }, fx.companies(), "companies")
end

T["bar horizontal and vertical"] = function()
  local show = { type = "bar", title = "Headcount", x_column = "department", y_column = "headcount", style = { color = "blue", show_values = true } }
  golden(show, fx.departments(), "headcount")
  golden(vim.tbl_extend("force", show, { renderer = "vertical" }), fx.departments(), "headcount")
end

T["histogram horizontal and vertical"] = function()
  local show = { type = "histogram", value_column = "score", bins = 6 }
  golden(show, fx.scores(), "scores")
  golden(vim.tbl_extend("force", show, { renderer = "vertical" }), fx.scores(), "scores")
end

T["boxplot with outliers and means"] = function()
  golden({ type = "boxplot", category_column = "class", value_column = "score", style = { show_outliers = true, show_means = true } }, fx.scores(), "classes")
end

T["heatmap halfblock and block"] = function()
  local show = { type = "heatmap", x_column = "hour", y_column = "day", value_column = "activity" }
  golden(show, fx.activity(), "week")
  golden(vim.tbl_extend("force", show, { renderer = "block", style = { show_values = true } }), fx.activity(), "week")
end

T["pie as a proportional bar"] = function()
  golden({ type = "pie", title = "Headcount share", label_column = "department", value_column = "headcount", colors = { "#ff6b6b", "#4ecdc4", "#45b7d1", "#96ceb4" } }, fx.departments(), "departments")
end

T["pie as a circle"] = function()
  local show = { type = "pie", renderer = "circle", title = "Headcount share", label_column = "department", value_column = "headcount" }
  golden(show, fx.departments(), "departments")
  golden(vim.tbl_extend("force", show, { canvas = "quadrant" }), fx.departments(), "departments-quadrant")
end

T["missing columns are reported in place of the chart"] = function()
  local out = render.render(fx.hourly_visits(), { type = "line", x_column = "nope", y_column = "visits" }, SIZE)
  eq(out.lines[1], "column 'nope' (show.x_column) not found; available: hour, visits, signups")
  eq(out.hl[1].group, "DbDashError")
  out = render.render(fx.hourly_visits(), { type = "line", renderer = "fancy", x_column = "hour", y_column = "visits" }, SIZE)
  eq(out.lines[1]:find("unknown style 'chart/line/fancy' %(available: asciichart, canvas%)") ~= nil, true)
end

T["every chart fits the requested width"] = function()
  local W = require("dbdash.util.width")
  for _, w in ipairs({ 40, 72, 120 }) do
    for _, case in ipairs({
      { LINE, fx.hourly_visits() },
      { { type = "bar", x_column = "department", y_column = "headcount" }, fx.departments() },
      { { type = "boxplot", category_column = "class", value_column = "score" }, fx.scores() },
      { { type = "heatmap", x_column = "hour", y_column = "day", value_column = "activity" }, fx.activity() },
      { { type = "pie", label_column = "department", value_column = "headcount" }, fx.departments() },
      { { type = "pie", renderer = "circle", label_column = "department", value_column = "headcount" }, fx.departments() },
    }) do
      local out = render.render(case[2], case[1], { width = w, height = 20 })
      for _, l in ipairs(out.lines) do
        eq({ case[1].type, w, W.width(l) <= w }, { case[1].type, w, true })
      end
    end
  end
end

T["registry: custom styles and setup defaults"] = function()
  local registry = require("dbdash.render.registry")
  registry.register("chart/bar/mine", {
    render = function(rs)
      return { lines = { "mine: " .. rs.row_count }, hl = {} }
    end,
  })
  local out = render.render(fx.departments(), { type = "bar", renderer = "mine" }, SIZE)
  eq(out.lines, { "mine: 4" })
  eq({ registry.resolve({ type = "line" }, { line = { canvas = "quadrant" } }) }, { "canvas", "quadrant" })
  eq({ registry.resolve({ type = "line", canvas = "block" }, { line = { canvas = "quadrant" } }) }, { "canvas", "block" })
  eq(registry.names("chart/bar/"), { "horizontal", "mine", "vertical" })
end

T["nice ticks"] = function()
  local nice = require("dbdash.render.ticks.nice")
  eq({ nice.ticks(0, 150, 4) }, { { 0, 50, 100, 150 }, { "0", "50", "100", "150" } })
  eq({ nice.ticks(0, 1, 5) }, { { 0, 0.25, 0.5, 0.75, 1 }, { "0.00", "0.25", "0.50", "0.75", "1.00" } })
  eq({ nice.limits(3, 97, 5) }, { 0, 100, 20 })
  eq(select(2, nice.ticks(0, 3e6, 4))[2], "1M")
end

T["python format subset"] = function()
  local f = require("dbdash.render.format")
  eq(f.python(1234567.891, "{:,.0f}"), "1,234,568")
  eq(f.python(0.256, "{:.1%}"), "25.6%")
  eq(f.python(42, "{:d}"), "42")
  eq(f.python(1234.5, "{:,}"), "1,234.5")
  eq(f.python(1, "{:x}"), nil)
  -- text around the field, as in Python
  eq(f.python(42.4, "{:.0f}%"), "42%")
  eq(f.python(1234.5, "$ {:,.2f} USD"), "$ 1,234.50 USD")
  eq(f.python(3, "{} users"), "3 users")
end

-- xy options (Chart.js / ECharts) ------------------------------------------------------

local function xy(rows, show, cols)
  cols = cols or { { name = "x", type = "integer" }, { name = "y", type = "integer" } }
  show.x_column, show.y_column = show.x_column or "x", show.y_column or "y"
  local out = render.render(resultset.new(cols, rows), show, { width = 60, height = 14 })
  return out, table.concat(out.lines, "\n")
end

T["xy: series_column pivots long rows into series"] = function()
  local cols = { { name = "d", type = "string" }, { name = "s", type = "string" }, { name = "v", type = "integer" } }
  local _, text = xy({ { "a", "EU", 1 }, { "a", "US", 2 }, { "b", "EU", 3 }, { "b", "US", 1 } }, {
    type = "line",
    x_column = "d",
    y_column = "v",
    series_column = "s",
  }, cols)
  eq({ text:find("■ EU", 1, true) ~= nil, text:find("■ US", 1, true) ~= nil }, { true, true })
  local _, n = text:gsub("\n%s+a%s+b%s*$", "")
  eq(n, 1) -- the x axis has a and b once each
end

T["xy: point markers, mark_points, mark_lines labels"] = function()
  local rows = { { 1, 5 }, { 2, 9 }, { 3, 2 } }
  local _, text = xy(rows, { type = "line", line_style = { point = "●" }, mark_points = { "max", "min" } })
  local _, n = text:gsub("●", "")
  eq(n, 3)
  eq({ text:find("▲9", 1, true) ~= nil, text:find("▼2", 1, true) ~= nil }, { true, true })
  _, text = xy(rows, { type = "line", mark_lines = { { value = 7, label = "limit" }, { value = "mean" } } })
  eq({ text:find("limit", 1, true) ~= nil, text:find("mean 5.33", 1, true) ~= nil }, { true, true })
end

T["xy: log scale ticks are powers of ten"] = function()
  local _, text = xy({ { 1, 1 }, { 2, 1000 } }, { type = "line", axes = { y_axis = { scale = "log" } } })
  for _, label in ipairs({ "1000", "100", "10" }) do
    eq(text:find("\n%s*" .. label .. " [│┃]") ~= nil, true)
  end
end

T["xy: stepped lines, NULL gaps, percent stacking"] = function()
  local o1 = xy({ { 1, 1 }, { 2, 5 } }, { type = "line" })
  local o2 = xy({ { 1, 1 }, { 2, 5 } }, { type = "line", line_style = { stepped = "after" } })
  eq(table.concat(o1.lines) ~= table.concat(o2.lines), true)
  local cols = { { name = "x", type = "integer" }, { name = "y", type = "integer" } }
  local gap = xy({ { 1, 1 }, { 2, vim.NIL }, { 3, 1 } }, { type = "line", line_style = { span_gaps = false } }, cols)
  local joined = xy({ { 1, 1 }, { 2, vim.NIL }, { 3, 1 } }, { type = "line" }, cols)
  eq(table.concat(gap.lines) ~= table.concat(joined.lines), true)
  local pcols = { { name = "x", type = "integer" }, { name = "a", type = "integer" }, { name = "b", type = "integer" } }
  local _, text = xy({ { 1, 1, 3 }, { 2, 2, 2 } }, { type = "area", y_columns = { "a", "b" }, style = { stacked = "percent" } }, pcols)
  eq(text:find("100 │", 1, true) ~= nil, true)
end

T["xy: subtitle under the title"] = function()
  local out = xy({ { 1, 1 }, { 2, 2 } }, { type = "line", title = "T", subtitle = "sub" })
  eq({ vim.trim(out.lines[1]), vim.trim(out.lines[2]) }, { "T", "sub" })
end

-- stat ----------------------------------------------------------------------------------

local function stat_rs(v, typ)
  return require("dbdash.db.resultset").new(
    { { name = "label", type = "string" }, { name = "users", type = typ or "integer" } },
    v == nil and {} or { { "all", v } }
  )
end

local function stat(case, show, rs, opts)
  local out = render.render(rs, vim.tbl_extend("force", { type = "stat" }, show), vim.tbl_extend("force", SIZE, opts or {}))
  helpers.golden("stat/big/" .. case, out)
  return out
end

T["stat: big digits, change and sparkline"] = function()
  stat("up", { title = "Active users" }, stat_rs(1047), { history = { 880, 950, 900, 1000, 1047 } })
end

T["stat: decrease, first refresh, unchanged"] = function()
  stat("down", { title = "Errors" }, stat_rs(80), { history = { 100, 80 } })
  stat("first", { title = "Errors" }, stat_rs(80), { history = { 80 } })
  stat("same", { title = "Errors" }, stat_rs(80), { history = { 80, 80 } })
end

T["stat: format, unit, value_column, options off"] = function()
  stat("format_unit", { value_column = "users", format = "{:,.1f}", unit = "ms", delta = false, sparkline = false },
    stat_rs(1234.56, "number"))
end

T["stat: falls back to one line when narrow or not drawable"] = function()
  stat("narrow", { title = "Active users", format = "{:,}" }, stat_rs(1234567), { width = 20, history = { 1, 2 } })
  stat("text", { value_column = "label" }, stat_rs(5))
end

T["stat: no rows, unknown column"] = function()
  stat("empty", {}, stat_rs(nil))
  stat("bad_column", { value_column = "nope" }, stat_rs(1))
end

T["stat: values for the history"] = function()
  local C = require("dbdash.render.charts.stat.common")
  eq(C.track(stat_rs(5), {}), 5)
  eq(C.track(stat_rs("12.5", "decimal"), {}), 12.5)
  eq(C.track(stat_rs(5), { value_column = "label" }), nil)
  eq(C.delta({ 0, 5 }).text, "↑ 5")
  eq(C.sparkline({ 1, 2, 3, 4, 5, 6, 7, 8 }, 20), "▁▂▃▄▅▆▇█")
end

return T
