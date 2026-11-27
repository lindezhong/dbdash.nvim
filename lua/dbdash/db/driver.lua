-- The base of drivers with connect (databases): how one query runs (timeouts, cancelling
-- on the server) and their producer, a loop that queries on every tick of its run and
-- backs off after failures (ARCHITECTURE.md#data-sources).
local async = require("dbdash.util.async")
local dberr = require("dbdash.util.error")
local defaults = require("dbdash.db.defaults")

local M = {}

---Server-side cancels still being sent: Neovim waits for them briefly when it exits.
M.pending = 0

---Run one query on a driver with connect (`info`: its parsed URL). `callback(err, rs)` is
---invoked exactly once, on the main loop. Returns a handle: handle:cancel(reason) stops it.
---
---Stopping a query (cancelled, or its time is up) always goes the same way:
---  1. the client stops waiting: the callback gets the error at once (phase "cancelled" or
---     "timeout") and a result that comes later is dropped;
---  2. the server stops: driver.cancel(conn, info) when the connection is open (Postgres
---     CancelRequest, MySQL KILL QUERY, SQL Server attention, MongoDB killOp, SQLite
---     interrupt, Lua scripts stop); drivers without it (redis, cassandra, http) skip this;
---  3. the connection is closed.
---@param driver dbdash.db.Driver
---@param info dbdash.db.ConnInfo
---@param query string
---@param opts dbdash.db.QueryOpts?
---@param callback fun(err: dbdash.Error?, rs: dbdash.db.ResultSet?)
---@return { cancel: fun(self, reason: string?) }
function M.execute(driver, info, query, opts, callback)
  opts = opts or {}
  local driver_name = driver.name
  local done = false
  local timer
  local conn
  local closed, server_stopped = false, false
  -- This query's token: Lua code of the query (lua://) stops when it is cancelled.
  local token = require("dbdash.db.cancel").new()
  local unlink

  local function finish(err, rs)
    if done then
      return
    end
    done = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if unlink then
      unlink()
    end
    vim.schedule(function()
      callback(err and dberr.wrap(err, driver_name) or nil, rs)
    end)
  end

  local function close_conn()
    if conn and not closed then
      closed = true
      pcall(conn.close, conn)
    end
  end

  ---Steps 2 and 3: stop the query on the server, then close the connection (in a task:
  ---drivers talk to the server).
  local function stop_server()
    if server_stopped or not conn or closed then
      return
    end
    server_stopped = true
    M.pending = M.pending + 1
    async.run(function()
      if driver.cancel then
        pcall(driver.cancel, conn, info)
      end
      close_conn()
    end, function()
      M.pending = M.pending - 1
    end)
  end

  ---Stop the query: the caller gets the error now (step 1), then the server stops.
  local function abort(phase, message)
    if done then
      return
    end
    finish(dberr.new({ driver = driver_name, phase = phase, message = message }))
    token:cancel(message)
    stop_server()
  end

  local handle = {
    cancel = function(_, reason)
      abort("cancelled", "query cancelled: " .. (reason or "cancelled"))
    end,
  }
  if opts.cancel then
    if opts.cancel.cancelled then
      handle:cancel(opts.cancel.reason)
      return handle
    end
    unlink = opts.cancel:on_cancel(function(reason)
      handle:cancel(reason)
    end)
  end

  local q_timeout = opts.timeout or info.timeout
  local exec_opts = {
    max_rows = opts.max_rows or defaults.current.max_rows,
    timeout = q_timeout,
    args = opts.args,
    meta = opts.meta,
    lua = opts.lua,
    source = opts.source,
    line = opts.line,
    allow_writes = opts.allow_writes,
    cancel = token,
  }

  timer = vim.uv.new_timer()
  timer:start(info.connect_timeout + q_timeout, 0, function()
    vim.schedule(function()
      abort(
        "timeout",
        ("query did not finish within %.1fs"):format((info.connect_timeout + q_timeout) / 1000)
      )
    end)
  end)

  local started = vim.uv.hrtime()
  local credentials = require("dbdash.db.credentials")
  async.run(function()
    credentials.fill(info, opts.password_cmd)
    if done then
      return
    end
    local c = driver.connect(info)
    if done then -- stopped while connecting: nothing runs on the server yet
      pcall(c.close, c)
      return
    end
    conn = c
    local ok2, rs = pcall(conn.execute, conn, query, exec_opts)
    if not ok2 and type(rs) == "table" and rs.phase == "timeout" then
      stop_server() -- a read or write timed out: the query may still run on the server
    elseif not server_stopped then
      close_conn()
    end
    if not ok2 then
      error(rs, 0)
    end
    local lua_result = require("dbdash.db.lua_result")
    if lua_result.is_raw(rs) and not opts.raw then
      rs = lua_result.normalize(rs, { max_rows = exec_opts.max_rows, phase = "query", hint = true })
    end
    rs.elapsed_ms = (vim.uv.hrtime() - started) / 1e6
    return rs
  end, function(err, rs)
    if err and opts.password_cmd and type(err) == "table" and err.phase == "auth" then
      credentials.forget(opts.password_cmd, info) -- the password may have changed
    end
    finish(err, rs)
  end)
  return handle
end

---Delay before the next try after `failures` failures in a row: the interval doubled per
---failure after the first, at most interval x factor (errors.backoff).
---@return integer ms
function M.backoff_delay(interval, failures, factor)
  local mult = math.min(2 ^ math.max(failures - 1, 0), math.max(factor or 1, 1))
  return math.floor(interval * mult)
end

---The producer of a driver with connect: on every tick (ctx.wait_tick) the query (a
---function renders it anew: sql, a tag passed along with its result, and options of this
---query) runs once (M.execute); its result or error is passed on, and the loop waits for
---the consumer to report how it went (ctx.report). Failures in a row back off: the next
---query not before interval x 2^(n-1) (at most x opts.backoff) from now; it waits with
---ctx.wait_tick(not_before, failures) and lets earlier ticks pass. It does not end by
---itself: when wait_tick says the run stops (or it is stopped). A run without ticks of
---its own (db.query) queries once.
---@param driver dbdash.db.Driver
function M.producer(driver)
  ---@param ctx dbdash.db.StreamCtx
  return function(info, query, ctx)
    local opts = ctx.opts
    local failures = opts.failures or 0 -- (a restarted run goes on counting)
    local not_before
    local waiting, reported
    ctx.report = function(ok)
      if waiting then
        local w = waiting
        waiting = nil
        w(ok)
      else
        reported = ok
      end
    end
    ctx.on_stop(function()
      if waiting then
        local w = waiting
        waiting = nil
        w(nil)
      end
    end)
    ---How the consumer took the last result: true, false, or nil when the run stopped.
    local function outcome()
      if reported ~= nil then
        local r = reported
        reported = nil
        return r
      end
      return async.await(function(cb)
        waiting = cb
      end)
    end
    local function now()
      vim.uv.update_time()
      return vim.uv.now()
    end
    while ctx.wait_tick(not_before, failures) do
      local slack = math.max(50, math.floor((opts.interval or 0) / 100))
      if not (not_before and now() + slack < not_before) then -- (earlier ticks pass)
        local ok, sql, tag, extra = pcall(function()
          if type(query) == "function" then
            return query()
          end
          return query
        end)
        if not ok then
          ctx.fail(sql) -- the query could not be rendered
        elseif not info then
          ctx.fail(ctx.prep_error, tag) -- the URL or its driver is wrong: on every tick
        else
          local qopts = vim.tbl_extend("force", {}, opts, extra or {}, { cancel = ctx.cancel })
          local err, rs = async.await(M.execute, driver, info, sql, qopts)
          if ctx.cancel.cancelled then
            return
          end
          if err then
            ctx.fail(err, tag)
          else
            ctx.emit(rs, nil, tag)
          end
        end
        -- a run of one tick has no next query to wait for
        local result = ctx.ticked and outcome() or not ctx.ticked
        if result == nil then
          return
        elseif result then
          failures, not_before = 0, nil
        else
          failures = failures + 1
          local interval = opts.interval
          local delay = interval and M.backoff_delay(interval, failures, opts.backoff)
          not_before = delay and delay > interval and now() + delay or nil
        end
      end
    end
  end
end

return M
