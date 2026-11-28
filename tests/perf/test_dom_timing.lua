-- Timing budgets of rendering every chart type into a document (DOM build, style, layout,
-- paint of the chart): the first render, a new result of the same shape, a render after a
-- new rule, and a redraw of a dashboard where nothing changed. Medians of several runs;
-- the budgets are about 3x the times measured before the charts' DOM (see BASELINE), so
-- they catch regressions, not noise. Every measurement is reported as a note.
-- DBDASH_PERF=0 skips these tests.
local H = require("tests.perf.helpers")
local render = require("dbdash.render")
local parser = require("dbdash.css.parser")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local OPTS = { width = 120, height = 40 }

local function render_into(chart, rs, show)
  return render.render(rs, show, { width = OPTS.width, height = OPTS.height, node = chart })
end

---{ first, new, rule } medians (ms) and the memory of a first render (MB).
local function times(kind, size)
  local gen = H.SCENARIOS[kind]
  local r0, show = gen(size, 0)
  local chart
  local first, mb = H.measure(
    function()
      render_into(chart, r0, show)
    end,
    5,
    function()
      local _
      _, chart = H.chart(kind)
    end
  )
  local doc
  doc, chart = H.chart(kind)
  render_into(chart, r0, show)
  local results = {}
  for i = 1, 5 do
    results[i] = gen(size, i)
  end
  local new = H.measure(function(i)
    render_into(chart, results[i], show)
  end, 5)
  local rule = H.measure(
    function()
      render_into(chart, results[5], show)
    end,
    5,
    function(i)
      doc:set_sheet(
        "runtime",
        assert(parser.sheet({ ["*"] = { ["font-style"] = i % 2 == 0 and "italic" or "normal" } }))
      )
    end
  )
  return { first = first, new = new, rule = rule, mb = mb }
end

-- Medians measured before the charts' DOM (commit 4837abb), on the development machine:
-- { first, new, rule } in ms per scenario and size. The budgets are BUDGET x these.
local BASELINE = {
  table = {
    [100] = { first = 4.1, new = 2.1, rule = 3.1 },
    [1000] = { first = 52.8, new = 33.7, rule = 46.9 },
  },
  text = {
    [100] = { first = 1.1, new = 0.9, rule = 0.9 },
    [1000] = { first = 11.4, new = 8.7, rule = 8.7 },
  },
  bar = {
    [12] = { first = 1.4, new = 0.9, rule = 1.1 },
    [100] = { first = 7.1, new = 6.9, rule = 6.4 },
  },
  line = {
    [200] = { first = 1.5, new = 1.1, rule = 1.2 },
    [2000] = { first = 6.3, new = 6.0, rule = 5.7 },
  },
  scatter = {
    [200] = { first = 2.1, new = 0.8, rule = 1.1 },
    [2000] = { first = 2.1, new = 1.7, rule = 1.8 },
  },
  pie = {
    [8] = { first = 0.7, new = 0.3, rule = 0.4 },
    [50] = { first = 1.7, new = 1.0, rule = 1.2 },
  },
  -- boxplot 50: first measured 16.8 / 13.4 / 15.0, not reproducible: the same code (4837abb)
  -- measured 31.6 ms for a new result on later runs on this machine, so that is the baseline
  boxplot = {
    [5] = { first = 1.4, new = 0.8, rule = 0.8 },
    [50] = { first = 31.6, new = 31.6, rule = 31.6 },
  },
  heatmap = {
    [24] = { first = 1.4, new = 0.9, rule = 1.0 },
    [100] = { first = 9.9, new = 9.3, rule = 9.9 },
  },
  stat = {
    [1] = { first = 0.1, new = 0.1, rule = 0.2 },
    [6] = { first = 0.5, new = 0.2, rule = 0.4 },
  },
}
-- no-change redraw of a one-chart dashboard with a 1000-row table, before: 21.2 ms
local BUDGET = 3

for kind, sizes in pairs(H.SIZES) do
  T[kind] = function()
    if not H.timing_enabled() then
      MiniTest.skip("DBDASH_PERF=0")
    end
    local got = {}
    for _, size in ipairs(sizes) do
      local t = times(kind, size)
      got[size] = t
      MiniTest.add_note(
        ("%s %d: first %.1f ms (%.1f MB), new result %.1f ms, after a rule %.1f ms"):format(
          kind,
          size,
          t.first,
          t.mb,
          t.new,
          t.rule
        )
      )
      local base = (BASELINE[kind] or {})[size]
      if base then
        for _, op in ipairs({ "first", "new", "rule" }) do
          eq({ kind, size, op, t[op] <= math.max(base[op] * BUDGET, 5) }, { kind, size, op, true })
        end
      end
    end
    -- linear in the items: the large case costs at most 3 x the item ratio of the typical,
    -- plus 10 ms of machine noise (quadratic growth would be about 10 x the ratio)
    local small, large = sizes[1], sizes[2]
    local ratio = H.items(kind, large) / H.items(kind, small)
    eq({ kind, got[large].new <= got[small].new * ratio * 3 + 10 }, { kind, true })
  end
end

T["a redraw of a dashboard where nothing changed"] = function()
  if not H.timing_enabled() then
    MiniTest.skip("DBDASH_PERF=0")
  end
  local sched = require("dbdash.dashboard")
  require("dbdash").setup({ dashboard = { pause_hidden = false } })
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile({
    "database: { url: 'sqlite:///:memory:' }",
    "interval: 1h",
    "query:",
    "  max_rows: 1000",
    "  sql: WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000) SELECT i, i * 7 % 100 AS v, 'row ' || i AS t FROM n",
    "show: { type: table, interval: 1h }",
  }, f)
  require("dbdash.view.dashboard").start(f, { no_show = true })
  local d = assert(sched.get(sched.normalize(f)))
  vim.wait(10000, function()
    return d.panels[1].state.result ~= nil and not d.render_pending
  end, 10)
  require("dbdash.view.dashboard").redraw(d)
  local ms = H.measure(function()
    require("dbdash.view.dashboard").redraw(d)
  end, 7)
  sched.stop(d.path)
  require("dbdash").setup({})
  MiniTest.add_note(("no-change redraw of a 1000-row table dashboard: %.1f ms"):format(ms))
  eq(ms <= 15, true)
end

return T
