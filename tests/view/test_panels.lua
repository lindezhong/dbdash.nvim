-- One logic for every dashboard: a config without `panels:` is a dashboard of one panel,
-- drawn as any other. Titles, the error line, the status (setup countdown_position) and
-- narrow windows; renderers draw the chart only; every message goes through the notifier.
local sched = require("dbdash.dashboard")
local buffer = require("dbdash.view.buffer")
local eq = MiniTest.expect.equality

local dir
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      vim.o.columns = 100
    end,
    post_case = function()
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
      vim.cmd("silent! only")
    end,
  },
})

---Start `text` as <name>.yaml in the current window and wait for its results.
local function run(name, text)
  local path = dir .. "/" .. name .. ".yaml"
  vim.fn.writefile(vim.split(text, "\n"), path)
  require("dbdash.view.dashboard").start(path, {})
  local d = assert(sched.get(sched.normalize(path)), "dashboard did not start")
  vim.wait(10000, function()
    for _, p in ipairs(d.panels) do
      if not (p.rs or p.error) or p.running then
        return false
      end
    end
    return true
  end, 10)
  require("dbdash.view.dashboard").redraw(d)
  return d
end

local function lines(d)
  return vim.api.nvim_buf_get_lines(d.buf, 0, -1, false)
end

---The status marks: { row (0-based), window column, text }.
local function marks(d)
  local out = {}
  for _, m in
    ipairs(vim.api.nvim_buf_get_extmarks(d.buf, buffer.ns_status, 0, -1, { details = true }))
  do
    out[#out + 1] = { m[2], m[4].virt_text_win_col, m[4].virt_text[1][1] }
  end
  return out
end

---The text of display cells [from, to) of `line`.
local function cells(line, from, to)
  local out, col = {}, 0
  for _, ch in ipairs(vim.fn.split(line, "\\zs")) do
    if col >= from and col < to then
      out[#out + 1] = ch
    end
    col = col + vim.fn.strdisplaywidth(ch)
  end
  return table.concat(out)
end

local PANEL = [[
database: { url: "sqlite:///:memory:" }
query: { sql: "SELECT 1 AS n, 'x' AS s" }
show: { type: table, title: Numbers, interval: 1h }
style:
  countdown: { display: block, content: "next {time}s" }
]]

T["a config without panels: is the grid of that one panel"] = function()
  local one = run("one", PANEL)
  local listed = run(
    "listed",
    [[
panels:
  - database: { url: "sqlite:///:memory:" }
    query: { sql: "SELECT 1 AS n, 'x' AS s" }
    show: { type: table, title: Numbers, interval: 1h }
    style:
      countdown: { display: block, content: "next {time}s" }
]]
  )
  eq(lines(listed), lines(one))
  eq(#marks(listed), #marks(one))
end

T["titles: one panel without one has no title line; with more, Panel N"] = function()
  local d = run(
    "untitled",
    [[
database: { url: "sqlite:///:memory:" }
query: { sql: "SELECT 7 AS n" }
show: { type: table, interval: 1h }
]]
  )
  eq(lines(d)[1]:find("Panel", 1, true), nil)
  eq(lines(d)[1]:match("^[┏┌]") ~= nil, true) -- the table first
  local two = run(
    "two",
    [[
database: { url: "sqlite:///:memory:" }
panels:
  - query: { sql: "SELECT 1 AS a" }
    show: { type: table, interval: 1h }
  - query: { sql: "SELECT 2 AS b" }
    show: { type: table, interval: 1h }
]]
  )
  local text = table.concat(lines(two), "\n")
  eq({ text:find("Panel 1", 1, true) ~= nil, text:find("Panel 2", 1, true) ~= nil }, { true, true })
end

T["an error is a line of its own under the title, wrapped, never cut"] = function()
  vim.o.columns = 40
  local d = run(
    "broken",
    [[
database: { url: "sqlite:///:memory:" }
query: { sql: "SELECT * FROM a_table_whose_name_is_far_too_long_for_one_line" }
show: { title: Broken, interval: 1h }
]]
  )
  local l = lines(d)
  eq(l[1]:match("^Broken") ~= nil, true)
  eq(l[2]:match("^✗ ") ~= nil, true)
  local text = table.concat(vim.tbl_map(vim.trim, l), "") -- (a long word breaks)
  eq(text:find("a_table_whose_name_is_far_too_long_for_one_line", 1, true) ~= nil, true)
  for _, line in ipairs(l) do
    eq(vim.fn.strdisplaywidth(line) <= 40, true)
  end
end

T["countdown_position places each panel's status on its title line"] = function()
  local cfg = [[
database: { url: "sqlite:///:memory:" }
style:
  countdown: { display: block, content: "next {time}s" }
panels:
  - query: { sql: "SELECT 1 AS a" }
    show: { type: table, title: Left, interval: 1h }
  - query: { sql: "SELECT 2 AS b" }
    show: { type: table, title: Right, interval: 1h }
]]
  local want = {
    -- right_align: at the end of the panel's width; eol: after the title and a space;
    -- overlay: at the start of the title line
    right_align = function(m, d)
      local r = d.regions[1]
      return m[2] + vim.fn.strdisplaywidth(m[3]) == r.x + r.width
    end,
    eol = function(m)
      return m[2] == #"Left" + 1
    end,
    overlay = function(m)
      return m[2] == 0
    end,
  }
  for _, position in ipairs({ "right_align", "eol", "overlay" }) do
    require("dbdash").setup({ countdown_position = position })
    local d = run("pos_" .. position, cfg)
    local ms = marks(d)
    eq(#ms, 2)
    table.sort(ms, function(a, b)
      return a[2] < b[2]
    end)
    eq(ms[1][1], 0) -- the title line
    eq(ms[1][3]:match("^next %d+s$") ~= nil, true)
    eq({ position, want[position](ms[1], d) }, { position, true })
    sched.stop(d.path)
  end
end

T["narrow windows: the status gives way to the title and ⓘ"] = function()
  local cfg = [[
database: { url: "sqlite:///:memory:" }
style:
  dashboard: { grid-template-columns: 2 }
  countdown: { display: block, content: "next refresh in {time}s" }
panels:
  - query: { sql: "SELECT 1 AS a" }
    show: { type: table, title: "GET, no token", description: About, interval: 1h }
  - query: { sql: "SELECT 2 AS b" }
    show: { type: table, title: "POST, with token", description: About, interval: 1h }
]]
  for _, cols in ipairs({ 120, 70, 50 }) do
    vim.o.columns = cols
    local d = run("narrow" .. cols, cfg)
    local title = lines(d)[1]
    for _, m in ipairs(marks(d)) do
      -- the cells under the mark are blank: no title or ⓘ is covered
      local under = cells(title, m[2], m[2] + vim.fn.strdisplaywidth(m[3]))
      eq({ cols, m[3], vim.trim(under) }, { cols, m[3], "" })
    end
    local text = table.concat(lines(d), "\n")
    eq(text:find("ⓘ", 1, true) ~= nil, true)
    sched.stop(d.path)
  end
end

T["renderers read the content committed; they do not build it"] = function()
  local d = run("built", PANEL)
  local content = require("dbdash.render.content")
  local real, calls = content.build, 0
  ---@diagnostic disable-next-line: duplicate-set-field (counted for the test)
  content.build = function(...)
    calls = calls + 1
    return real(...)
  end
  vim.o.columns = 60 -- a new layout: everything is rendered again
  require("dbdash.view.dashboard").redraw(d)
  content.build = real
  eq(calls, 0)
end

T["every message goes through the notifier, with its prefix"] = function()
  local notes = {}
  local real = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
  vim.notify = function(m)
    notes[#notes + 1] = m
  end
  require("dbdash").setup({ countdown_position = "nowhere" }) -- a setup error
  local e = require("dbdash.util.emitter").new()
  e:on("x", function()
    error("boom", 0)
  end)
  e:emit("x") -- a failing listener
  require("dbdash.commands").describe() -- no dashboard here: an error
  vim.notify = real
  eq(#notes >= 3, true)
  for _, m in ipairs(notes) do
    eq({ m, m:sub(1, 8) }, { m, "dbdash: " })
  end
end

T["a panel's error names its config file and its panel"] = function()
  local notes = {}
  local real = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
  vim.notify = function(m)
    notes[#notes + 1] = m
  end
  run(
    "where",
    [[
database: { url: "sqlite:///:memory:" }
panels:
  - query: { sql: "SELECT 1 AS a" }
    show: { type: table, title: Good, interval: 1h }
  - query: { sql: "SELEC oops" }
    show: { type: table, title: Bad, interval: 1h }
]]
  )
  run(
    "lone",
    [[
database: { url: "sqlite:///:memory:" }
query: { sql: "SELEC oops" }
show: { type: table, interval: 1h }
]]
  )
  vim.notify = real
  local text = table.concat(notes, "\n")
  eq(text:find("where%.yaml › Bad: sqlite query error") ~= nil, true)
  eq(text:find("lone%.yaml: sqlite query error") ~= nil, true) -- no title: the file only
end

return T
