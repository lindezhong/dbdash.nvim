-- Golden tests for every built-in chart style and canvas (design §11.5):
-- tests/golden/<type>/<renderer>[-<canvas>]/<case>.txt
local fx = require("tests.render.fixtures")
local helpers = require("tests.helpers")
local render = require("dbdash.render")
local resultset = require("dbdash.db.resultset")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local SIZE = { width = 72, height = 18 }

---Golden output of a chart styled by `style` (selector -> properties; chart { renderer,
---canvas } picks the renderer).
local function golden(show, rs, case, style)
  local renderer, canvas = require("dbdash.render.registry").resolve(show.type, (style or {}).chart)
  local dir = show.type .. "/" .. renderer .. (renderer == "canvas" and ("-" .. canvas) or "")
  helpers.golden(
    dir .. "/" .. case,
    render.render(rs, show, vim.tbl_extend("force", SIZE, { style = style }))
  )
end

---The chart element's renderer / canvas as a style sheet.
local function chart(renderer, canvas)
  return { chart = { renderer = renderer, canvas = canvas } }
end

local LINE = {
  type = "line",
  title = "Hourly visits",
  x_column = "hour",
  y_columns = { "visits", { column = "signups", label = "Signups" } },
}

for _, canvas in ipairs({ "braille", "quadrant", "block", "halfblock", "ascii" }) do
  T["line on " .. canvas] = function()
    golden(LINE, fx.hourly_visits(), "visits", chart(nil, canvas))
  end
end

T["line asciichart"] = function()
  golden(LINE, fx.hourly_visits(), "visits", chart("asciichart"))
end

T["line with axes, legend at bottom and fill"] = function()
  golden(
    vim.tbl_extend("force", LINE, {
      axes = {
        x_axis = { title = "hour" },
        y_axis = { title = "count", min_value = 0, max_value = 200 },
      },
    }),
    fx.hourly_visits(),
    "options",
    { legend = { position = "bottom" }, series = { fill = true } }
  )
end

T["area stacked and overlapping"] = function()
  local show = { type = "area", x_column = "hour", y_columns = { "visits", "signups" } }
  golden(show, fx.hourly_visits(), "overlap")
  show.stacked = true
  golden(show, fx.hourly_visits(), "stacked")
end

T["scatter colored by category"] = function()
  golden(
    { type = "scatter", x_column = "revenue", y_column = "margin", color_column = "segment" },
    fx.companies(),
    "segments",
    { ["series.Large"] = { color = "#e74c3c" } }
  )
  golden(
    { type = "scatter", x_column = "revenue", y_column = "margin" },
    fx.companies(),
    "plain",
    chart(nil, "quadrant")
  )
end

T["bubble sizes and labels"] = function()
  golden({
    type = "bubble",
    x_column = "revenue",
    y_column = "margin",
    size_column = "size",
    color_column = "segment",
    label_column = "company",
  }, fx.companies(), "companies")
end

T["bar horizontal and vertical"] = function()
  local show =
    { type = "bar", title = "Headcount", x_column = "department", y_column = "headcount" }
  golden(show, fx.departments(), "headcount", { series = { color = "blue" } })
  golden(
    show,
    fx.departments(),
    "headcount",
    { series = { color = "blue" }, chart = { renderer = "vertical" } }
  )
end

T["histogram horizontal and vertical"] = function()
  local show = { type = "histogram", value_column = "score", bins = 6 }
  golden(show, fx.scores(), "scores")
  golden(show, fx.scores(), "scores", chart("vertical"))
end

T["boxplot with outliers and means"] = function()
  golden(
    { type = "boxplot", category_column = "class", value_column = "score" },
    fx.scores(),
    "classes",
    { mean = { display = "block" } }
  )
end

T["heatmap halfblock and block"] = function()
  local show = { type = "heatmap", x_column = "hour", y_column = "day", value_column = "activity" }
  golden(show, fx.activity(), "week")
  golden(
    show,
    fx.activity(),
    "week",
    { chart = { renderer = "block" }, value = { display = "block" } }
  )
end

T["pie as a proportional bar"] = function()
  golden(
    {
      type = "pie",
      title = "Headcount share",
      label_column = "department",
      value_column = "headcount",
    },
    fx.departments(),
    "departments",
    {
      ["series:nth-child(1)"] = { color = "#ff6b6b" },
      ["series:nth-child(2)"] = { color = "#4ecdc4" },
      ["series:nth-child(3)"] = { color = "#45b7d1" },
      ["series:nth-child(4)"] = { color = "#96ceb4" },
    }
  )
end

T["pie as a circle"] = function()
  local show = {
    type = "pie",
    title = "Headcount share",
    label_column = "department",
    value_column = "headcount",
  }
  golden(show, fx.departments(), "departments", chart("circle"))
  golden(show, fx.departments(), "departments-quadrant", chart("circle", "quadrant"))
end

T["missing columns are reported in place of the chart"] = function()
  local out = render.render(
    fx.hourly_visits(),
    { type = "line", x_column = "nope", y_column = "visits" },
    SIZE
  )
  eq(out.lines[1], "column 'nope' (show.x_column) not found; available: hour, visits, signups")
  eq(out.hl[1].group, "DbDashError")
  out = render.render(
    fx.hourly_visits(),
    { type = "line", x_column = "hour", y_column = "visits" },
    vim.tbl_extend("force", SIZE, { style = chart("fancy") })
  )
  eq(
    out.lines[1]:find("unknown style 'chart/line/fancy' %(available: asciichart, canvas%)") ~= nil,
    true
  )
end

T["every chart fits the requested width"] = function()
  local W = require("dbdash.util.width")
  for _, w in ipairs({ 40, 72, 120 }) do
    for _, case in ipairs({
      { LINE, fx.hourly_visits() },
      { { type = "bar", x_column = "department", y_column = "headcount" }, fx.departments() },
      { { type = "boxplot", category_column = "class", value_column = "score" }, fx.scores() },
      {
        { type = "heatmap", x_column = "hour", y_column = "day", value_column = "activity" },
        fx.activity(),
      },
      {
        { type = "pie", label_column = "department", value_column = "headcount" },
        fx.departments(),
      },
      {
        { type = "pie", label_column = "department", value_column = "headcount" },
        fx.departments(),
        chart("circle"),
      },
    }) do
      local out = render.render(case[2], case[1], { width = w, height = 20, style = case[3] })
      for _, l in ipairs(out.lines) do
        eq({ case[1].type, w, W.width(l) <= w }, { case[1].type, w, true })
      end
    end
  end
end

T["registry: an implementation missing what its category needs is a clear error"] = function()
  local registry = require("dbdash.render.registry")
  local function err(name, impl)
    local ok, e = pcall(registry.register, name, impl)
    eq(ok, false)
    return e
  end
  eq(err("chart/bar/x", {}), "chart/bar/x needs render (a function)")
  eq(err("chart/bar/x", function() end), "chart/bar/x must be a table, not a function")
  eq(err("palette/p", { colors = {} }), "palette/p needs color (a function)")
  eq(err("ticks/t", { ticks = function() end }), "ticks/t needs limits (a function)")
  eq(err("mine", {}):match("^registry names are category/name") ~= nil, true)
end

T["registry: custom renderers; renderer and canvas from computed styles"] = function()
  local registry = require("dbdash.render.registry")
  registry.register("chart/bar/mine", {
    render = function(rs)
      return { lines = { "mine: " .. rs.row_count }, hl = {} }
    end,
  })
  local out = render.render(
    fx.departments(),
    { type = "bar" },
    vim.tbl_extend("force", SIZE, { style = chart("mine") })
  )
  eq(out.lines, { "mine: 4" })
  eq({ registry.resolve("line", {}) }, { "canvas", "braille" })
  eq({ registry.resolve("line", { canvas = "quadrant" }) }, { "canvas", "quadrant" })
  eq({ registry.resolve("pie", {}) }, { "bar", "braille" })
  -- setup({ style }) is the user sheet: below a dashboard's own rules
  require("dbdash").setup({ style = { ["chart.line"] = { canvas = "block" } } })
  out = render.render(fx.hourly_visits(), LINE, SIZE)
  eq(table.concat(out.lines):find("█", 1, true) ~= nil, true)
  require("dbdash").setup({})
  eq(registry.names("chart/bar/"), { "horizontal", "mine", "vertical" })
end

T["per-item selectors: one bar, one legend item"] = function()
  local rs = resultset.new(
    { { name = "k", type = "string" }, { name = "v", type = "integer" } },
    { { "Books", 2 }, { "Food", 7 } }
  )
  local out = render.render(rs, { type = "bar", x_column = "k", y_column = "v" }, {
    width = 50,
    height = 10,
    style = {
      ["bar[category=Books]"] = { color = "Special" },
      ["bar[category=Food] value"] = { display = "none" },
    },
  })
  local special = vim.tbl_filter(function(h)
    return h.group == "Special"
  end, out.hl)
  eq(#special, 1) -- the Books bar only
  eq(table.concat(out.lines, "\n"):find(" 7", 1, true), nil) -- Food's value hidden
  rs = resultset.new(
    { { name = "l", type = "string" }, { name = "v", type = "integer" } },
    { { "a", 5 }, { "b", 3 }, { "c", 2 } }
  )
  out = render.render(rs, { type = "pie", label_column = "l", value_column = "v" }, {
    width = 50,
    height = 10,
    style = { ["legend-item:nth-child(2) label"] = { color = "Special" } },
  })
  special = vim.tbl_filter(function(h)
    return h.group == "Special"
  end, out.hl)
  eq(#special, 1)
  eq(out.lines[special[1].row + 1]:find("b", 1, true) ~= nil, true)
end

T["nice ticks"] = function()
  local nice = require("dbdash.render.ticks.nice")
  eq({ nice.ticks(0, 150, 4) }, { { 0, 50, 100, 150 }, { "0", "50", "100", "150" } })
  eq(
    { nice.ticks(0, 1, 5) },
    { { 0, 0.25, 0.5, 0.75, 1 }, { "0.00", "0.25", "0.50", "0.75", "1.00" } }
  )
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

local function xy(rows, show, cols, style)
  cols = cols or { { name = "x", type = "integer" }, { name = "y", type = "integer" } }
  show.x_column, show.y_column = show.x_column or "x", show.y_column or "y"
  local out =
    render.render(resultset.new(cols, rows), show, { width = 60, height = 14, style = style })
  return out, table.concat(out.lines, "\n")
end

T["xy: series_column pivots long rows into series"] = function()
  local cols = {
    { name = "d", type = "string" },
    { name = "s", type = "string" },
    { name = "v", type = "integer" },
  }
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
  local _, text = xy(
    rows,
    { type = "line", mark_points = { "max", "min" } },
    nil,
    { point = { display = "block", content = "●" } }
  )
  local _, n = text:gsub("●", "")
  eq(n, 3)
  eq({ text:find("▲9", 1, true) ~= nil, text:find("▼2", 1, true) ~= nil }, { true, true })
  _, text =
    xy(rows, { type = "line", mark_lines = { { value = 7, label = "limit" }, { value = "mean" } } })
  eq({ text:find("limit", 1, true) ~= nil, text:find("mean 5.33", 1, true) ~= nil }, { true, true })
end

T["xy: log scale ticks are powers of ten"] = function()
  local _, text = xy(
    { { 1, 1 }, { 2, 1000 } },
    { type = "line", axes = { y_axis = { scale = "log" } } }
  )
  for _, label in ipairs({ "1000", "100", "10" }) do
    eq(text:find("\n%s*" .. label .. " [│┃]") ~= nil, true)
  end
end

T["xy: stepped lines, NULL gaps, percent stacking"] = function()
  local o1 = xy({ { 1, 1 }, { 2, 5 } }, { type = "line" })
  local o2 = xy(
    { { 1, 1 }, { 2, 5 } },
    { type = "line" },
    nil,
    { series = { curve = "step-after" } }
  )
  eq(table.concat(o1.lines) ~= table.concat(o2.lines), true)
  local cols = { { name = "x", type = "integer" }, { name = "y", type = "integer" } }
  local gap = xy({ { 1, 1 }, { 2, vim.NIL }, { 3, 1 } }, { type = "line", span_gaps = false }, cols)
  local joined = xy({ { 1, 1 }, { 2, vim.NIL }, { 3, 1 } }, { type = "line" }, cols)
  eq(table.concat(gap.lines) ~= table.concat(joined.lines), true)
  local pcols = {
    { name = "x", type = "integer" },
    { name = "a", type = "integer" },
    { name = "b", type = "integer" },
  }
  local _, text = xy(
    { { 1, 1, 3 }, { 2, 2, 2 } },
    { type = "area", y_columns = { "a", "b" }, stacked = "percent" },
    pcols
  )
  eq(text:find("100 │", 1, true) ~= nil, true)
end

T["xy: no title or subtitle (they are the panel's)"] = function()
  local out = xy({ { 1, 1 }, { 2, 2 } }, { type = "line", title = "Title", subtitle = "Sub" })
  local text = table.concat(out.lines, "\n")
  eq({ text:find("Title", 1, true), text:find("Sub", 1, true) }, { nil, nil })
end

-- bar and histogram options -------------------------------------------------------------

local function bar_rs()
  return resultset.new({
    { name = "c", type = "string" },
    { name = "a", type = "integer" },
    { name = "b", type = "integer" },
  }, { { "x", 5, 1 }, { "y", 9, 2 }, { "z", 2, 7 } })
end

local function text_of(out)
  return table.concat(out.lines, "\n")
end

T["bar: grouped and stacked series, legend"] = function()
  local show = { type = "bar", x_column = "c", y_columns = { "a", "b" } }
  local text = text_of(render.render(bar_rs(), show, { width = 60, height = 20 }))
  eq({ text:find("■ a", 1, true) ~= nil, text:find("■ b", 1, true) ~= nil }, { true, true })
  local _, n = text:gsub("│■", "")
  eq(n, 6) -- one line per series and category
  show.stacked = true
  text = text_of(render.render(bar_rs(), show, { width = 60, height = 20 }))
  -- totals
  eq({ text:find("■ 6 ", 1, true) ~= nil, text:find("■ 11", 1, true) ~= nil }, { true, true })
end

T["bar: sort, top, inside values, mark_lines labels"] = function()
  local show = { type = "bar", x_column = "c", y_column = "a", sort = "desc", top = 2 }
  local out = render.render(bar_rs(), show, { width = 50, height = 10 })
  eq({ vim.trim(out.lines[2]):sub(1, 1), vim.trim(out.lines[3]):sub(1, 1) }, { "y", "x" })
  eq(text_of(out):find("z", 1, true), nil)
  show.mark_lines = { { value = 4, label = "four" } }
  eq(
    text_of(render.render(bar_rs(), show, { width = 50, height = 10 })):find("four", 1, true) ~= nil,
    true
  )
  show = { type = "bar", x_column = "c", y_column = "a", mark_lines = { { value = "mean" } } }
  eq(
    text_of(render.render(bar_rs(), show, { width = 50, height = 12, style = chart("vertical") })):find(
      "mean 5.33",
      1,
      true
    ) ~= nil,
    true
  )
end

T["histogram: bin_width, bin_range, cumulative, percent"] = function()
  local rows = {}
  for i = 1, 10 do
    rows[i] = { i * 10 - 5 }
  end
  local rs = resultset.new({ { name = "v", type = "integer" } }, rows)
  local B = require("dbdash.render.charts.lib.bars")
  local bins = B.histogram(
    rs,
    { value_column = "v", bin_width = 25, bin_range = { 0, 100 } },
    render.ctx({ width = 40 })
  )
  eq(
    vim.tbl_map(function(b)
      return b.value
    end, bins),
    { 2, 3, 2, 3 }
  )
  bins = B.histogram(rs, {
    value_column = "v",
    bin_width = 25,
    bin_range = { 0, 100 },
    cumulative = true,
    normalize = "percent",
  }, render.ctx({ width = 40 }))
  eq(bins[#bins].value, 100)
end

-- boxplot, heatmap, pie, stat and text options -------------------------------------------

T["boxplot: whiskers, values, vertical renderer"] = function()
  local B = require("dbdash.render.charts.boxplot.boxdraw")
  local vals = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 100 }
  eq(#B.stats(vim.deepcopy(vals)).outliers, 1)
  eq(#B.stats(vim.deepcopy(vals), "minmax").outliers, 0)
  eq(B.stats(vim.deepcopy(vals), "minmax").whi, 100)
  local rows = vim.tbl_map(function(v)
    return { v }
  end, vals)
  local rs = resultset.new({ { name = "v", type = "integer" } }, rows)
  local text = text_of(
    render.render(
      rs,
      { type = "boxplot", value_column = "v" },
      { width = 60, height = 12, style = { value = { display = "block" } } }
    )
  )
  eq(text:find("5.5", 1, true) ~= nil, true) -- the median under the box
  text = text_of(
    render.render(
      rs,
      { type = "boxplot", value_column = "v" },
      { width = 40, height = 14, style = chart("vertical") }
    )
  )
  eq({ text:find("┌", 1, true) ~= nil, text:find("├", 1, true) ~= nil }, { true, true })
end

T["heatmap: color-steps, scale range, legend off"] = function()
  local rs = resultset.new({
    { name = "x", type = "string" },
    { name = "y", type = "string" },
    { name = "v", type = "integer" },
  }, { { "a", "r", 1 }, { "b", "r", 50 }, { "a", "s", 90 }, { "b", "s", 10 } })
  local show = { type = "heatmap", x_column = "x", y_column = "y", value_column = "v" }
  local text = text_of(render.render(rs, show, {
    width = 40,
    height = 10,
    style = {
      chart = {
        ["color-steps"] = {
          { value = 0, color = "#00ff00" },
          { value = 60, color = "#ff0000" },
        },
      },
    },
  }))
  eq({ text:find("≥0", 1, true) ~= nil, text:find("≥60", 1, true) ~= nil }, { true, true })
  show = {
    type = "heatmap",
    x_column = "x",
    y_column = "y",
    value_column = "v",
    scale_min = 0,
    scale_max = 200,
  }
  text = text_of(render.render(rs, show, {
    width = 40,
    height = 10,
    style = {
      legend = { display = "none" },
      chart = { ["color-scale"] = { "#000000", "#ffffff" } },
    },
  }))
  eq(text:find("200", 1, true), nil) -- no legend
end

T["pie: top + Other, hole total, half, legend off, format"] = function()
  local rs = resultset.new(
    { { name = "l", type = "string" }, { name = "v", type = "integer" } },
    { { "a", 50 }, { "b", 30 }, { "c", 15 }, { "d", 5 } }
  )
  local text = text_of(render.render(rs, {
    type = "pie",
    label_column = "l",
    value_column = "v",
    format = "{} u",
    sort = "asc",
    top = 2,
  }, { width = 50, height = 12 }))
  eq({
    text:find("Other", 1, true) ~= nil,
    text:find("80 u", 1, true) ~= nil,
    text:find("■ d", 1, true) ~= nil,
  }, { true, true, true })
  local pie = { type = "pie", label_column = "l", value_column = "v" }
  text = text_of(
    render.render(
      rs,
      pie,
      { width = 60, height = 14, style = { chart = { renderer = "circle", hole = 0.6 } } }
    )
  )
  eq(text:find("100", 1, true) ~= nil, true)
  local full = render.render(rs, pie, {
    width = 60,
    height = 14,
    style = { chart = { renderer = "circle" }, legend = { display = "none" } },
  })
  local half = render.render(rs, pie, {
    width = 60,
    height = 14,
    style = { chart = { renderer = "circle", angle = 180 }, legend = { display = "none" } },
  })
  eq(#half.lines < #full.lines, true)
  eq(text_of(full):find("■", 1, true), nil)
end

T["stat: reduce, prefix, label, delta_mode, several values"] = function()
  local rs = resultset.new(
    { { name = "a", type = "integer" }, { name = "b", type = "integer" } },
    { { 10, 1 }, { 30, 2 } }
  )
  local C = require("dbdash.render.charts.stat.common")
  for reduce, want in pairs({
    first = 10,
    last = 30,
    sum = 40,
    mean = 20,
    min = 10,
    max = 30,
    count = 2,
  }) do
    eq({ reduce, C.value(rs, { reduce = reduce }) }, { reduce, want })
  end
  eq(C.delta({ 10, 15 }, "absolute").text, "↑ 5")
  local normal = { value = { ["font-size"] = "normal" } }
  local out = render.render(
    rs,
    { type = "stat", prefix = "$", label = "total", reduce = "sum" },
    { width = 40, height = 8, style = normal }
  )
  eq({ out.lines[1], out.lines[2] }, { "$40", "total" })
  local text = text_of(
    render.render(
      rs,
      { type = "stat", value_columns = { "a", { column = "b", label = "bee" } } },
      { width = 40, height = 8, style = normal }
    )
  )
  eq(text:find("bee", 1, true) ~= nil, true)
end

T["text: text-align, line numbers, line-clamp, highlight classes, reverse"] = function()
  local rs = resultset.new(
    { { name = "l", type = "string" } },
    { { "INFO up" }, { "ERROR down" }, { "INFO ok" } }
  )
  local out = render.render(
    rs,
    { type = "text", reverse = true, highlight = { { pattern = "ERROR", class = "bad" } } },
    {
      width = 30,
      height = 8,
      style = {
        ["line-number"] = { display = "block" },
        chart = { ["line-clamp"] = 2 },
        ["line.bad"] = { color = "Error" },
      },
    }
  )
  eq(
    { out.lines[1], out.lines[2], out.lines[3] },
    { "1 INFO ok", "2 ERROR down", "… 1 more lines (chart line-clamp)" }
  )
  eq(
    vim.tbl_filter(function(h)
      return h.group == "Error"
    end, out.hl)[1].row,
    1
  )
  out = render.render(
    rs,
    { type = "text" },
    { width = 30, height = 8, style = { line = { ["text-align"] = "right" } } }
  )
  eq(#out.lines[1], 30)
end

-- stat ----------------------------------------------------------------------------------

local function stat_rs(v, typ)
  return require("dbdash.db.resultset").new(
    { { name = "label", type = "string" }, { name = "users", type = typ or "integer" } },
    v == nil and {} or { { "all", v } }
  )
end

local function stat(case, show, rs, opts, style)
  local out = render.render(
    rs,
    vim.tbl_extend("force", { type = "stat" }, show),
    vim.tbl_extend("force", SIZE, opts or {}, { style = style })
  )
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
  stat(
    "format_unit",
    { value_column = "users", format = "{:,.1f}", unit = "ms" },
    stat_rs(1234.56, "number"),
    nil,
    {
      delta = { display = "none" },
      sparkline = { display = "none" },
    }
  )
end

T["stat: falls back to one line when narrow or not drawable"] = function()
  stat(
    "narrow",
    { title = "Active users", format = "{:,}" },
    stat_rs(1234567),
    { width = 20, history = { 1, 2 } }
  )
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
