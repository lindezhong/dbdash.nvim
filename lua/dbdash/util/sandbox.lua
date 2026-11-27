-- Running Lua from a config safely: guard() stops code that runs too long or whose cancel
-- token was cancelled (lua:// queries, query.transform and Lua in templates), and the
-- `dbdash` helpers that need no data source.
local async = require("dbdash.util.async")

local M = {}

---The helpers of Lua code (`dbdash`) that need no data source (db/lua_env.lua adds
---dbdash.query).
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
}

-- Timeouts of guarded code. LuaJIT has one debug hook for all coroutines, so a single hook
-- checks the deadlines of the coroutine running now: a task waiting in guarded code (on a
-- query, a command) is not checked while other code runs, and guarded code inside guarded
-- code (dbdash.run() callbacks, modules) keeps the outer deadline too. The same hook stops
-- guarded code whose cancel token (db/cancel.lua) was cancelled.
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

return M
