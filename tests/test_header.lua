-- The dashboard header: the title and the countdown to the global refresh, and the uses of
-- the title elsewhere (notifications, meta.dashboard_title).
local sched = require("dbdash.dashboard")
local buffer = require("dbdash.view.buffer")
local eq = MiniTest.expect.equality

local dir
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      -- the dashboards here have no window: shown all the same (pausing: test_pause.lua)
      require("dbdash").setup({ dashboard = { pause_hidden = false } })
    end,
    post_case = function()
      require("dbdash").setup({})
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
    end,
  },
})

local function run(name, text)
  local path = dir .. "/" .. name .. ".yaml"
  vim.fn.writefile(vim.split(text, "\n"), path)
  require("dbdash.view.dashboard").start(path, { no_show = true })
  local d = assert(sched.get(sched.normalize(path)), "dashboard did not start")
  vim.wait(10000, function()
    for _, p in ipairs(d.panels) do
      if not (p.state.result or p.state.error) or p.running then
        return false
      end
    end
    return true
  end, 10)
  require("dbdash.view.dashboard").redraw(d)
  return d
end

local function marks(d, row)
  local out = {}
  for _, m in
    ipairs(
      vim.api.nvim_buf_get_extmarks(
        d.buf,
        buffer.ns_status,
        { row, 0 },
        { row, -1 },
        { details = true }
      )
    )
  do
    if m[4].virt_text then
      out[#out + 1] = m[4].virt_text[1][1]
    end
  end
  return out
end

T["countdown_text: {time}, {clock}, running"] = function()
  eq(require("dbdash.view.dashboard").countdown_text("{time}s", 42), "42s")
  eq(require("dbdash.view.dashboard").countdown_text("all in {clock}", 582), "all in 9:42")
  eq(require("dbdash.view.dashboard").countdown_text("{clock}", 3725), "1:02:05")
  eq(require("dbdash.view.dashboard").countdown_text("{clock}", 5), "0:05")
  eq(require("dbdash.view.dashboard").countdown_text("{time}s", 5, true), "…")
end

T["title and global countdown: a header line, the panel's countdown below it"] = function()
  local d = run(
    "one",
    [[
title: Sales overview
interval: 10m
database: { url: "sqlite:///:memory:" }
query: { sql: SELECT 1 AS x }
show: { interval: 30s }
style:
  countdown: { display: block, content: "{time}s" }
  header countdown: { content: "all in {clock}" }
]]
  )
  local lines = vim.api.nvim_buf_get_lines(d.buf, 0, 3, false)
  eq({ lines[1], lines[2] }, { "Sales overview", "" })
  eq(marks(d, 0)[1]:match("^all in %d+:%d%d$") ~= nil, true)
  eq(marks(d, 2)[1]:match("^%d+s$") ~= nil, true)
  eq(d.panels[1].meta.dashboard_title, "Sales overview")
end

T["grid: the header above the panels; without title or countdown, none"] = function()
  local d = run(
    "grid",
    [[
interval: 1h
style: { "header countdown": { display: block } }
database: { url: "sqlite:///:memory:" }
panels:
  - query: { sql: SELECT 1 AS x }
    show: { title: A }
]]
  )
  local lines = vim.api.nvim_buf_get_lines(d.buf, 0, 3, false)
  eq({ lines[1], lines[2], lines[3] }, { "", "", "A" })
  eq(#marks(d, 0), 1)
  local plain =
    run("plain", "database: { url: 'sqlite:///:memory:' }\nquery: { sql: SELECT 1 AS x }\n")
  eq(vim.api.nvim_buf_get_lines(plain.buf, 0, 1, false)[1] ~= "", true)
  eq(plain.panels[1].meta.dashboard_title, nil)
end

T["the header countdown counts down to the top-level interval: none without one"] = function()
  local d = run(
    "nointerval",
    [[
style: { "header countdown": { display: block } }
database: { url: "sqlite:///:memory:" }
query: { sql: SELECT 1 AS x }
]]
  )
  eq(#marks(d, 0), 0)
end

T["threshold notifications name the config file (and the panel's title, when it has one)"] = function()
  local notes = {}
  local real = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  run(
    "thr",
    [[
title: Board
database: { url: "sqlite:///:memory:" }
query: { sql: SELECT 99 AS v }
show:
  type: stat
  thresholds: [{ value: 50, class: danger, notify: true }]
]]
  )
  vim.notify = real
  local found = false
  for _, n in ipairs(notes) do
    found = found or n:find("^dbdash: [^\n]*thr%.yaml: 99 ≥ 50") ~= nil
  end
  eq(found, true)
end

T["the sidebar lists file names only, not titles"] = function()
  vim.fn.writefile(
    { "title: My board", "database: { url: 'sqlite:///:memory:' }", "query: { sql: x }" },
    dir .. "/a.yaml"
  )
  local sidebar = require("dbdash.view.sidebar")
  local buf = vim.api.nvim_create_buf(false, true)
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(dir)
  sidebar.render(buf)
  vim.cmd.cd(cwd)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  eq(text:find("a.yaml", 1, true) ~= nil, true)
  eq(text:find("My board", 1, true), nil)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    eq(m[4].virt_text, nil)
  end
end

return T
