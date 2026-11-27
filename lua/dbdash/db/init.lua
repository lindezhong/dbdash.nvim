-- DriverManager (ARCHITECTURE.md#data-sources): driver registry, URL dispatch and the query entry
-- points.
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
  if type(driver) ~= "table" or type(driver.name) ~= "string" then
    error("a driver is a table with a name", 0)
  end
  local connect, produce = type(driver.connect) == "function", type(driver.produce) == "function"
  if connect == produce then
    error(
      ("driver %s: give connect (a database, queried on every tick) or produce (a source that sends data), one of them"):format(
        driver.name
      ),
      0
    )
  end
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

---Server-side cancels still being sent: Neovim waits for them briefly when it exits.
---@return integer
function M.pending_cancels()
  return require("dbdash.db.driver").pending
end

---Run one query (the Lua API, dbdash.query in Lua code): a run of one tick, its first
---result. `callback(err, rs)` is invoked exactly once, on the main loop; handle:cancel(reason)
---stops the query (the callback gets the error at once, then the server stops it).
---@param raw_url string
---@param query string
---@param opts dbdash.db.QueryOpts?
---@param callback fun(err: dbdash.Error?, rs: dbdash.db.ResultSet?)
---@return { cancel: fun(self, reason: string?) }
function M.query(raw_url, query, opts, callback)
  opts = opts or {}
  local done, run, unlink = false, nil, nil
  local function finish(err, rs)
    if done then
      return
    end
    done = true
    if unlink then
      unlink()
    end
    callback(err, rs)
  end
  local handle = {
    cancel = function(_, reason)
      reason = reason or "cancelled"
      if not done then
        done = true -- (a result that comes now is dropped)
        if unlink then
          unlink()
        end
        vim.schedule(function()
          callback(dberr.new({ phase = "cancelled", message = "query cancelled: " .. reason }))
        end)
      end
      if run then
        run:stop(reason)
      end
    end,
  }
  local parent = opts.cancel
  if parent and parent.cancelled then
    handle:cancel(parent.reason)
    return handle
  end
  local ropts = vim.tbl_extend("force", {}, opts, { query_only = true })
  ropts.cancel = nil
  run = M.run(raw_url, query, ropts, function(err, rs)
    finish(err, rs)
  end, function(err)
    finish(err or dberr.new({ phase = "internal", message = "the query gave no result" }))
  end)
  if parent then
    unlink = parent:on_cancel(function(reason)
      handle:cancel(reason)
    end)
  end
  return handle
end

-- Push sources --------------------------------------------------------------------------------

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

---Run a data source. A driver with produce sends results until it returns (on_end(nil)),
---fails (on_end(err)) or is stopped; a driver with connect is queried on every tick of
---opts.wait_tick (once without it) and never ends by itself. handle:stop(reason) or
---opts.cancel stops the run: on_end gets a "cancelled" error.
---Every result goes to on_result(err, value, vars, tag) on the main loop, in order, before
---on_end: a query's error, or a value (a result set, a raw driver result, an item).
---@param query string|fun(): string, any the query, or a function rendering it on each tick
---@param opts dbdash.db.QueryOpts
---@param on_result fun(err: table?, value: any, vars: table?, tag: any)
---@param on_end fun(err: dbdash.Error?)
---@return { stop: fun(self, reason: string?), stats: { items: integer, truncated: integer } }
function M.run(raw_url, query, opts, on_result, on_end)
  opts = opts or {}
  local token = require("dbdash.db.cancel").new(opts.cancel)
  local stats = { items = 0, truncated = 0, rejected = {} } -- rejected: count by HTTP status
  local ctx
  local handle = {
    stats = stats,
    ---The consumer took a result: ok, or it failed (a database waits for this, and backs
    ---off after failures).
    report = function(_, ok)
      if ctx and ctx.report then
        ctx.report(ok)
      end
    end,
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
    local d = M.validate(expanded, opts.options)
    driver_name = d.name
    local i = url.parse(expanded)
    i.options = opts.options or {}
    i.base_dir = opts.base_dir
    if d.parse_url then
      i = d.parse_url(i)
    end
    return { driver = d, info = i }
  end)
  if not ok and not opts.wait_tick then
    finish(prep)
    return handle
  elseif not ok then
    -- A ticked run reports what is wrong on every tick, as each query does.
    prep = { error = prep, info = { options = opts.options or {} } }
  elseif opts.query_only and prep.driver.produce then
    finish(dberr.new({
      driver = driver_name,
      phase = "config",
      message = driver_name .. ":// is a push source: it runs as a stream (:help dbdash-push)",
    }))
    return handle
  end
  local max = require("dbdash.util.bytes").parse(defaults.current.max_record) or 1048576
  local lua_result = require("dbdash.db.lua_result")
  local function emit(value, vars, tag)
    if done then
      return
    end
    stats.items = stats.items + 1
    local err
    if not opts.raw and prep.driver and prep.driver.produce then
      -- an item without query.transform: JSON rows (or one record)
      local ok_rows, rows = pcall(function()
        local v = value
        if type(v) == "string" then
          local okj = pcall(vim.json.decode, v)
          if not okj then
            dberr.raise(
              "query",
              ("the item is not JSON rows (%s); add query.transform to read it (:help dbdash-push)"):format(
                vim.trim(v):sub(1, 60)
              )
            )
          end
          v = require("dbdash.util.json").decode(v)
        end
        if require("dbdash.util.map").is_map(v) and v.rows == nil then
          v = { v } -- one record (a form, the parameters of a request)
        end
        local max_rows = opts.max_rows or defaults.current.max_rows
        local rs = lua_result.normalize(v, { max_rows = max_rows, phase = "query", hint = true })
        rs.item = value -- the item as it came (meta.prev.query)
        return rs
      end)
      if ok_rows then
        value = rows
      else
        err, value = rows, nil
      end
    end
    vim.schedule(function()
      if not token.cancelled then
        on_result(err and dberr.wrap(err, driver_name) or nil, value, vars or {}, tag)
      end
    end)
  end
  local function fail(err, tag)
    if done then
      return
    end
    vim.schedule(function()
      if not token.cancelled then
        on_result(dberr.wrap(err, driver_name), nil, nil, tag)
      end
    end)
  end
  local once = true
  local function one_tick()
    local first = once
    once = false
    return first
  end
  ---@type dbdash.db.StreamCtx
  ctx = {
    opts = opts,
    ticked = opts.wait_tick ~= nil,
    prep_error = prep.error,
    emit = emit,
    fail = fail,
    wait_tick = opts.wait_tick or one_tick,
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
    if prep.driver and prep.driver.produce then
      prep.driver.produce(prep.info, type(query) == "function" and query() or query, ctx)
    else
      local producer = require("dbdash.db.driver").producer(prep.driver)
      producer(prep.driver and prep.info or nil, query, ctx)
    end
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

---Coroutine-style query for use inside util.async tasks. Raises an Error (util/error).
---@return dbdash.db.ResultSet
function M.query_async(raw_url, query, opts)
  local err, rs = async.await(M.query, raw_url, query, opts)
  if err then
    error(err, 0)
  end
  return rs
end

---Check a database URL (${NAME} expanded) and its options against its driver: the URL's
---parameters (tls, timeouts...) and the options the driver declares (driver.options).
---Raises a config error; returns the driver.
---@param raw_url string
---@param options table?
---@return dbdash.db.Driver
function M.validate(raw_url, options)
  local d = M.driver_for(raw_url)
  url.parse(raw_url)
  if d.options then
    require("dbdash.db.options").check(d.name, options or {}, d.options, {})
  end
  return d
end

---The message of an error raised by the data layer.
local function message(err)
  return type(err) == "table" and err.message or tostring(err)
end

-- The rules of a config's database (config/validators.lua): its driver (database.type, else
-- the URL's scheme), the URL's variables and parameters, password_cmd, the driver's options.
-- Gives the database with its type (the driver's name).
M.validators = {
  {
    field = "database",
    ---@param db { type: string?, url: string, password_cmd: any, options: table }
    validate = function(db, ctx, path)
      local expanded, env_err = require("dbdash.db.credentials").expand_env(db.url)
      if not expanded then
        ctx:fail(path .. ".url", "%s", env_err)
      end
      local cmd = db.password_cmd
      if cmd ~= nil then
        local ok = type(cmd) == "string" and cmd ~= ""
        if type(cmd) == "table" then
          ok = #cmd > 0
          for _, a in ipairs(cmd) do
            ok = ok and type(a) == "string"
          end
        end
        if not ok then
          ctx:fail(
            path .. ".password_cmd",
            "password_cmd must be a command string or a list of strings"
          )
        end
      end
      local scheme = expanded:match("^([%a][%w+.-]*)://")
      local name = db.type and db.type:lower() or scheme
      if name == "oracle" or (scheme and scheme:lower() == "oracle") then
        ctx:fail(path .. ".url", "Oracle is not supported by dbdash.nvim")
      elseif not name then
        ctx:fail(
          path .. ".url",
          "cannot infer database type from url %q; set database.type",
          db.url
        )
      end
      local ok, d = pcall(M.driver, name)
      if not ok then
        ctx:fail(path .. (db.type and ".type" or ".url"), "unsupported database type '%s'", name)
      end
      local uok, uerr = pcall(url.parse, expanded)
      if not uok then
        ctx:fail(path .. ".url", "%s", message(uerr))
      end
      if d.options then
        local oknames, oerr =
          pcall(require("dbdash.db.options").check, d.name, db.options or {}, d.options, {})
        if not oknames then
          ctx:fail(path .. ".options", "%s", message(oerr))
        end
      end
      db.type = d.name
      return db
    end,
  },
}

return M
