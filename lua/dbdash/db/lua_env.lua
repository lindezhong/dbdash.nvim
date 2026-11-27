-- Running Lua from a config (lua:// queries and query.transform) inside a util.async task.
-- Scripts see the globals (vim, io, ...) plus:
--   args              the dashboard arguments
--   meta              the dashboard metadata (read-only; see dbdash/metadata.lua)
--   dbdash.system()   run a command without blocking the editor -> { code, stdout, stderr }
--   dbdash.query()    run a query on any database -> result set (columns, rows)
--   dbdash.sleep(ms), dbdash.checkpoint(), dbdash.null (NULL in results)
--   dbdash.safe(s)    (templates) output s as is, even with autoescape
--   store             the panel's table kept for as long as the dashboard runs
local async = require("dbdash.util.async")
local dberr = require("dbdash.util.error")

local M = {}

---The helpers given to scripts as `dbdash`.
M.helpers = {
  null = vim.NIL,
  safe = function(s)
    return require("dbdash.util.markup").safe(tostring(s))
  end,
  checkpoint = async.checkpoint,
  sleep = async.sleep,
  ---@param cmd string|string[] a string runs through the shell (sh -c / cmd /c)
  ---@param opts table? vim.system options (cwd, env, stdin, timeout, ...)
  system = function(cmd, opts)
    opts = vim.tbl_extend("keep", opts or {}, { text = true })
    local r = async.await(function(cb)
      vim.system(require("dbdash.util.shell").argv(cmd), opts, cb)
    end)
    return { code = r.code, stdout = r.stdout or "", stderr = r.stderr or "", signal = r.signal }
  end,
  ---@param url string
  ---@param query string
  ---@param opts table? max_rows, timeout, options
  ---   raw = true: the raw result of lua:// / http(s):// instead of rows (value, response)
  query = function(url, query, opts)
    -- Cancelling the code that runs this (its refresh) cancels the query too.
    opts = vim.tbl_extend(
      "force",
      {},
      opts or {},
      { cancel = (opts or {}).cancel or M.current_cancel() }
    )
    local rs = require("dbdash.db").query_async(url, query, opts)
    local lua_result = require("dbdash.db.lua_result")
    if lua_result.is_raw(rs) then
      return rs.value, rs.vars.response
    end
    return rs
  end,
}

---Message of an error raised by a script: strings keep their "file:line:" prefix, tables
---their message field.
local function message_of(e)
  if type(e) == "table" then
    return e.message or vim.inspect(e)
  end
  return tostring(e)
end

-- Timeouts of guarded code. LuaJIT has one debug hook for all coroutines, so a single hook
-- checks the deadlines of the coroutine running now: a task waiting in guarded code (on a
-- query, a command) is not checked while other code runs, and guarded code inside guarded
-- code (dbdash.run() callbacks, modules) keeps the outer deadline too. The same hook stops
-- guarded code whose cancel token (dbdash.db.cancel) was cancelled.
-- coroutine -> { { at, timeout, token, done } }
local deadlines = setmetatable({}, { __mode = "k" })

local function timeout_hook()
  local co = coroutine.running()
  local list = co and deadlines[co]
  if not list then
    if next(deadlines) == nil then
      debug.sethook() -- nothing guarded any more (e.g. its coroutine was collected)
    end
    return
  end
  local t = vim.uv.hrtime()
  for i, d in ipairs(list) do
    if not d.done then
      local cancelled = d.token and d.token.cancelled
      local started = d.slice and async.slice_start(co)
      local stalled = started and t - started > d.slice * 1e6
      if cancelled or stalled or t > d.at then
        -- Raise once for the outermost stopped entry; the inner ones end with it.
        for j = i, #list do
          list[j].done = true
        end
        if cancelled then
          error({ message = "query cancelled: " .. d.token.reason, cancelled = true }, 0)
        elseif stalled then
          error({
            message = ("script ran %.1fs without waiting (dbdash.sleep, dbdash.checkpoint, ...)"):format(
              d.slice / 1000
            ),
            timeout = true,
          }, 0)
        end
        error({
          message = ("script did not finish within %.1fs"):format(d.timeout / 1000),
          timeout = true,
        }, 0)
      end
    end
  end
end

---Call fn() and stop it when it runs longer than `timeout` ms: the count hook raises
---{ timeout = true, message } (pure Lua loops included); or when `token` is cancelled:
---{ cancelled = true, message }. Returns pcall's results.
---@param token dbdash.db.CancelToken?
---@param slice integer? ms the code may run without waiting (a task's time slice); code
---   that may run for ever (luastream://) has no timeout but this
---@return boolean ok, any result_or_error
function M.guard(fn, timeout, token, slice)
  -- Interpreted code so the count hook can stop a runaway loop after the timeout.
  jit.off(fn, true)
  local co = coroutine.running()
  if not ((timeout or token or slice) and co) then
    return pcall(fn)
  end
  local list = deadlines[co]
  if not list then
    list = {}
    deadlines[co] = list
  end
  local entry = {
    at = timeout and vim.uv.hrtime() + timeout * 1e6 or math.huge,
    timeout = timeout,
    token = token,
    slice = slice,
  }
  list[#list + 1] = entry
  if debug.gethook() ~= timeout_hook then
    debug.sethook(timeout_hook, "", 10000)
  end
  local ok, ret = pcall(fn)
  entry.done = true
  for i = #list, 1, -1 do
    if list[i] == entry then
      table.remove(list, i)
      break
    end
  end
  if #list == 0 then
    deadlines[co] = nil
    if next(deadlines) == nil then
      debug.sethook()
    end
  end
  return ok, ret
end

---The cancel token of the guarded code running now (innermost), if any.
---@return dbdash.db.CancelToken?
function M.current_cancel()
  local co = coroutine.running()
  local list = co and deadlines[co]
  for i = #(list or {}), 1, -1 do
    if list[i].token and not list[i].done then
      return list[i].token
    end
  end
end

---@class dbdash.db.lua_env.RunOpts
---@field phase string
---@field source string?
---@field line integer?
---@field args table?
---@field meta table?
---@field lua table?
---@field vars table?
---@field timeout integer?
---@field max_rows integer?
---@field cancel dbdash.db.CancelToken?
---@field slice integer?

---Compile and run `code`. Must be called inside a util.async task.
---@param code string
---@param o dbdash.db.lua_env.RunOpts
---   vars: extra globals (e.g. rs for transform); line: line of the code in the config file;
---   lua: { store, helpers } of the panel's run (store, and dbdash with the run's helpers)
---@return any value what the script returned (checked as rows by db/lua_result.lua)
function M.run(code, o)
  local name = o.source or "lua"
  -- Leading newlines make error line numbers match the config file.
  local prefix = string.rep("\n", math.max((o.line or 1) - 1, 0))
  local g = o.lua or {}
  local env = setmetatable({
    args = o.args or {},
    meta = require("dbdash.util.readonly").proxy(o.meta or {}, "meta"),
    store = g.store or {},
    dbdash = g.helpers or M.helpers,
  }, { __index = _G })
  for k, v in pairs(o.vars or {}) do
    env[k] = v
  end
  local fn, cerr = load(prefix .. code, "@" .. name, "t", env)
  if not fn then
    dberr.raise(o.phase, "syntax error: " .. tostring(cerr))
  end
  local ok, ret = M.guard(fn, o.timeout, o.cancel, o.slice)
  if not ok then
    if type(ret) == "table" and ret.timeout then
      dberr.raise("timeout", ret.message)
    elseif type(ret) == "table" and ret.cancelled then
      dberr.raise("cancelled", ret.message)
    end
    if type(ret) == "table" and ret.phase and ret.message then
      error(ret, 0) -- a DbError from dbdash.query
    end
    dberr.raise(o.phase, message_of(ret))
  end
  -- Arguments the script assigned (args.x = v) apply now (see scheduler Panel:sync_args).
  if g.after then
    local aok, aerr = pcall(g.after)
    if not aok then
      dberr.raise(o.phase, message_of(aerr))
    end
  end
  return ret
end

return M
