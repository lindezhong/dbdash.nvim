-- The CSS-like box around a chart (paint/box.lua) and the part styles (render/init.lua).
local box = require("dbdash.paint.box")
local render = require("dbdash.render")
local resultset = require("dbdash.db.resultset")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

---Box settings of a panel styled by `sheet` (selector -> properties).
local function settings(sheet)
  return box.settings(require("dbdash.css").scope(nil, nil, sheet))
end

local function content(...)
  return { lines = { ... }, hl = { { row = 0, col_s = 0, col_e = 1, group = "G" } } }
end

T["padding shorthand like CSS"] = function()
  eq(settings({ panel = { padding = 2 } }).pad, { 2, 2, 2, 2 })
  eq(settings({ panel = { padding = { 1, 3 } } }).pad, { 1, 3, 1, 3 })
  eq(settings({ panel = { padding = { 1, 2, 3 } } }).pad, { 1, 2, 3, 2 })
  eq(settings({ panel = { padding = { 1, 2, 3, 4 } } }).pad, { 1, 2, 3, 4 })
  eq(settings({}).pad, { 0, 0, 0, 0 })
end

T["wrap: padding and a border with the title in its top line"] = function()
  local s = settings({ panel = { border = "rounded", padding = { 0, 1 } } })
  local out = box.wrap(content("ab"), s, 12, nil, { text = "T", spans = { { 0, 1, "Title" } } })
  eq(
    out.lines,
    { "╭─ T ──────╮", "│ ab       │", "╰──────────╯" }
  )
  -- the content's highlight moved by the border and the padding
  local g = vim.tbl_filter(function(h)
    return h.group == "G"
  end, out.hl)[1]
  eq({ g.row, g.col_s, g.col_e }, { 1, #"│ ", #"│ " + 1 })
  -- panel-title { text-align: right }
  s = settings({ panel = { border = true }, ["panel-title"] = { ["text-align"] = "right" } })
  eq(
    box.wrap(content("x"), s, 12, nil, { text = "T", spans = {} }).lines[1],
    "┌────── T ─┐"
  )
end

T["wrap: an exact height pads the content; no box settings: unchanged"] = function()
  local s = settings({ panel = { border = "ascii" } })
  eq(box.wrap(content("a"), s, 5, 4).lines, { "+---+", "|a  |", "|   |", "+---+" })
  local c = content("a")
  eq(box.wrap(c, settings({}), 5, 4), c)
end

T["background: below everything, full width"] = function()
  local s = settings({ panel = { ["background-color"] = "#101010" } })
  local out = box.wrap(content("a"), s, 4)
  eq(out.lines, { "a   " })
  eq({ out.hl[1].priority, out.hl[1].col_e, out.full }, { 50, 4, true })
end

T["position: justify-self and align-self"] = function()
  local s = settings({ panel = { ["justify-self"] = "center", ["align-self"] = "end" } })
  local out = box.position(content("ab"), s, 10, 3)
  eq(out.lines, { "", "", "    ab" })
  eq(out.hl[1].col_s, 4)
  s = settings({ panel = { ["justify-self"] = "end" } })
  eq(box.position(content("ab"), s, 10).lines, { "        ab" })
end

T["part rules recolor values; a chart draws no title (its panel's)"] = function()
  local rs = resultset.new(
    { { name = "k", type = "string" }, { name = "v", type = "integer" } },
    { { "a", 1 }, { "b", 2 } }
  )
  local out = render.render(rs, {
    type = "bar",
    title = "Title",
    x_column = "k",
    y_column = "v",
  }, {
    width = 40,
    style = { value = { color = "Special" } },
  })
  local groups = {}
  for _, h in ipairs(out.hl) do
    groups[h.group] = true
  end
  eq({ groups.Special, groups.DbDashNumber }, { true, nil })
  eq(table.concat(out.lines, "\n"):find("Title", 1, true), nil)
end

T["plot border styles and hidden axes"] = function()
  local rs = resultset.new(
    { { name = "x", type = "integer" }, { name = "y", type = "integer" } },
    { { 1, 1 }, { 2, 4 } }
  )
  local show = { type = "line", x_column = "x", y_column = "y" }
  local out =
    render.render(rs, show, { width = 40, height = 12, style = { plot = { border = "double" } } })
  eq(out.lines[1]:find("╔", 1, true) ~= nil, true)
  out = render.render(
    rs,
    show,
    { width = 40, height = 12, style = { plot = { border = "none" }, axis = { display = "none" } } }
  )
  local text = table.concat(out.lines, "\n")
  eq({ text:find("┌", 1, true), text:find("4", 1, true) }, { nil, nil })
end

return T
