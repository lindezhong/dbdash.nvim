-- Dashboards have a document (dom/build.lua) and their view and charts take their colors
-- from it: a rule added to the document reaches the buffer on the next redraw.
local sched = require("dbdash.dashboard")
local parser = require("dbdash.css.parser")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- dashboards without a window are paused (and not rendered) unless this is off
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

local function start(lines)
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile(lines, f)
  require("dbdash.view.dashboard").start(f, { no_show = true })
  local d = assert(sched.get(sched.normalize(f)))
  vim.wait(5000, function()
    for _, p in ipairs(d.panels) do
      if not (p.rs or p.error) then
        return false
      end
    end
    return true
  end, 10)
  vim.wait(1000, function() -- the result's rendering update is coalesced
    return not d.render_pending
  end, 5)
  return d
end

local function groups(d)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(d.buf, -1, 0, -1, { details = true })) do
    if m[4].hl_group then
      out[m[4].hl_group] = true
    end
  end
  return out
end

T["the document mirrors the dashboard"] = function()
  local d = start({
    "database: { url: 'sqlite:///:memory:' }",
    "panels:",
    "  - id: kpi",
    "    query: { sql: 'SELECT 1 AS n' }",
    "    show: { type: stat, title: K }",
    "  - query: { sql: 'SELECT 1 AS n' }",
    "    show: { type: table, title: T }",
  })
  eq(d.doc.root.tag, "dashboard")
  eq(
    { d.panels[1].node:describe(), d.panels[1].chart_node:describe() },
    { "panel#kpi.stat", "chart.stat" }
  )
  eq(d.panels[2].node:describe(), "panel#2.table")
end

T["a rule in the document reaches the buffer"] = function()
  local d = start({
    "database: { url: 'sqlite:///:memory:' }",
    "panels:",
    "  - id: kpi",
    "    query: { sql: 'SELECT 1 AS n' }",
    "    show: { type: table, title: K }",
  })
  eq(groups(d).DbDashHeader, true)
  d.doc:set_sheet(
    "runtime",
    assert(parser.sheet({
      ["#kpi header"] = { color = "DiagnosticOk" },
      ["panel-title"] = { color = "DiagnosticInfo" },
    }))
  )
  require("dbdash.view.dashboard").redraw(d)
  local g = groups(d)
  eq({ g.DbDashHeader, g.DiagnosticOk, g.DiagnosticInfo }, { nil, true, true })
end

return T
