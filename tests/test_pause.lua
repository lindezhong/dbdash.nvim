-- A dashboard no window shows pauses (setup dashboard.pause_hidden, :help dbdash-pause): it
-- spends nothing on what is shown. A database is not queried (its own interval, the
-- top-level one); a source that sends data cannot be stopped without losing data, so its
-- items keep being received and processed (transform, history, thresholds), but nothing
-- is committed or drawn until the dashboard is shown again. Hidden here means hidden as a
-- user hides it: another buffer in its window.
local sched = require("dbdash.dashboard")
local eq = MiniTest.expect.equality

-- the autocmds that see windows change (tests run with --noplugin)
vim.cmd("runtime plugin/dbdash.lua")

local dir
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      require("dbdash").setup({ lua = { confirm = false } })
    end,
    post_case = function()
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

local function settle(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

---Start `text` in the current window; wait until `ready(d)`.
local function start(name, text, ready)
  local path = dir .. "/" .. name .. ".yaml"
  vim.fn.writefile(vim.split(text, "\n"), path)
  require("dbdash.view.dashboard").start(path, {})
  local d = assert(sched.get(sched.normalize(path)), "dashboard did not start")
  eq(
    vim.wait(5000, function()
      return ready(d)
    end, 10),
    true
  )
  return d
end

local function hide(d)
  vim.cmd("enew") -- another buffer in its window, as a user hides it
  settle(50)
  eq(d.paused, true)
end

local function show(d)
  vim.cmd("buffer " .. d.buf)
  settle(50)
  eq(d.paused, false)
end

---Count the queries sent to SQLite (every one is a Conn:execute of its driver; counted
---there because the data layer above it may be loaded again by other tests).
local function count_queries()
  local n = { 0 }
  local Conn = getmetatable(require("dbdash.db.drivers.sqlite").connect({})).__index
  local real = Conn.execute
  Conn.execute = function(...)
    n[1] = n[1] + 1
    return real(...)
  end
  MiniTest.finally(function()
    Conn.execute = real
  end)
  return n
end

T["pull: hidden, no query is sent (own and top-level intervals); shown, what is due at once"] = function()
  local queries = count_queries()
  local d = start(
    "pull",
    [[
database: { url: "sqlite:///:memory:" }
interval: 2s
panels:
  - query: { sql: "SELECT 1 AS a" }
    show: { type: table, interval: 1s }
  - query: { sql: "SELECT 2 AS b" }
    show: { type: table, interval: 1h }
]],
    function(d)
      return d.panels[1].state.result ~= nil and d.panels[2].state.result ~= nil
    end
  )
  settle(200)
  hide(d)
  local before = queries[1]
  settle(3000) -- three of the panel's intervals, one and a half of the top-level one
  eq(queries[1], before)
  show(d)
  eq(
    vim.wait(1000, function()
      return queries[1] > before
    end, 10),
    true
  )
  settle(2600) -- and the clock goes on (an interval of 1s)
  eq(queries[1] >= before + 2, true)
end

T["pull: a panel backing off sends no retry while hidden"] = function()
  local queries = count_queries()
  local d = start(
    "retry",
    [[
database: { url: "sqlite:///:memory:" }
query: { sql: "SELEC oops" }
show: { type: table, interval: 1s }
]],
    function(d)
      return d.panels[1].state.error ~= nil and not d.panels[1].running
    end
  )
  hide(d)
  local before = queries[1]
  settle(2500)
  eq(queries[1], before)
end

T["pull: pause_hidden = false keeps querying while hidden"] = function()
  require("dbdash").setup({ lua = { confirm = false }, dashboard = { pause_hidden = false } })
  local queries = count_queries()
  local d = start(
    "keep",
    [[
database: { url: "sqlite:///:memory:" }
query: { sql: "SELECT 1 AS a" }
show: { type: table, interval: 1s }
]],
    function(d)
      return d.panels[1].state.result ~= nil
    end
  )
  vim.cmd("enew")
  settle(50)
  eq(d.paused or false, false)
  local before = queries[1]
  settle(3200)
  eq(queries[1] >= before + 2, true)
end

T["push: hidden, items are received and processed, not committed; shown, the latest at once"] = function()
  local notes = {}
  local real_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
  vim.notify = function(m)
    notes[#notes + 1] = m
  end
  MiniTest.finally(function()
    vim.notify = real_notify
  end)
  local d = start(
    "push",
    [[
database: { url: "luastream://" }
query:
  sql: |
    local i = 0
    while true do
      i = i + 1
      print(vim.json.encode({ { n = i } }))
      dbdash.sleep(100)
    end
show:
  type: stat
  interval: 1s
  thresholds: [{ value: 25, class: danger, notify: true }]
]],
    function(d)
      return d.panels[1].stream and d.panels[1].stream.processed >= 2
    end
  )
  local p = d.panels[1]
  settle(1100) -- a tick: what came so far is committed
  hide(d)
  local function shown_n()
    local text = table.concat(vim.api.nvim_buf_get_lines(d.buf, 0, -1, false), "\n")
    return text
  end
  local processed, history, text = p.stream.processed, #p.history, shown_n()
  local committed = p.chart_node.content and p.chart_node.content.rs
  settle(2500)
  -- received and processed: the transform ran, the history and thresholds saw them
  eq(p.stream.processed >= processed + 15, true)
  eq(#p.history > history or #p.history == require("dbdash.options").current.defaults.history, true)
  eq(table.concat(notes, "\n"):find("≥ 25", 1, true) ~= nil, true) -- notified while hidden
  -- nothing committed, nothing drawn
  eq(p.chart_node.content and p.chart_node.content.rs, committed)
  eq(shown_n(), text)
  local latest = p.state.result
  show(d)
  -- the latest result at once (later items wait for the panel's next tick)
  eq(p.chart_node.content.rs, latest)
  settle(100)
  eq(shown_n() ~= text, true)
end

return T
