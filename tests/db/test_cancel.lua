-- Cancelling queries (db.query's handle, opts.cancel tokens, timeouts): the caller gets the
-- error at once, then the driver stops the query on the server, then the connection closes.
local db = require("dbdash.db")
local cancel = require("dbdash.db.cancel")
local async = require("dbdash.util.async")
local resultset = require("dbdash.db.resultset")
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

-- A driver that logs what happens: connect (slow for host "slowconnect"), execute (slow for
-- "slow"), cancel (only for scheme cancelfake) and close.
local log = {}
local function fake(name, with_cancel)
  db.register({
    name = name,
    schemes = { name },
    connect = function(info)
      log[#log + 1] = "connect"
      if info.host == "slowconnect" then
        async.sleep(300)
      end
      return {
        execute = function(_, q)
          log[#log + 1] = "execute"
          if q == "slow" then
            async.sleep(3000)
          end
          return resultset.new({ { name = "x", type = "integer" } }, { { 1 } })
        end,
        close = function()
          log[#log + 1] = "close"
        end,
      }
    end,
    cancel = with_cancel and function()
      log[#log + 1] = "cancel"
    end or nil,
  })
end
fake("cancelfake", true)
fake("nocancelfake", false)

---Start a query; returns the handle and a function that waits for its callback.
local function start(url, q, opts)
  local calls = {}
  local handle = db.query(url, q, opts or {}, function(err, rs)
    calls[#calls + 1] = { err = err, rs = rs }
  end)
  local function wait(ms)
    vim.wait(ms or 2000, function()
      return #calls > 0
    end, 5)
    return calls
  end
  return handle, wait, calls
end

local function settle()
  vim.wait(2000, function()
    return db.pending_cancels() == 0
  end, 5)
  vim.wait(50)
end

T["cancel: the caller gets the error at once, then cancel and close"] = function()
  log = {}
  local handle, wait = start("cancelfake://h", "slow")
  vim.wait(100, function()
    return log[2] == "execute"
  end, 5)
  local t0 = vim.uv.hrtime()
  handle:cancel("by the test")
  local calls = wait()
  eq(#calls, 1)
  eq((vim.uv.hrtime() - t0) / 1e6 < 500, true)
  eq({ calls[1].err.phase, calls[1].err.message }, { "cancelled", "query cancelled: by the test" })
  settle()
  eq(log, { "connect", "execute", "cancel", "close" })
  eq(db.pending_cancels(), 0)
end

T["cancel: twice is the same as once; the late result is dropped"] = function()
  log = {}
  local handle, wait, calls = start("cancelfake://h", "slow")
  vim.wait(100, function()
    return log[2] == "execute"
  end, 5)
  handle:cancel("one")
  handle:cancel("two")
  wait()
  vim.wait(3500) -- the driver's execute returns meanwhile
  eq(#calls, 1)
  eq(calls[1].err.message, "query cancelled: one")
  eq(log, { "connect", "execute", "cancel", "close" })
end

T["cancel: while connecting nothing runs on the server; the connection is closed"] = function()
  log = {}
  local handle, wait = start("cancelfake://slowconnect", "slow")
  vim.wait(50)
  handle:cancel("early")
  eq(wait()[1].err.phase, "cancelled")
  vim.wait(600)
  eq(log, { "connect", "close" })
end

T["cancel: a driver without cancel only closes the connection"] = function()
  log = {}
  local handle, wait = start("nocancelfake://h", "slow")
  vim.wait(100, function()
    return log[2] == "execute"
  end, 5)
  handle:cancel("x")
  eq(wait()[1].err.phase, "cancelled")
  settle()
  eq(log, { "connect", "execute", "close" })
end

T["cancel: a token stops every query registered on it, and later ones at once"] = function()
  log = {}
  local token = cancel.new()
  local _, wait1 = start("cancelfake://h", "slow", { cancel = token })
  local _, wait2 = start("cancelfake://h", "slow", { cancel = token })
  vim.wait(200, function()
    return #log >= 4
  end, 5)
  token:cancel("refresh replaced")
  eq(wait1()[1].err.message, "query cancelled: refresh replaced")
  eq(wait2()[1].err.message, "query cancelled: refresh replaced")
  settle()
  local _, wait3 = start("cancelfake://h", "fast", { cancel = token })
  eq(wait3()[1].err.message, "query cancelled: refresh replaced")
  vim.wait(100)
  eq(#vim.tbl_filter(function(l)
    return l == "connect"
  end, log), 2) -- the third one did not connect
end

T["cancel: a child token follows its parent; release() stops that"] = function()
  local parent = cancel.new()
  local a, b = cancel.new(parent), cancel.new(parent)
  b:release()
  parent:cancel("why")
  eq({ a.cancelled, a.reason, b.cancelled }, { true, "why", false })
  local got
  a:on_cancel(function(r)
    got = r
  end)
  eq(got, "why") -- registered after: runs at once
end

T["cancel: a query that finished is not cancelled"] = function()
  log = {}
  local handle, wait = start("cancelfake://h", "fast")
  local calls = wait()
  handle:cancel("late")
  settle()
  eq({ #calls, calls[1].err }, { 1, nil })
  eq(log, { "connect", "execute", "close" })
end

T["timeout: the same steps as a cancel, with phase timeout"] = function()
  log = {}
  local _, wait = start("cancelfake://h?connect_timeout=100ms", "slow", { timeout = 200 })
  local calls = wait(3000)
  eq(calls[1].err.phase, "timeout")
  settle()
  eq(log, { "connect", "execute", "cancel", "close" })
end

T["sqlite: a query that never ends stops on cancel"] = function()
  local handle, wait = start(
    "sqlite:///:memory:",
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c",
    { timeout = 60000 }
  )
  vim.wait(200)
  handle:cancel("test")
  eq(wait(1000)[1].err.phase, "cancelled")
  settle()
  -- The worker thread is free again: another query runs.
  eq(h.ok("sqlite:///:memory:", "SELECT 7").rows[1][1], 7)
end

T["lua://: a script that never ends stops on cancel"] = function()
  local handle, wait = start("lua://", "while true do dbdash.checkpoint() end", { timeout = 60000 })
  vim.wait(200)
  handle:cancel("test")
  local calls = wait(1000)
  eq(calls[1].err.phase, "cancelled")
  settle()
end

T["lua://: cancelling the script cancels the query it waits for"] = function()
  log = {}
  local handle, wait =
    start("lua://", "return dbdash.query('cancelfake://h', 'slow')", { timeout = 60000 })
  vim.wait(300, function()
    return log[2] == "execute"
  end, 5)
  handle:cancel("outer")
  eq(wait()[1].err.phase, "cancelled")
  settle()
  eq(log, { "connect", "execute", "cancel", "close" })
end

T["lua_env.guard: a cancelled token stops a running loop"] = function()
  local env = require("dbdash.db.lua_env")
  local token = cancel.new()
  local res
  async.run(function()
    return env.guard(function()
      local i = 0
      while true do
        i = i + 1
        if i % 100000 == 0 then
          async.sleep(1)
        end
      end
    end, nil, token)
  end, function(err, ok, ret)
    res = { err = err, ok = ok, ret = ret }
  end)
  vim.wait(100)
  token:cancel("stop")
  vim.wait(1000, function()
    return res ~= nil
  end, 5)
  eq({ res.ok, res.ret.cancelled, res.ret.message }, { false, true, "query cancelled: stop" })
end

-- Integration: the query stops on the server (it would run on for 30 s otherwise).

---Poll `count()` until it is 0 (the server dropped the query) or 5 s pass.
local function gone(count)
  local n
  for _ = 1, 50 do
    n = count()
    if n == 0 then
      return true
    end
    vim.wait(100)
  end
  return n
end

local function marker()
  return ("dbdash_cancel_%d"):format(math.random(1e9))
end

local PG = "postgres://dbdash:dbdash_pw@127.0.0.1:15432/dbdash_test"
local MY = "mysql://dbdash:dbdash_pw@127.0.0.1:13306/dbdash_test"
local MS = "mssql://sa:Dbdash_pw1@127.0.0.1:11433/master"
local MG = "mongodb://dbdash:dbdash_pw@127.0.0.1:17017/dbdash_test?authSource=admin"

---Start a slow query, wait until the server runs it, then stop it with `stop(handle)`
---(nil: let it time out) and check that the server no longer runs it.
local function server_stops(url, q, running, opts, stop)
  local handle, wait = start(url, q, opts)
  vim.wait(5000, function()
    return running() > 0
  end, 100)
  eq(running() > 0, true)
  if stop then
    stop(handle)
  end
  local calls = wait(10000)
  eq(calls[1].err ~= nil, true)
  settle()
  eq(gone(running), true)
  return calls[1].err
end

T["it: postgres: CancelRequest stops the query"] = function()
  h.require_it()
  for _, url in ipairs({ PG, PG .. "?tls=require" }) do
    local m = marker()
    local function running()
      return h.ok(
        PG,
        ("SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%%%s%%' AND pid <> pg_backend_pid()"):format(
          m
        )
      ).rows[1][1]
    end
    local err = server_stops(
      url,
      ("SELECT pg_sleep(30) /* %s */"):format(m),
      running,
      {},
      function(hd)
        hd:cancel("test")
      end
    )
    eq(err.phase, "cancelled")
  end
end

T["it: postgres: a timeout stops the query on the server too"] = function()
  h.require_it()
  local m = marker()
  local function running()
    return h.ok(
      PG,
      ("SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%%%s%%' AND pid <> pg_backend_pid()"):format(
        m
      )
    ).rows[1][1]
  end
  -- The whole query may take connect_timeout + timeout. The timeout leaves the check time
  -- to see the query on the server first: each check is a connection of its own, slow over
  -- a tunnel to the docker host (tests on another machine, README).
  local err = server_stops(
    PG .. "?connect_timeout=1s",
    ("SELECT pg_sleep(30) /* %s */"):format(m),
    running,
    { timeout = 5000 }
  )
  eq(err.phase, "timeout")
end

T["it: mysql: KILL QUERY stops the query"] = function()
  h.require_it()
  local m = marker()
  local function running()
    return h.ok(
      MY,
      ("SELECT count(*) FROM information_schema.processlist WHERE info LIKE '%%%s%%' AND id <> CONNECTION_ID()"):format(
        m
      )
    ).rows[1][1]
  end
  local err = server_stops(MY, ("SELECT SLEEP(30) /* %s */"):format(m), running, {}, function(hd)
    hd:cancel("test")
  end)
  eq(err.phase, "cancelled")
end

T["it: mssql: attention stops the batch"] = function()
  h.require_it()
  local m = marker()
  local function running()
    return h.ok(
      MS,
      ([[SELECT count(*) FROM sys.dm_exec_requests r CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
      WHERE t.text LIKE '%%%s%%' AND r.session_id <> @@SPID]]):format(m)
    ).rows[1][1]
  end
  local err = server_stops(
    MS,
    ("WAITFOR DELAY '00:00:30' /* %s */"):format(m),
    running,
    {},
    function(hd)
      hd:cancel("test")
    end
  )
  eq(err.phase, "cancelled")
end

T["it: mongodb: killOp stops the operation"] = function()
  h.require_it()
  local coll = marker()
  -- (JSON text: the command name must come first)
  h.ok(
    MG,
    ('{"operation": "command", "command": {"insert": "%s", "documents": [{"x": 1}]}}'):format(coll)
  )
  local function running()
    local rs = h.ok(
      MG,
      vim.json.encode({
        database = "admin",
        operation = "aggregate",
        pipeline = {
          { ["$currentOp"] = vim.empty_dict() },
          { ["$match"] = { ["command.find"] = coll } },
        },
      })
    )
    return rs.row_count
  end
  local q = vim.json.encode({ collection = coll, filter = { ["$where"] = "sleep(30000) || true" } })
  local err = server_stops(MG, q, running, {}, function(hd)
    hd:cancel("test")
  end)
  eq(err.phase, "cancelled")
  h.ok(MG, ('{"operation": "command", "command": {"drop": "%s"}}'):format(coll))
end

-- driver.cancel on its own: the connection stays open, so the query can only end early
-- because the server stopped it (closing the connection alone also stops it on some
-- servers, which the tests above cannot tell apart).
local function driver_cancel_ends_query(raw, q)
  local url = require("dbdash.db.url")
  local drv = db.driver_for(raw)
  local info = url.parse(raw) --[[@as dbdash.db.ConnInfo]]
  info.options = {}
  if drv.parse_url then
    info = drv.parse_url(info)
  end
  local conn, done, err
  local t0 = vim.uv.hrtime()
  async.run(function()
    conn = drv.connect(info)
    conn:execute(q, { max_rows = 10, timeout = 60000, cancel = require("dbdash.db.cancel").new() })
  end, function(e)
    done, err = vim.uv.hrtime(), e
  end)
  vim.wait(5000, function()
    return conn ~= nil
  end, 10)
  vim.wait(1000)
  eq(done, nil) -- still running
  async.run(function()
    drv.cancel(conn, info)
  end)
  vim.wait(10000, function()
    return done ~= nil
  end, 10)
  eq(done ~= nil and (done - t0) / 1e9 < 15, true)
  async.run(function()
    conn:close()
  end)
  return err
end

T["it: driver.cancel alone stops the query (postgres, mysql, mssql, mongodb)"] = function()
  h.require_it()
  driver_cancel_ends_query(PG, "SELECT pg_sleep(30)")
  driver_cancel_ends_query(MY, "SELECT SLEEP(30)")
  driver_cancel_ends_query(MS, "WAITFOR DELAY '00:00:30'")
  local coll = marker()
  h.ok(
    MG,
    ('{"operation": "command", "command": {"insert": "%s", "documents": [{"x": 1}]}}'):format(coll)
  )
  local err = driver_cancel_ends_query(
    MG,
    vim.json.encode({ collection = coll, filter = { ["$where"] = "sleep(30000) || true" } })
  )
  eq(err ~= nil and tostring(err.message or err):find("interrupt") ~= nil, true)
  h.ok(MG, ('{"operation": "command", "command": {"drop": "%s"}}'):format(coll))
end

return T
