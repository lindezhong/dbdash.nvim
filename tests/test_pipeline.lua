-- The rendering pipeline (after Servo): coalesced updates, layout reuse by subtree
-- version, a compositor that writes only changed rows, hit testing and event dispatch.
local sched = require("dbdash.dashboard")
local parser = require("dbdash.css.parser")
local layout = require("dbdash.layout.view")
local buffer = require("dbdash.view.buffer")
local events = require("dbdash.events")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("dbdash").setup({ dashboard = { pause_hidden = false } })
    end,
    post_case = function()
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
    end,
  },
})

local CFG = {
  "database: { url: 'sqlite:///:memory:' }",
  "interval: 1h",
  "style: { dashboard: { grid-template-columns: 2 } }",
  "panels:",
  "  - id: a",
  "    query: { sql: 'SELECT 1 AS n' }",
  "    show: { type: table, title: A, interval: 1h }",
  "  - id: b",
  "    query: { sql: 'SELECT 2 AS m' }",
  "    show: { type: table, title: B, interval: 1h }",
}

local function start()
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile(CFG, f)
  require("dbdash.view.dashboard").start(f, { no_show = true })
  local d = assert(sched.get(sched.normalize(f)))
  vim.wait(5000, function()
    return d.panels[1].rs ~= nil and d.panels[2].rs ~= nil and not d.render_pending
  end, 10)
  require("dbdash.view.dashboard").redraw(d)
  return d
end

local function counters(d)
  local st = buffer.stats[d.buf] or { rows = 0, draws = 0 }
  return { hits = layout.stats.hits, misses = layout.stats.misses, rows = st.rows, draws = st.draws }
end

local function delta(a, b)
  return {
    hits = b.hits - a.hits,
    misses = b.misses - a.misses,
    rows = b.rows - a.rows,
    draws = b.draws - a.draws,
  }
end

T["a style query before the frame (a flush) does not lose the frame"] = function()
  local d = start()
  local p = d.panels[2]
  p.rs = require("dbdash.db.resultset").new({ { name = "m", type = "integer" } }, { { 7 } })
  p.committed = false
  p:emit("panel:result", p.rs, {}) -- committed: the document asks for a frame
  -- what the status line does: read computed styles, which restyles the document early
  require("dbdash.css.style").get(p.node)
  eq(d.doc:needs_update(), false)
  eq(d.doc:needs_frame(), true)
  eq(
    vim.wait(1000, function()
      return table
        .concat(vim.api.nvim_buf_get_lines(d.buf, 0, -1, false), "\n")
        :find("│ 7 │", 1, true) ~= nil
    end, 10),
    true
  )
  eq(d.doc:needs_frame(), false)
end

T["nothing changed: layout is reused and no row is written"] = function()
  local d = start()
  local before = counters(d)
  require("dbdash.view.dashboard").redraw(d)
  local dd = delta(before, counters(d))
  eq({ dd.misses, dd.rows, dd.draws }, { 0, 0, 1 })
  eq(dd.hits > 0, true)
end

T["a new result of one panel lays out that panel only"] = function()
  local d = start()
  local p = d.panels[2]
  local before = counters(d)
  p.rs = require("dbdash.db.resultset").new({ { name = "m", type = "integer" } }, { { 3 } })
  p.committed = false -- (a new period: the result is committed at once)
  p:emit("panel:result", p.rs, {}) -- as the panel's consumer tells it
  require("dbdash.view.dashboard").redraw(d)
  local dd = delta(before, counters(d))
  -- panel b: measured twice (min / max-content) and laid out once; panel a: reused
  eq(dd.misses, 3)
  eq(dd.rows > 0, true)
  eq(
    table.concat(vim.api.nvim_buf_get_lines(d.buf, 0, -1, false), "\n"):find("│ 3 │", 1, true)
      ~= nil,
    true
  )
end

T["a style change restyles, then lays out the panels it touches"] = function()
  local d = start()
  local before = counters(d)
  d.doc:set_sheet("runtime", assert(parser.sheet({ ["#a header"] = { color = "DiagnosticOk" } })))
  require("dbdash.view.dashboard").redraw(d)
  local dd = delta(before, counters(d))
  eq(d.last_restyle.damage, require("dbdash.css.properties").DAMAGE.repaint)
  -- repaint damage: panel a is laid out again for its new colors, its intrinsic sizes are
  -- reused (no relayout damage), panel b is untouched
  eq(dd.misses, 1)
  eq(dd.rows, 1) -- only the header row of panel a's table changed
end

T["requests in one batch render once"] = function()
  local d = start()
  local before = counters(d)
  d.doc:note_reason("viewport") -- something to update (a frame of nothing draws nothing)
  for _ = 1, 5 do
    require("dbdash.view.dashboard").request_render(d)
  end
  vim.wait(500, function()
    return not d.render_pending
  end, 5)
  eq(delta(before, counters(d)).draws, 1)
end

T["a change of element data only (the status) draws no frame"] = function()
  local d = start()
  vim.wait(500, function()
    return not d.render_pending
  end, 5)
  local before = counters(d)
  d.panels[1].node:set_data("running", "yes") -- (as a commit of the status does)
  vim.wait(500, function()
    return not d.render_pending
  end, 5)
  eq(delta(before, counters(d)).draws, 0)
  eq(d.doc.data_changed, false) -- the status line took it
end

T["hit testing finds the node; events capture, then bubble"] = function()
  local d = start()
  -- panel b's chart: its title is on the first row of the grid, the table below it
  local b = d.panels[2]
  local row_title, row_chart
  for _, h in ipairs(d.hits) do
    if
      h.node == b.node:find(function(n)
        return n.tag == "panel"
      end) and h.node ~= b.chart_node
    then
      row_title = row_title or h.row_s
    end
    if h.node == b.chart_node then
      row_chart = h.row_s
    end
  end
  local x
  for _, h in ipairs(d.hits) do
    if h.node == b.chart_node then
      x = h.x + 1
    end
  end
  eq(events.hit_test(d, row_chart + 1, x), b.chart_node)
  eq(require("dbdash.view.dashboard").panel_at(sched.get(d.path), row_chart + 1, x), b)
  local order = {}
  d.doc.root:on("ping", function(ev)
    order[#order + 1] = "root-capture:" .. ev.phase
  end, { capture = true })
  b.node:on("ping", function(ev)
    order[#order + 1] = "panel-bubble:" .. ev.phase
  end)
  b.chart_node:on("ping", function(ev)
    order[#order + 1] = "chart:" .. ev.phase
  end)
  d.doc.root:on("ping", function()
    order[#order + 1] = "root-bubble"
  end)
  events.dispatch("ping", b.chart_node)
  eq(order, { "root-capture:capture", "chart:target", "panel-bubble:bubble", "root-bubble" })
  order = {}
  b.node:on("ping", function(ev)
    ev:stop_propagation()
  end)
  events.dispatch("ping", b.chart_node)
  eq(order, { "root-capture:capture", "chart:target", "panel-bubble:bubble" })
end

return T
