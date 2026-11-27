-- The model without a view (ARCHITECTURE.md#scheduling, #results, #drawing): the clock on
-- a fake time, commits once per period, generations, the subscribers, a database's loop
-- backing off, and the events a dashboard tells.
local sched = require("dbdash.dashboard")
local eq = MiniTest.expect.equality

local dir
local real_now, real_update = vim.uv.now, vim.uv.update_time
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      require("dbdash").setup({ lua = { confirm = false }, dashboard = { pause_hidden = false } })
    end,
    post_case = function()
      vim.uv.now, vim.uv.update_time = real_now, real_update
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
    end,
  },
})

local function write(text)
  local path = dir .. "/m.yaml"
  vim.fn.writefile(vim.split(text, "\n"), path)
  return path
end

---A dashboard of `text` that is not started, on a fake time: t(ms) sets the time, and the
---clock's uv timer is a stand-in (wake() is called by the case). Returns d and the ticks
---each panel got.
local function on_fake_clock(text)
  local path = write(text)
  local cfg = assert(sched.prepare(path))
  local d =
    require("dbdash.dashboard.dashboard").new(path, cfg, require("dbdash.args").new_state({}))
  local now = 0
  ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
  vim.uv.now = function()
    return now
  end
  ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
  vim.uv.update_time = function() end
  d.clock.timer = {
    stop = function() end,
    start = function() end,
    get_due_in = function()
      return 1
    end,
  }
  local ticks = {}
  d.events:on("panel:tick", function(p)
    ticks[#ticks + 1] = p.index
  end)
  d.clock:start()
  return d, ticks, function(ms)
    now = ms
  end
end

local GRID = [[
database: { url: "lua://" }
interval: 3s
grid: { columns: 2 }
panels:
  - query: { sql: "return {}" }
    show: { type: table, interval: 1s }
  - query: { sql: "return {}" }
    show: { type: table, interval: 5s }
]]

T["clock: own deadlines; the top-level one ticks every panel and aligns them"] = function()
  local d, ticks, t = on_fake_clock(GRID)
  t(1000)
  d.clock:wake()
  eq(ticks, { 1 })
  t(2000)
  d.clock:wake()
  t(3000) -- top-level: both; panel 1's own deadline is the same moment (one tick)
  d.clock:wake()
  eq(ticks, { 1, 1, 1, 2 })
  eq({ d.panels[1].next_at, d.panels[2].next_at }, { 4000, 8000 })
  -- panel 2 (5 s, longer than the top-level 3 s) only ever ticks with the others
  -- one wake: one tick per due panel, however many deadlines it met
  t(6000)
  d.clock:wake()
  eq(vim.list_slice(ticks, 5), { 1, 2 })
  eq(d.panels[2].next_at, 11000) -- its own deadline is always after the next top-level one
end

T["clock: deadlines within the slack are one tick"] = function()
  local d, ticks, t = on_fake_clock(GRID)
  d.panels[1].next_at = 3010 -- 10 ms after the top-level deadline
  t(3000)
  d.clock:wake()
  eq(ticks, { 1, 2 })
  eq(d.panels[1].next_at, 4000)
end

T["clock: a panel backing off is left alone by the top-level tick"] = function()
  local d, ticks, t = on_fake_clock(GRID)
  d.panels[1].retry_at, d.panels[1].next_at = 5000, 5000
  t(3000)
  d.clock:wake()
  eq(ticks, { 2 })
  t(5000)
  d.clock:wake()
  eq(ticks, { 2, 1 })
end

T["clock: hidden only refresh_hidden panels tick; shown, what came due ticks at once"] = function()
  local d, ticks, t = on_fake_clock([[
database: { url: "lua://" }
grid: { columns: 2 }
panels:
  - query: { sql: "return {}" }
    show: { type: table, interval: 1s }
  - query: { sql: "return {}" }
    show: { type: table, interval: 1s, refresh_hidden: true }
]])
  d:pause()
  t(1000)
  d.clock:wake()
  eq(ticks, { 2 })
  t(1500)
  d:resume()
  eq(ticks, { 2, 1 })
  eq(d.panels[1].next_at, 2500)
end

T["commit: one result per period at once, the next at the tick; a tick commits once"] = function()
  local d = on_fake_clock(GRID)
  local p = d.panels[1]
  d:commit()
  local rs = require("dbdash.db.lua_result").normalize({ { x = 1 } }, {})
  p.rs = rs
  p:emit("panel:result", rs, {})
  eq({ p.committed, p.pending }, { true, false })
  local version = d.doc.version
  p.rs = require("dbdash.db.lua_result").normalize({ { x = 2 } }, {})
  p:emit("panel:result", p.rs, {})
  eq({ p.pending, d.doc.version }, { true, version }) -- waits for the next tick
  p:emit("panel:tick")
  eq(p.pending, false)
  eq(d.doc.version > version, true)
  version = d.doc.version
  p:emit("panel:tick") -- nothing new: nothing written
  eq(d.doc.version, version)
end

T["subscribers: history records results, errors, skipped ticks and cancels"] = function()
  local d = on_fake_clock(GRID)
  local p = d.panels[1]
  local rs = require("dbdash.db.lua_result").normalize({ { x = 1 } }, {})
  p:emit("panel:result", rs, { elapsed_ms = 3 })
  p:emit("panel:error", require("dbdash.util.error").new({ phase = "query", message = "no" }), {})
  p:emit("panel:skipped")
  p:emit("panel:cancelled", "why")
  local kinds = vim.tbl_map(function(h)
    return h.cancelled or (h.skipped and "skipped") or h.error or h.rows
  end, p.history)
  eq(kinds, { "why", "skipped", "query error: no", 1 })
end

T["a dashboard without a view: its events, and what it commits into the document"] = function()
  local path = write([[
database: { url: "sqlite:///:memory:" }
query: { sql: "SELECT 1 AS x" }
show: { type: table, interval: 1h }
]])
  local cfg, state = sched.prepare(path)
  local seen = {}
  local events = require("dbdash.dashboard.events")
  local function on_started(d)
    for _, e in ipairs({ "panel:state", "panel:result", "panel:error" }) do
      d.events:on(e, function()
        seen[#seen + 1] = e
      end)
    end
  end
  events:on("dashboard:started", on_started)
  MiniTest.finally(function()
    events:off("dashboard:started", on_started)
  end)
  local d = sched.create(path, cfg, state)
  local p = d.panels[1]
  vim.wait(3000, function()
    return p.rs ~= nil
  end, 10)
  -- started, its query running, the result, not running any more
  eq(seen, { "panel:state", "panel:state", "panel:result", "panel:state" })
  eq(p.node.data.running, false)
  eq(p.node.data.next_at, p.next_at)
  local cells = {}
  p.chart_node:walk(function(n)
    if n.tag == "cell" then
      cells[#cells + 1] = n
    end
  end)
  eq(#cells > 0, true) -- the content was built from the result
end

T["generations: after a restart, results of the old run are dropped"] = function()
  local path = write([[
database: { url: "sqlite:///:memory:" }
query: { sql: "SELECT 1 AS x" }
show: { type: table, interval: 1h }
]])
  local cfg, state = sched.prepare(path)
  local d = sched.create(path, cfg, state)
  local p = d.panels[1]
  vim.wait(3000, function()
    return p.rs ~= nil
  end, 10)
  local old = p.gen
  p:restart()
  local received = p.feed.received
  p:on_result(old, nil, require("dbdash.db.lua_result").normalize({ { x = 9 } }, {}))
  eq(p.feed.received, received)
end

T["a database's loop: failures in a row back off; the first success ends it"] = function()
  local waits = {}
  local handle ---@type dbdash.db.RunHandle
  local outcomes = { false, false, false, true }
  local n = 0
  local done = false
  local now = real_now()
  ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
  vim.uv.now = function()
    return now
  end
  handle = require("dbdash.db").run("sqlite:///:memory:", "SELECT 1", {
    interval = 1000,
    backoff = 8,
    wait_tick = function(not_before, failures)
      waits[#waits + 1] = { not_before ~= nil, failures }
      now = not_before or now + 1000 -- the tick comes when it may query
      return #waits <= #outcomes
    end,
  }, function()
    n = n + 1
    handle:report(outcomes[n])
  end, function()
    done = true
  end)
  vim.wait(3000, function()
    return done
  end, 10)
  -- the 1st failure waits the interval; from the 2nd on, longer (until a success)
  eq(waits, { { false, 0 }, { false, 1 }, { true, 2 }, { true, 3 }, { false, 0 } })
end

T["db.query: one result, then the run stops"] = function()
  local calls, ended = 0, false
  require("dbdash.db").query("sqlite:///:memory:", "SELECT 1 AS x", {}, function(err, rs)
    calls = calls + 1
    eq({ err, rs.rows }, { nil, { { 1 } } })
    ended = true
  end)
  vim.wait(3000, function()
    return ended
  end, 10)
  vim.wait(100)
  eq(calls, 1)
end

return T
