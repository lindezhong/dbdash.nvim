-- DriverManager (design §8.2): driver registry, URL dispatch and the query entry points.
--
-- Every query is: parse url -> connect -> execute -> close (no pooling). close() is always
-- called, the whole operation is bounded by connect_timeout + timeout, and callbacks always
-- run on the main loop. A query can be cancelled (M.query's handle, opts.cancel).
local async = require("dbdash.util.async")
local dberr = require("dbdash.db.error")
local dialect = require("dbdash.db.dialect")
local resultset = require("dbdash.db.resultset")
local url = require("dbdash.db.url")

local M = {}

M.NULL = resultset.NULL
M.Error = dberr

---@class dbdash.db.ConnInfo: dbdash.db.Url
---@field options table driver-specific options from the config (database.options)
---@field base_dir string? directory of the config file (for relative sqlite paths)

---@class dbdash.db.Connection
---@field execute fun(self, query: string, opts: { max_rows: integer, timeout: integer }): dbdash.db.ResultSet
---@field close fun(self)
---@field server_version fun(self): string?

---@class dbdash.db.Driver
---@field name string
---@field schemes string[]
---@field dialect dbdash.db.Dialect?
---@field capabilities { tls: boolean, sql: boolean, query_language: string }
---@field parse_url (fun(u: dbdash.db.ConnInfo): dbdash.db.ConnInfo)?
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
  driver.dialect = driver.dialect or dialect.get(driver.name)
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
---@field max_rows integer?
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
---@field cookie_jar dbdash.http.Jar? cookies kept between http(s):// queries (one per dashboard)
---@field cancel dbdash.db.CancelToken? cancelling it stops the query (see M.query)

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
  local q_timeout = opts.timeout or info.timeout
  local exec_opts = {
    max_rows = opts.max_rows or require("dbdash").options.defaults.max_rows,
    timeout = q_timeout,
    args = opts.args,
    meta = opts.meta,
    lua = opts.lua,
    source = opts.source,
    line = opts.line,
    cookie_jar = opts.cookie_jar,
    cancel = token,
  }

  timer = vim.uv.new_timer()
  timer:start(info.connect_timeout + q_timeout, 0, function()
    vim.schedule(function()
      abort("timeout", ("query did not finish within %.1fs"):format((info.connect_timeout + q_timeout) / 1000))
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
