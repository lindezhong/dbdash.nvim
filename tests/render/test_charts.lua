-- Golden tests for every built-in chart style and canvas (design §11.5):
-- tests/golden/<type>/<renderer>[-<canvas>]/<case>.txt
local fx = require("tests.render.fixtures")
local helpers = require("tests.helpers")
local render = require("dbdash.render")
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
end

return T
