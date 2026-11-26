-- :DbDashInspect (DevTools: matched rules, computed style, box) and :DbDashStyle set
-- (runtime rules, the top of the cascade).
local sched = require("dbdash.scheduler")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("dbdash").setup({ style = { ["chart.table header"] = { ["font-weight"] = "bold" } } })
      vim.cmd("runtime plugin/dbdash.lua")
    end,
    post_case = function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          vim.api.nvim_win_close(w, true)
        end
      end
      vim.cmd("silent! only")
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
  "style:",
  "  dashboard: { grid-template-columns: 2 }",
  "  panel-title: { color: Title }",
  "panels:",
  "  - id: a",
  "    query: { sql: 'SELECT 1 AS n' }",
  "    show: { type: table, title: A }",
  "    style:",
  "      panel-title: { color: Special }",
  "  - id: b",
  "    query: { sql: 'SELECT 2 AS m' }",
  "    show: { type: table, title: B }",
}

local function start()
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile(CFG, f)
  sched.start(f)
  local d = assert(sched.get(sched.normalize(f)))
  vim.wait(5000, function()
    return d.panels[1].rs and d.panels[2].rs and not d.render_pending
  end, 10)
  d:redraw()
  vim.api.nvim_set_current_win(vim.fn.bufwinid(d.buf))
  return d
end

---Put the cursor in the box recorded for `node`.
local function cursor_on(d, node)
  for _, h in ipairs(d.hits) do
    if h.node == node then
      vim.api.nvim_win_set_cursor(0, { h.row_s + 1, 0 })
      local line = vim.api.nvim_get_current_line()
      -- the byte of display column h.x + 1
      local col = 0
      for c = 0, #line do
        if vim.fn.strdisplaywidth(line:sub(1, c)) >= h.x + 1 then
          col = c
          break
        end
      end
      vim.api.nvim_win_set_cursor(0, { h.row_s + 1, col })
      return
    end
  end
  error("no box for " .. node:describe())
end

local function float_text()
  local win = vim.api.nvim_get_current_win()
  eq(vim.api.nvim_win_get_config(win).relative ~= "", true)
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

T["inspect: path, rules by origin and specificity, computed style, box"] = function()
  local d = start()
  cursor_on(d, d.panels[1].chart_node)
  vim.cmd("DbDashInspect header")
  local text = float_text()
  eq(text:find("dashboard > panel#a.table > chart.table > table > header", 1, true) ~= nil, true)
  eq(text:find("ua       header", 1, true) ~= nil, true) -- the UA sheet's rule
  eq(text:find("user     chart.table header  (0,1,2)", 1, true) ~= nil, true) -- setup({ style })
  eq(text:find("font%-weight +bold") ~= nil, true)
  vim.api.nvim_win_close(0, true)
  -- the panel's title: the dashboard's rule, then the panel's own (inline) rule wins
  vim.api.nvim_set_current_win(vim.fn.bufwinid(d.buf))
  cursor_on(d, d.panels[1].chart_node)
  vim.cmd("DbDashInspect panel-title")
  text = float_text()
  local author, inline = text:find("author   panel-title", 1, true), text:find("inline   panel-title", 1, true)
  eq({ author ~= nil, inline ~= nil, (author or 0) < (inline or 0) }, { true, true, true })
  eq(text:find("color +Special") ~= nil, true)
  -- the chart's box is highlighted in the dashboard
  eq(#vim.api.nvim_buf_get_extmarks(d.buf, require("dbdash.inspect").ns, 0, -1, {}) > 0, true)
end

T[":DbDashStyle set adds a runtime rule over every other origin; reset drops it"] = function()
  local d = start()
  vim.cmd("DbDashStyle set panel-title color DiagnosticOk")
  eq(require("dbdash.css").hl_of(d.panels[2].node:find(function(n)
    return n.tag == "panel-title"
  end)), "DiagnosticOk")
  -- over the panel's own (inline) rule too
  eq(require("dbdash.css").hl_of(d.panels[1].node:find(function(n)
    return n.tag == "panel-title"
  end)), "DiagnosticOk")
  -- JSON values; a grid change relays the panels out
  vim.cmd("DbDashStyle set dashboard grid-template-columns 1")
  eq(d.regions[2].row_s > d.regions[1].row_e, true)
  vim.cmd("DbDashStyle reset")
  eq(d.regions[2].row_s, d.regions[1].row_s)
  -- an invalid rule is refused and the sheet stays as it was
  local errs = {}
  local notify = vim.notify
  vim.notify = function(m)
    errs[#errs + 1] = m
  end
  vim.cmd("DbDashStyle set panel colour red")
  vim.notify = notify
  eq(errs[1]:find("unknown property 'colour'", 1, true) ~= nil, true)
end

return T
