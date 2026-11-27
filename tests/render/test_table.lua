local fx = require("tests.render.fixtures")
local helpers = require("tests.helpers")
local render = require("dbdash.render")
local resultset = require("dbdash.db.resultset")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

---Render a table; `style`: a style sheet for the chart (selector -> properties).
local function out(rs, show, width, style)
  show.type = "table"
  return render.render(rs, show, { width = width or 80, style = style })
end

T["golden: all columns"] = function()
  helpers.golden("table/box/all_columns", out(fx.departments(), { title = "Departments" }))
end

T["golden: column_list with alias and width"] = function()
  helpers.golden(
    "table/box/column_list",
    out(fx.departments(), {
      column_list = {
        { column = "department", alias = "部门", width = 10 },
        { column = "headcount", alias = "人数" },
        { column = "manager", alias = "Manager" },
        { column = "missing", alias = "Missing" },
      },
    }, nil, { header = { color = "blue", ["font-weight"] = "bold" } })
  )
end

T["golden: narrow window shrinks widest columns"] = function()
  helpers.golden("table/box/narrow", out(fx.departments(), {}, 40))
end

T["golden: no border, row lines"] = function()
  helpers.golden(
    "table/box/no_border",
    out(fx.departments(), {}, nil, { table = { border = "none" } })
  )
  helpers.golden(
    "table/box/show_lines",
    out(fx.departments(), {}, nil, { rule = { display = "block" } })
  )
end

T["golden: empty and truncated results"] = function()
  local rs = resultset.new({ { name = "a", type = "string" } }, {})
  helpers.golden("table/box/empty", out(rs, {}))
  rs = resultset.new({ { name = "n", type = "integer" } }, { { 1 }, { 2 } }, { truncated = true })
  helpers.golden("table/box/truncated", out(rs, {}))
end

T["false is shown as false, not NULL"] = function()
  local rs = resultset.new(
    { { name = "b", type = "boolean" } },
    { { false }, { true }, { vim.NIL } }
  )
  local text = table.concat(out(rs, {}).lines, "\n")
  eq({ text:find("false", 1, true) ~= nil, text:find("true", 1, true) ~= nil }, { true, true })
  local _, nulls = text:gsub("NULL", "")
  eq(nulls, 1)
end

T["every line fits the width and has the same display width"] = function()
  local o = out(fx.departments(), {}, 40)
  local W = require("dbdash.util.width")
  local w = W.width(o.lines[1])
  for _, l in ipairs(o.lines) do
    eq(W.width(l), w)
    eq(W.width(l) <= 40, true)
  end
end

T["values are formatted by type"] = function()
  local tbl = require("dbdash.render.table")
  eq(tbl.format_value(vim.NIL, "string", "NULL"), "NULL")
  eq(tbl.format_value("\1\255", "bytes", "NULL"), "\\x01ff")
  eq(tbl.format_value(1.5, "number", "NULL"), "1.5")
  eq(tbl.format_value(true, "boolean", "NULL"), "true")
  eq(tbl.format_value("a\nb", "string", "NULL"), "a↵b")
  eq(tbl.format_value({ 1, 2 }, "array", "NULL"), "[1,2]")
end

T["unknown chart types are reported in place of the chart"] = function()
  local o = render.render(fx.departments(), { type = "radar" }, { width = 80 })
  eq(o.lines[1]:find("unknown style 'chart/radar/canvas'", 1, true) ~= nil, true)
  eq(o.hl[1].group, "DbDashError")
end

T["highlight specs"] = function()
  local hl = require("dbdash.css.hl")
  eq(hl.parse("bold blue"), { bold = true, fg = "blue" })
  eq(hl.parse("#3498db on black"), { fg = "#3498db", bg = "black" })
  eq(hl.parse("bright_blue"), { fg = "lightblue" })
  eq(hl.parse("#abc"), { fg = "#aabbcc" })
  eq(select(2, hl.parse("sparkly")) ~= nil, true)
  eq(hl.color("Comment"), "Comment")
  local g = hl.color("bold #ff0000")
  eq(g, "DbDashC_bold_ff0000")
  eq(vim.api.nvim_get_hl(0, { name = g }).bold, true)
  eq(hl.color("sparkly", "DbDashHeader"), "DbDashHeader")
  vim.cmd("hi clear")
  hl.setup()
  eq(vim.api.nvim_get_hl(0, { name = g }).fg, 0xff0000)
end

T["long cells wrap; white-space: nowrap cuts; break-all; newlines"] = function()
  local rs = resultset.new(
    { { name = "k", type = "string" }, { name = "v", type = "string" } },
    { { "a", "the quick brown fox jumps" }, { "b", "x\ny" } }
  )
  local o = out(rs, {}, 20)
  eq(o.lines[4], "│ a │ the quick    │")
  eq(o.lines[5], "│   │ brown fox    │")
  eq(o.lines[6], "│   │ jumps        │")
  eq(o.lines[7], "│ b │ x            │")
  eq(o.lines[8], "│   │ y            │")
  o = out(rs, {}, 20, { cell = { ["white-space"] = "nowrap" } })
  eq(o.lines[4], "│ a │ the quick b… │")
  eq(o.lines[5], "│ b │ x↵y          │")
  o = out(rs, {}, 20, { cell = { ["word-break"] = "break-all" } })
  eq(o.lines[4], "│ a │ the quick br │")
end

T["cell width and height: column_list and cell { width, height }"] = function()
  local rs = resultset.new({ { name = "v", type = "string" } }, { { "one two three four five" } })
  local o = out(rs, { column_list = { { column = "v", width = 7, height = 2 } } })
  eq(
    { o.lines[4], o.lines[5], o.lines[6] },
    { "│ one two │", "│ three…  │", "└─────────┘" }
  )
  o = out(rs, {}, nil, { cell = { width = 9, height = 1 } })
  eq(
    { o.lines[4], o.lines[5] },
    { "│ one two…  │", "└───────────┘" }
  )
end

T["a wrapped row keeps its colors on every line"] = function()
  local rs = resultset.new(
    { { name = "n", type = "integer" }, { name = "t", type = "string" } },
    { { 9, "aa bb" } }
  )
  local o = out(rs, {
    column_list = {
      { column = "n", thresholds = { { value = 5, class = "hot" } } },
      { column = "t", width = 2 },
    },
  }, nil, { ["cell.hot"] = { color = "#ff0000" } })
  local rows = {}
  for _, h in ipairs(o.hl) do
    if h.group:match("^DbDashCss_") then
      rows[h.row] = true
    end
  end
  eq({ rows[3], rows[4] }, { true, true })
end

T["CSS: border styles, padding, align, vertical-align, stripes, text-overflow"] = function()
  local rs = resultset.new(
    { { name = "k", type = "string" }, { name = "n", type = "integer" } },
    { { "a", 1 }, { "bb", 22 } }
  )
  local o = out(rs, {}, nil, { table = { border = "rounded" } })
  eq({ o.lines[1], o.lines[3], o.lines[6] }, {
    "╭────┬────╮",
    "├────┼────┤",
    "╰────┴────╯",
  })
  o = out(rs, {}, nil, { table = { border = "ascii" }, cell = { padding = 0 } })
  eq({ o.lines[1], o.lines[2], o.lines[4] }, { "+--+--+", "|k | n|", "|a | 1|" })
  o = out(rs, {}, nil, { table = { border = "none" } })
  eq(o.lines[1], "k    n")
  o = out(rs, {
    column_list = {
      { column = "k", align = "right" },
      { column = "n", align = "center", width = 5 },
    },
  })
  eq(o.lines[4], "│  a │   1   │")
  -- vertical_align: the short cell sits in the middle of a three-line row
  rs = resultset.new(
    { { name = "a", type = "string" }, { name = "b", type = "string" } },
    { { "x", "one two three" } }
  )
  o = out(
    rs,
    { column_list = { "a", { column = "b", width = 5 } } },
    nil,
    { cell = { ["vertical-align"] = "middle" } }
  )
  eq(
    { o.lines[4], o.lines[5], o.lines[6] },
    { "│   │ one   │", "│ x │ two   │", "│   │ three │" }
  )
  -- text-overflow
  o = out(
    rs,
    { column_list = { "a", { column = "b", width = 6 } } },
    nil,
    { cell = { ["white-space"] = "nowrap", ["text-overflow"] = "..." } }
  )
  eq(o.lines[4], "│ x │ one... │")
  -- stripes: even rows get a background below the other colors
  rs = resultset.new({ { name = "a", type = "integer" } }, { { 1 }, { 2 } })
  o = out(rs, {}, nil, { ["row:nth-child(even)"] = { ["background-color"] = "#202020" } })
  local bg = vim.tbl_filter(function(h)
    return h.priority == 50
  end, o.hl)
  eq(#bg, 1)
  eq(bg[1].row, 4)
end

T["DataTables-like: sort, rows shown, column format and color, row thresholds, caption"] = function()
  local rs = resultset.new(
    { { name = "k", type = "string" }, { name = "n", type = "number" } },
    { { "a", 1234.5 }, { "b", vim.NIL }, { "c", 99 } }
  )
  local o = out(rs, { sort = { column = "n", order = "desc" } })
  eq(
    { o.lines[4]:sub(1, 6), o.lines[5]:sub(1, 6), o.lines[6]:sub(1, 6) },
    { "│ a ", "│ c ", "│ b " }
  )
  o = out(rs, { sort = "k" }, nil, { table = { ["line-clamp"] = 1 } })
  eq(o.lines[#o.lines], "… 2 more rows (table line-clamp)")
  o = out(
    rs,
    { column_list = { "k", { column = "n", format = "{:,.1f}" } } },
    nil,
    { ["cell[column=n]"] = { color = "Special" } }
  )
  eq(o.lines[4], "│ a │ 1,234.5 │")
  local special = vim.tbl_filter(function(h)
    return h.group == "Special"
  end, o.hl)
  -- every cell of the column, the NULL one too: an author rule wins over the default
  -- sheet's cell.null (the cascade, as in a browser)
  eq(#special, 3)
  o = out(rs, { row_thresholds = { column = "n", steps = { { value = 1000, class = "danger" } } } })
  local red = vim.tbl_filter(function(h)
    return h.row == 3 and h.group == "DiagnosticError"
  end, o.hl)
  eq(#red, 2) -- both cells of the row with 1234.5
  o = out(rs, { title = "T" }, nil, { title = { ["caption-side"] = "bottom" } })
  eq(vim.trim(o.lines[#o.lines]), "T")
end

return T
