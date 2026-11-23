local fx = require("tests.render.fixtures")
local helpers = require("tests.helpers")
local render = require("dbdash.render")
local resultset = require("dbdash.db.resultset")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function out(rs, show, width)
  show.type = "table"
  return render.render(rs, show, { width = width or 80 })
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
      style = { header_style = "bold blue" },
    })
  )
end

T["golden: narrow window shrinks widest columns"] = function()
  helpers.golden("table/box/narrow", out(fx.departments(), {}, 40))
end

T["golden: no border, row lines"] = function()
  helpers.golden("table/box/no_border", out(fx.departments(), { style = { border = false } }))
  helpers.golden("table/box/show_lines", out(fx.departments(), { style = { show_lines = true } }))
end

T["golden: empty and truncated results"] = function()
  local rs = resultset.new({ { name = "a", type = "string" } }, {})
  helpers.golden("table/box/empty", out(rs, {}))
  rs = resultset.new({ { name = "n", type = "integer" } }, { { 1 }, { 2 } }, { truncated = true })
  helpers.golden("table/box/truncated", out(rs, {}))
end

T["false is shown as false, not NULL"] = function()
  local rs = resultset.new({ { name = "b", type = "boolean" } }, { { false }, { true }, { vim.NIL } })
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
  local hl = require("dbdash.render.highlight")
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

return T
