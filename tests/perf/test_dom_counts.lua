-- Counts of the charts' DOM (dom/content): elements and restyles grow linearly with the
-- data, a new result of the same shape reuses every element (and restyles only those
-- whose classes changed), and styles are shared, not computed per element.
local H = require("tests.perf.helpers")
local content = require("dbdash.dom.content")
local style = require("dbdash.css.style")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function count(node)
  local n = 0
  node:walk(function()
    n = n + 1
  end)
  return n
end

---Build a chart's DOM of `size` into a fresh document and style it.
---@return dbdash.dom.Document doc, dbdash.dom.Node chart, table restyled
local function built(kind, size, seed)
  local doc, chart = H.chart(kind)
  doc.restyled = nil
  local rs, show = H.SCENARIOS[kind](size, seed or 0)
  content.build(chart, rs, show)
  style.restyle(doc)
  local r = doc.restyled
  doc.restyled = nil
  return doc, chart, r
end

-- kinds with a content DOM so far, and the elements per item
local KINDS = { table = 8, text = 1 } -- a row and its 6 cells (+ header), a line

for kind, per in pairs(KINDS) do
  T[kind .. ": elements and restyles grow linearly"] = function()
    local _, small, rs1 = built(kind, 100)
    local _, large, rs2 = built(kind, 1000)
    local n1, n2 = count(small), count(large)
    -- about `per` elements per item, and 10 x the items: 10 x the elements (± 10%)
    eq({ kind, n2 >= 1000 * (per - 1), n2 / n1 > 9 and n2 / n1 < 11 }, { kind, true, true })
    eq({ kind, rs2.nodes / rs1.nodes > 9 and rs2.nodes / rs1.nodes < 11 }, { kind, true })
  end

  T[kind .. ": styles are shared"] = function()
    local _, _, r = built(kind, 1000)
    -- a handful of distinct styles (the rules' combinations), not one per element
    eq({ kind, r.computed <= 50, r.shared > 900 }, { kind, true, true })
  end

  T[kind .. ": a new result of the same shape reuses every element"] = function()
    local doc, chart = built(kind, 1000)
    local before = vim.deepcopy(content.stats)
    local rs, show = H.SCENARIOS[kind](1000, 1)
    content.build(chart, rs, show)
    style.restyle(doc)
    local created = content.stats.created - before.created
    local reused = content.stats.reused - before.reused
    eq({ kind, created, reused >= 1000 }, { kind, 0, true })
    -- only elements whose classes changed (thresholds, highlights) restyle
    eq({ kind, doc.restyled.nodes < 0.3 * count(chart) }, { kind, true })
    -- the same result again: nothing to build at all
    local skipped = content.stats.skipped
    content.build(chart, rs, show)
    eq(content.stats.skipped, skipped + 1)
  end
end

T["table: only text changes, no restyle; a class change restyles that element"] = function()
  local doc, chart = built("table", 200)
  local rs, show = H.SCENARIOS.table(200, 0)
  -- the same classes, other values (thresholds and NULLs at the same places)
  for _, row in ipairs(rs.rows) do
    if row[4] ~= vim.NIL then
      row[4] = row[4] + 1000
    end
  end
  content.build(chart, rs, show)
  doc.restyled = nil
  style.restyle(doc)
  eq(doc.restyled.nodes, 0)
  -- one cell crosses a threshold: that cell restyles, nothing else
  rs = vim.deepcopy(rs)
  rs.rows[10][2] = 950
  content.build(chart, rs, show)
  doc.restyled = nil
  style.restyle(doc)
  eq(doc.restyled.nodes, 1)
end

return T
