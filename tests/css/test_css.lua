-- The DOM and CSS layers: selectors, matching, cascade, inheritance, damage, highlight
-- groups, dirty tracking.
local dom = require("dbdash.dom.node")
local document = require("dbdash.dom.document")
local parser = require("dbdash.css.parser")
local match = require("dbdash.css.match")
local style = require("dbdash.css.style")
local hl = require("dbdash.css.hl")
local D = require("dbdash.css.properties").DAMAGE
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

---A small document: dashboard > panel#a.big > chart.bar > { axis, series.EU, series.US }
local function tree()
  local doc = document.new()
  local panel = doc.root:append(dom.new("panel", { id = "a", classes = { "big" } }))
  local chart = panel:append(dom.new("chart", { classes = { "bar" }, attrs = { type = "bar" } }))
  local axis = chart:append(dom.new("axis"))
  local eu = chart:append(dom.new("series", { classes = { "EU" }, attrs = { name = "EU" } }))
  local us = chart:append(dom.new("series", { classes = { "US" }, attrs = { name = "US" } }))
  return doc, { panel = panel, chart = chart, axis = axis, eu = eu, us = us }
end

local function sheet(t, keys)
  return assert(parser.sheet(t, keys))
end

T["selectors: parse, specificity, errors"] = function()
  local s = assert(parser.selector("panel#a.big chart[type=bar] series:nth-child(2)"))
  eq(#s.parts, 3)
  eq(s.specificity, { 1, 3, 3 })
  eq(assert(parser.selector("*")).specificity, { 0, 0, 0 })
  eq(#assert(parser.selector("chart::part(axis)")).parts, 2)
  eq(select(2, parser.selector("a:hover")):find("unknown pseudo%-class") ~= nil, true)
  eq(select(2, parser.selector("a[")):find("missing ']'") ~= nil, true)
  eq(select(2, parser.selector("a > b")):find("unexpected") ~= nil, true)
  local _, err = parser.sheet({ title = { colour = "red" } })
  assert(err)
  eq(err.key, "title")
  eq(err.message:find("unknown property 'colour'") ~= nil, true)
  _, err = parser.sheet({ title = { ["text-align"] = "middle" } })
  assert(err)
  eq(err.message:find("expected one of") ~= nil, true)
end

T["matching: tags, ids, classes, attributes, pseudo-classes, descendants"] = function()
  local _, n = tree()
  local function m(sel, node)
    return match.selector(assert(parser.selector(sel)), node)
  end
  eq(m("series", n.eu), true)
  eq(m("series.EU", n.us), false)
  eq(m("series[name=US]", n.us), true)
  eq(m('series[name="US"]', n.us), true)
  eq(m("series:first-child", n.eu), true)
  eq(m("series:last-child", n.us), true)
  eq(m("series:nth-child(even)", n.us), true)
  eq(m("series:nth-child(odd)", n.us), false)
  eq(m("series:nth-child(2)", n.us), true)
  eq(m("panel#a series", n.eu), true)
  eq(m("panel#b series", n.eu), false)
  eq(m("dashboard panel.big chart series", n.eu), true)
  eq(m("chart::part(axis)", n.axis), true)
  eq(m("*", n.axis), true)
end

T["cascade: origins, specificity, order; inheritance; inline scope"] = function()
  local doc, n = tree()
  doc:set_sheet("ua", sheet({ ["*"] = { color = "ua" }, axis = { color = "Comment" } }))
  doc:set_sheet("user", sheet({ panel = { color = "#111111" } }))
  doc:set_sheet(
    "author",
    sheet({ ["series.EU"] = { color = "#222222" }, series = { color = "#333333" } })
  )
  local c = style.get(n.eu)
  eq(c.color, "#222222") -- the class wins over the tag (same origin)
  eq(style.get(n.us).color, "#333333")
  -- user beats ua; the ua "*" rule still applies to chart, so it does not inherit
  eq(style.get(n.panel).color, "#111111")
  eq(style.get(n.chart).color, "ua")
  -- inheritance: font-weight is inherited, border is not
  doc:set_sheet("author", sheet({ panel = { ["font-weight"] = "bold", border = "rounded" } }))
  eq({ style.get(n.axis)["font-weight"], style.get(n.axis).border }, { "bold", "none" })
  -- an inline sheet only applies inside its scope; it beats author rules
  local other = doc.root:append(dom.new("panel", { id = "b" }))
  local oaxis = other:append(dom.new("axis"))
  doc:set_sheet("author", sheet({ ["#a axis"] = { color = "#444444" } }))
  doc:set_sheet("inline", sheet({ axis = { color = "#555555" } }), n.panel)
  eq(style.get(n.axis).color, "#555555")
  eq(style.get(oaxis).color, "Comment")
  -- runtime beats everything
  doc:set_sheet("runtime", sheet({ axis = { color = "#666666" } }))
  eq(style.get(n.axis).color, "#666666")
end

T["damage: by property, new nodes rebuild, only the dirty root restyles"] = function()
  local doc, n = tree()
  doc:set_sheet("author", sheet({ axis = { color = "#111111" } }))
  local stats = style.restyle(doc)
  eq(stats.damage, D.rebuild) -- every node is new
  eq(style.restyle(doc).nodes, 0) -- nothing dirty
  doc:set_sheet("author", sheet({ axis = { color = "#222222" } }))
  stats = style.restyle(doc)
  eq(stats.damage, D.repaint)
  eq(n.axis.style_data.damage, D.repaint)
  doc:set_sheet("author", sheet({ axis = { color = "#222222", padding = 1 } }))
  eq(style.restyle(doc).damage, D.relayout)
  doc:set_sheet("author", sheet({ axis = { color = "#222222", padding = 1, display = "none" } }))
  eq(style.restyle(doc).damage, D.rebuild)
  -- a class change restyles from that node only
  n.us:set_classes({ "US", "hot" })
  stats = style.restyle(doc)
  eq({ stats.root, stats.nodes }, { n.us, 1 })
  -- two dirty nodes: their common ancestor is the dirty root
  n.us:set_text("x")
  n.axis:set_text("y")
  eq(doc.dirty_root, n.chart)
  eq(n.panel.dirty_descendants, true)
  doc:take_dirty()
  eq(n.panel.dirty_descendants, false)
end

T["appending one by one restyles the new node and its previous sibling only"] = function()
  local doc = document.new("dashboard")
  doc:set_sheet(
    "author",
    sheet({
      ["row:nth-child(even)"] = { color = "#222222" },
      ["row:last-child"] = { ["font-weight"] = "bold" },
    })
  )
  local t = doc.root:append(dom.new("table"))
  style.restyle(doc)
  local restyled, rows = 0, {}
  for i = 1, 300 do
    rows[i] = t:append(dom.new("row"))
    style.get(rows[i]) -- a query after each insertion, as a renderer does
    restyled = restyled + doc.restyled.nodes
    doc.restyled = nil
  end
  eq({ restyled <= 2 * 300 + 2, restyled }, { true, restyled }) -- linear, not quadratic
  -- positions kept on insertion: :nth-child and :last-child stay right
  eq({ style.get(rows[2]).color, style.get(rows[3]).color }, { "#222222", nil })
  eq(
    { style.get(rows[299])["font-weight"], style.get(rows[300])["font-weight"] },
    { "normal", "bold" }
  )
  eq({ rows[300]:position() }, { 300, 300 })
end

T["highlight groups: a group as is, generated groups, refresh"] = function()
  vim.api.nvim_set_hl(0, "TestCssGroup", { fg = "#112233", bold = true })
  eq(
    hl.group({ color = "TestCssGroup", ["font-weight"] = "normal", ["text-decoration"] = "none" }),
    "TestCssGroup"
  )
  local g =
    hl.group({ color = "TestCssGroup", ["font-style"] = "italic", ["text-decoration"] = "none" })
  local a = vim.api.nvim_get_hl(0, { name = g })
  eq({ a.fg, a.bold, a.italic }, { 0x112233, true, true })
  g = hl.group({
    color = "#ff0000",
    ["background-color"] = "#000010",
    ["text-decoration"] = "underline",
  })
  a = vim.api.nvim_get_hl(0, { name = g })
  eq({ a.fg, a.bg, a.underline }, { 0xff0000, 0x10, true })
  eq(hl.group({ ["text-decoration"] = "none" }), nil)
  vim.cmd("hi clear")
  hl.refresh()
  eq(vim.api.nvim_get_hl(0, { name = g }).fg, 0xff0000)
end

return T
