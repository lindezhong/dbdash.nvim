-- DriverManager (design §8.2): driver registry, URL dispatch and the query entry points.
--
-- Every query is: parse url -> connect -> execute -> close (no pooling). close() is always
-- called, the whole operation is bounded by connect_timeout + timeout, and callbacks always
-- run on the main loop. A query can be cancelled (M.query's handle, opts.cancel).
local async = require("dbdash.util.async")
local dberr = require("dbdash.util.error")
local resultset = require("dbdash.db.resultset")
local url = require("dbdash.db.url")
local defaults = require("dbdash.db.defaults")

local M = {}

M.NULL = resultset.NULL
M.Error = dberr

---@class dbdash.db.ConnInfo: dbdash.db.Url
---@field options table driver-specific options from the config (database.options)
---@field base_dir string? directory of the config file (for relative sqlite paths)

---@class dbdash.db.ExecuteOpts
---@field max_rows integer
---@field timeout integer

---@class dbdash.db.Connection
---@field execute fun(self, query: string, opts: dbdash.db.ExecuteOpts): dbdash.db.ResultSet
---@field close fun(self)
---@field server_version fun(self): string?

---@class dbdash.db.Driver
---@field name string
---@field schemes string[]
---@field dialect string|dbdash.template.Dialect? how template values are written in its queries:
---  a dialect name of dbdash.template.dialect (default: the driver's name) or a dialect
---@field capabilities { tls: boolean, sql: boolean, query_language: string }
---@field parse_url (fun(u: dbdash.db.ConnInfo): dbdash.db.ConnInfo)?
---@field produce (fun(info: dbdash.db.ConnInfo, query: string, ctx: dbdash.db.StreamCtx))? a push
---   source (capabilities.push): produces data until it returns (:help dbdash-push)
---@field cancel (fun(conn: dbdash.db.Connection, info: dbdash.db.ConnInfo))? stop the query
---   running on `conn` on the server (inside a task, while the query's own task waits)
---@field connect fun(info: dbdash.db.ConnInfo): dbdash.db.Connection

local drivers = {} ---@type table<string, dbdash.db.Driver>
local by_scheme = {} ---@type table<string, dbdash.db.Driver>

local BUILTIN = {
  sqlite = "dbdash.db.drivers.sqlite",
  sqlite3 = "dbdash.db.drivers.sqlite",
  redis = "dbdash.db.drivers.redis",
  rediss = "dbdash.db.drivers.redis",
  postgres = "dbdash.db.drivers.postgres",
  postgresql = "dbdash.db.drivers.postgres",
  mysql = "dbdash.db.drivers.mysql",
  mariadb = "dbdash.db.drivers.mysql",
  cassandra = "dbdash.db.drivers.cassandra",
  cql = "dbdash.db.drivers.cassandra",
  mongodb = "dbdash.db.drivers.mongodb",
  lua = "dbdash.db.drivers.lua",
  luastream = "dbdash.db.drivers.luastream",
  exec = "dbdash.db.drivers.exec",
  webhook = "dbdash.db.drivers.webhook",
  http = "dbdash.db.drivers.http",
  https = "dbdash.db.drivers.http",
  mssql = "dbdash.db.drivers.mssql",
  sqlserver = "dbdash.db.drivers.mssql",
}

---Register a driver (built-in drivers register lazily on first use).
---@param driver dbdash.db.Driver
function M.register(driver)
  assert(type(driver.name) == "string", "driver.name is required")
  assert(type(driver.connect) == "function", "driver.connect is required")
  driver.schemes = driver.schemes or { driver.name }
  driver.dialect = driver.dialect or driver.name
  driver.capabilities = driver.capabilities or { tls = false, sql = true, query_language = "sql" }
  drivers[driver.name] = driver
  for _, s in ipairs(driver.schemes) do
    by_scheme[s] = driver
  end
end

---Driver by scheme or name; loads built-in drivers on demand.
---@param scheme string
---@return dbdash.db.Driver
function M.driver(scheme)
  scheme = scheme:lower():gsub("%+.*$", "")
  local d = by_scheme[scheme] or drivers[scheme]
  if d then
    return d
  end
  if scheme == "oracle" then
    dberr.raise("config", "Oracle is not supported by dbdash.nvim")
  end
  local mod = BUILTIN[scheme]
  if mod then
    local ok, res = pcall(require, mod)
    if ok then
      M.register(res)
      return res
    end
    if type(res) == "string" and res:find("module '" .. mod .. "' not found", 1, true) then
      dberr.raise("config", ("the %s driver is not implemented yet"):format(scheme))
    end
    error(res, 0)
  end
  dberr.raise("config", ("no driver for scheme '%s'"):format(scheme))
end

---Driver for a URL string (used by the template engine to pick a dialect).
---@param raw string
---@return dbdash.db.Driver
function M.driver_for(raw)
  local scheme = raw:match("^([%a][%w+.-]*)://")
  if not scheme then
    dberr.raise("config", ("invalid database url %q"):format(raw))
  end
  return M.driver(scheme)
end

---@class dbdash.db.QueryOpts
---@field max_rows integer? (default: dbdash.db.defaults)
---@field timeout integer? ms, overrides the url's timeout
---@field options table? driver options (database.options)
---@field base_dir string?
---@field password_cmd string|string[]? command printing the password (database.password_cmd)
---@field args table? dashboard arguments (lua:// scripts get them as `args`)
---@field meta table? dashboard metadata (lua:// scripts get it as `meta`)
---@field lua { store: table, helpers: table }? lua:// scripts: the panel's store and dbdash helpers
---@field source string? config file name for messages (lua:// error locations)
---@field line integer? line of the query in the config file (lua:// error locations)
---@field raw boolean? return a raw driver result (lua://, http) as is, for query.transform;
---   otherwise it is checked and turned into a result set
---@field allow_writes boolean? the query may write files (http(s):// curl -c cookie files);
---   set for configs that were trusted with it
---@field cancel dbdash.db.CancelToken? cancelling it stops the query (see M.query)
---@field on_status fun(text: string)? push sources: their status changed (M.stream)

-- Server-side cancels still being sent (see M.pending_cancels).
local pending = 0

---Server-side cancels still being sent: Neovim waits for them briefly when it exits.
---@return integer
function M.pending_cancels()
  return pending
end

---Run a query. `callback(err, rs)` is invoked exactly once, on the main loop. Returns a
---handle: handle:cancel(reason) stops the query.
---
---Stopping a query (cancelled, or its time is up) always goes the same way:
---  1. the client stops waiting: the callback gets the error at once (phase "cancelled" or
---     "timeout") and a result that comes later is dropped;
---  2. the server stops: driver.cancel(conn, info) when the connection is open (Postgres
---     CancelRequest, MySQL KILL QUERY, SQL Server attention, MongoDB killOp, SQLite
---     interrupt, Lua scripts stop); drivers without it (redis, cassandra, http) skip this;
---  3. the connection is closed.
---@param raw_url string
---@param query string
---@param opts dbdash.db.QueryOpts?
---@param callback fun(err: dbdash.db.DbError?, rs: dbdash.db.ResultSet?)
---@return { cancel: fun(self, reason: string?) }
function M.query(raw_url, query, opts, callback)
  opts = opts or {}
  local driver_name
  local done = false
  local timer
  local conn, driver, info
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
    pending = pending + 1
    async.run(function()
      if driver.cancel then
        pcall(driver.cancel, conn, info)
      end
      close_conn()
    end, function()
      pending = pending - 1
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

  local ok, prep = pcall(function()
    local expanded, env_err = require("dbdash.db.credentials").expand_env(raw_url)
    if not expanded then
      dberr.raise("config", env_err)
    end
    local d = M.driver_for(expanded)
    driver_name = d.name
    local i = url.parse(expanded)
    i.options = opts.options or {}
    i.base_dir = opts.base_dir
    if d.parse_url then
      i = d.parse_url(i)
    end
    return { driver = d, info = i }
  end)
  if not ok then
    finish(prep)
    return handle
  end
  driver, info = prep.driver, prep.info
  if driver.produce then
    finish(dberr.new({
      driver = driver_name,
      phase = "config",
      message = driver.name .. ":// is a push source: it runs as a stream (:help dbdash-push)",
    }))
    return handle
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

-- Push sources --------------------------------------------------------------------------------

---@class dbdash.db.StreamCtx what a push source's producer gets
---@field writer fun(delimiter: string?, vars: table?): fun(text: string) a stream: the text
---   written is cut at `delimiter` (default "\n"), each piece is one item
---@field emit fun(value: any, vars: table?) one item as it is
---@field cancel dbdash.db.CancelToken cancelled when the stream stops
---@field stats { items: integer, truncated: integer, rejected: table<integer, integer> }
---@field set_status fun(text: string) what the source is doing ("listening 127.0.0.1:8765"),
---   shown in the panel (handle.status, opts.on_status)
---@field on_stop fun(fn: fun()) cleanup when the stream ends or stops (kill a process, ...)
---@field base_dir string? the config file's directory
---@field options table database.options
---@field args table?, meta table?, lua table?, source string?, line integer? as for lua://
---@field timeout integer ms (query.timeout, else the URL's)

---Cut text at `delimiter` and pass each complete piece to `emit`. Pieces longer than
---`max` bytes are cut there (counted in stats.truncated); empty pieces are skipped.
---@return fun(text: string) write, fun() flush (the rest, at the end)
function M.splitter(delimiter, max, emit, stats)
  delimiter = delimiter or "\n"
  local buf, dropping = "", false
  local function piece(p)
    if delimiter == "\n" and p:sub(-1) == "\r" then
      p = p:sub(1, -2)
    end
    if p ~= "" then
      emit(p)
    end
  end
  local function write(text)
    buf = buf .. text
    while true do
      local i, j = buf:find(delimiter, 1, true)
      if not i then
        break
      end
      if dropping then
        dropping = false -- the rest of a piece that was too long
      else
        piece(buf:sub(1, i - 1))
      end
      buf = buf:sub(j + 1)
    end
    if #buf > max and not dropping then
      -- Too long without a delimiter: pass the first `max` bytes, drop the rest of it.
      stats.truncated = stats.truncated + 1
      piece(buf:sub(1, max))
      dropping = true
    end
    if dropping then
      buf = buf:sub(-(#delimiter - 1)) -- (a delimiter may start at the end)
      if #delimiter == 1 then
        buf = ""
      end
    end
  end
  local function flush()
    if not dropping then
      piece(buf)
    end
    buf, dropping = "", false
  end
  return write, flush
end

---Run a push source: its producer runs until it returns (on_end(nil)), fails (on_end(err))
---or is stopped (handle:stop(reason), or opts.cancel; on_end gets a "cancelled" error).
---Every item goes to on_item(value, vars) on the main loop, in order, before on_end.
---@param opts dbdash.db.QueryOpts
---@param on_item fun(value: any, vars: table)
---@param on_end fun(err: dbdash.db.DbError?)
---@return { stop: fun(self, reason: string?), stats: { items: integer, truncated: integer } }
function M.stream(raw_url, query, opts, on_item, on_end)
  opts = opts or {}
  local token = require("dbdash.db.cancel").new(opts.cancel)
  local stats = { items = 0, truncated = 0, rejected = {} } -- rejected: count by HTTP status
  local handle = {
    stats = stats,
    stop = function(_, reason)
      token:cancel(reason or "stopped")
    end,
  }
  local driver_name
  local done = false
  local stops, flushes = {}, {}
  local function finish(err)
    if done then
      return
    end
    done = true
    token:release()
    for i = #stops, 1, -1 do
      pcall(stops[i])
    end
    vim.schedule(function()
      on_end(err and dberr.wrap(err, driver_name) or nil)
    end)
  end
  token:on_cancel(function(reason)
    finish(dberr.new({
      driver = driver_name,
      phase = "cancelled",
      message = "stream stopped: " .. reason,
    }))
  end)
  local ok, prep = pcall(function()
    local expanded, env_err = require("dbdash.db.credentials").expand_env(raw_url)
    if not expanded then
      dberr.raise("config", env_err)
    end
    local d = M.driver_for(expanded)
    driver_name = d.name
    if not d.produce then
      dberr.raise("config", ("%s is not a push source"):format(d.name))
    end
    local i = url.parse(expanded)
    i.options = opts.options or {}
    i.base_dir = opts.base_dir
    if d.parse_url then
      i = d.parse_url(i)
    end
    return { driver = d, info = i }
  end)
  if not ok then
    finish(prep)
    return handle
  end
  local max = require("dbdash.util.bytes").parse(defaults.current.max_record) or 1048576
  local function emit(value, vars)
    if done then
      return
    end
    stats.items = stats.items + 1
    vim.schedule(function()
      if not token.cancelled then
        on_item(value, vars or {})
      end
    end)
  end
  ---@type dbdash.db.StreamCtx
  local ctx = {
    emit = emit,
    writer = function(delimiter, vars)
      local write, flush = M.splitter(delimiter, max, function(piece)
        emit(piece, vars)
      end, stats)
      flushes[#flushes + 1] = flush
      return write
    end,
    cancel = token,
    stats = stats,
    set_status = function(text)
      handle.status = text
      if opts.on_status then
        vim.schedule(function()
          if not done then
            opts.on_status(text)
          end
        end)
      end
    end,
    on_stop = function(fn)
      stops[#stops + 1] = fn
    end,
    base_dir = opts.base_dir,
    options = prep.info.options,
    args = opts.args,
    meta = opts.meta,
    lua = opts.lua,
    source = opts.source,
    line = opts.line,
    max_rows = opts.max_rows or defaults.current.max_rows,
    timeout = opts.timeout or prep.info.timeout, -- (luastream: the longest stretch without waiting)
  }
  async.run(function()
    prep.driver.produce(prep.info, query, ctx)
  end, function(err)
    if not err then
      for _, flush in ipairs(flushes) do
        flush() -- the last piece without a delimiter
      end
    end
    finish(err)
  end)
  return handle
end

---Coroutine-style query for use inside util.async tasks. Raises DbError.
---@return dbdash.db.ResultSet
function M.query_async(raw_url, query, opts)
  local err, rs = async.await(M.query, raw_url, query, opts)
  if err then
    error(err, 0)
  end
  return rs
end

return M
