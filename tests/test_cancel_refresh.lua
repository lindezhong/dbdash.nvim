-- Cancelling refreshes: a refresh the user asks for replaces the one running (its queries
-- stop), stopping a dashboard and exiting cancel what runs; timer ticks still skip.
local sched = require("dbdash.dashboard")
local db = require("dbdash.db")
local async = require("dbdash.util.async")
local resultset = require("dbdash.db.resultset")
local eq = MiniTest.expect.equality

-- A driver whose queries containing "slow" take 2 s; it logs what happens.
local log = {}
db.register({
  name = "slowfake",
  schemes = { "slowfake" },
  capabilities = { tls = false, sql = true, query_language = "sql" },
  connect = function()
    return {
      execute = function(_, q)
        log[#log + 1] = "execute " .. q
        if q:find("slow") then
          async.sleep(2000)
        end
        log[#log + 1] = "done " .. q
        return resultset.new({ { name = "q", type = "text" } }, { { q } })
      end,
      close = function() end,
    }
  end,
  cancel = function()
    log[#log + 1] = "cancel"
  end,
})

-- (config files accept the built-in types only)
require("dbdash.config").DB_TYPES.slowfake = true

local dir
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      log = {}
      _G.dbdash_test_spins = 0
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      require("dbdash").setup({ lua = { confirm = false } })
    end,
    post_case = function()
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      vim.wait(200)
      require("dbdash").setup({})
    end,
  },
})

local function start(text)
  local path = dir .. "/c.yaml"
  vim.fn.writefile(vim.split(text, "\n"), path)
  require("dbdash.view.dashboard").start(path, { no_show = true })
  return assert(sched.get(sched.normalize(path)), "dashboard did not start")
end

local function has(entry)
  return vim.tbl_contains(log, entry)
end

local SLOW = [[
database: { url: "slowfake://h" }
args:
  - { name: q, type: string, default: "slow" }
query:
  sql: "{{ args.q }}"
show: { type: table, interval: 1h }
]]

local function wait_running(p)
  vim.wait(2000, function()
    return p.running and has("execute slow")
  end, 5)
  eq(p.running, true)
end

T["a requested refresh cancels the running one and starts at once"] = function()
  local d = start(SLOW)
  local p = d.panels[1]
  wait_running(p)
  local first = p.current
  d:restart() -- what `r` does
  eq(has("cancel") or vim.wait(1000, function()
    return has("cancel")
  end, 5), true)
  -- The new refresh runs already; the old one is closed as cancelled.
  eq({ p.running, p.current ~= first, p.refresh_count }, { true, true, 2 })
  eq(
    { p.prev.id, p.prev.ok, p.prev.error },
    { first.record.id, false, "query cancelled: replaced by a new refresh" }
  )
  eq(p.history[1].cancelled, "replaced by a new refresh")
  eq(p.error, nil)
end

T["changing an argument cancels the running refresh; only the new result shows"] = function()
  local d = start(SLOW)
  local p = d.panels[1]
  wait_running(p)
  require("dbdash.args").set_modified(d.state, "q", "fast")
  d:restart()
  vim.wait(1000, function()
    return p.rs ~= nil
  end, 5)
  eq(p.rs.rows[1][1], "fast")
  vim.wait(2500) -- the slow query's late result is dropped
  eq(p.rs.rows[1][1], "fast")
  eq({ p.error, p.refresh_count }, { nil, 2 })
end

T["a timer tick while a refresh runs is skipped, not a cancel"] = function()
  local d = start(SLOW)
  local p = d.panels[1]
  wait_running(p)
  p:refresh() -- a timer tick
  eq(p.history[1].skipped, true)
  vim.wait(2500, function()
    return p.rs ~= nil
  end, 5)
  eq({ has("cancel"), p.rs.rows[1][1], p.refresh_count }, { false, "slow", 1 })
end

T["stopping the dashboard cancels its queries"] = function()
  local d = start(SLOW)
  wait_running(d.panels[1])
  sched.stop(d.path)
  vim.wait(500, function()
    return has("cancel")
  end, 5)
  eq(has("cancel"), true)
  eq(db.pending_cancels(), 0)
end

T["exiting cancels the queries and waits for the server cancels"] = function()
  local d = start(SLOW)
  wait_running(d.panels[1])
  sched.freeze_all()
  eq({ has("cancel"), db.pending_cancels() }, { true, 0 })
  eq(sched.get(d.path) ~= nil, true) -- kept for the session hooks
end

T["lua:// and query.transform: a cancelled refresh stops its Lua code"] = function()
  for _, text in ipairs({
    [[
database: { url: "lua://" }
query:
  sql: "while true do _G.dbdash_test_spins = _G.dbdash_test_spins + 1; dbdash.checkpoint() end"
show: { type: table, interval: 1h }
]],
    [[
database: { url: "sqlite:///:memory:" }
query:
  sql: "SELECT 1"
  transform: "while true do _G.dbdash_test_spins = _G.dbdash_test_spins + 1; dbdash.checkpoint() end"
  timeout: 60s
show: { type: table, interval: 1h }
]],
  }) do
    _G.dbdash_test_spins = 0
    local d = start(text)
    vim.wait(2000, function()
      return _G.dbdash_test_spins > 0
    end, 5)
    eq(_G.dbdash_test_spins > 0, true)
    sched.stop(d.path)
    vim.wait(200)
    local n = _G.dbdash_test_spins
    vim.wait(300)
    eq(_G.dbdash_test_spins, n) -- no longer running
  end
end

T["dbdash.run(): cancelling the refresh cancels the callback's query"] = function()
  local d = start([[
database: { url: "slowfake://h" }
args:
  - { name: q, type: string, default: "fast" }
query:
  sql: "{{ args.q }}"
  transform: |
    if meta.run.kind == "refresh" then dbdash.run({ q = "slow callback" }) end
    return rs
show: { type: table, interval: 1h }
]])
  vim.wait(2000, function()
    return has("execute slow callback")
  end, 5)
  sched.stop(d.path)
  vim.wait(500, function()
    return has("cancel")
  end, 5)
  eq(has("cancel"), true)
end

T[":DbDashStatus lists a cancelled refresh"] = function()
  local d = start(SLOW)
  wait_running(d.panels[1])
  d:restart()
  vim.wait(100)
  local lines
  local popup = require("dbdash.view.popup")
  local real = popup.open
  popup.open = function(l)
    lines = l
  end
  vim.api.nvim_set_current_buf(d.buf)
  pcall(require("dbdash.commands").status)
  popup.open = real
  eq(
    lines ~= nil
      and table.concat(lines, "\n"):find("cancelled %(replaced by a new refresh%)") ~= nil,
    true
  )
end

T["it: postgres: `r` and stopping the dashboard stop the query on the server"] = function()
  local h = require("tests.helpers")
  h.require_it()
  local PG = "postgres://dbdash:dbdash_pw@127.0.0.1:15432/dbdash_test"
  local m = ("dbdash_cancel_%d"):format(math.random(1e9))
  local function running()
    return h.ok(
      PG,
      ("SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%%%s%%' AND pid <> pg_backend_pid()"):format(
        m
      )
    ).rows[1][1]
  end
  local function wait_for(n)
    vim.wait(5000, function()
      return running() == n
    end, 100)
    return running()
  end
  local d = start(([[
database: { url: "%s" }
query:
  sql: "SELECT pg_sleep(30) /* %s */"
show: { type: table, interval: 1h }
]]):format(PG, m))
  eq(wait_for(1), 1)
  d:restart() -- the old query stops, the new one runs
  vim.wait(1000)
  eq(wait_for(1), 1)
  sched.stop(d.path)
  eq(wait_for(0), 0)
end

return T
