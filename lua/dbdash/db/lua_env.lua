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
local dberr = require("dbdash.db.error")

local M = {}

---The helpers given to scripts as `dbdash`.
M.helpers = {
  null = vim.NIL,
  safe = function(s)
    return require("dbdash.template.runtime").safe(tostring(s))
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

---Call fn() and stop it when it runs longer than `timeout` ms: an instruction-count hook
---raises { timeout = true, message } (pure Lua loops included). Returns pcall's results.
---@return boolean ok, any result_or_error
function M.guard(fn, timeout)
  -- Interpreted code so the count hook can stop a runaway loop after the timeout.
  jit.off(fn, true)
  local co = coroutine.running()
  local deadline = timeout and co and (vim.uv.hrtime() + timeout * 1e6) or nil
  if deadline then
    debug.sethook(co, function()
      if vim.uv.hrtime() > deadline then
        debug.sethook(co)
        error({ message = ("script did not finish within %.1fs"):format(timeout / 1000), timeout = true }, 0)
      end
    end, "", 10000)
  end
  local ok, ret = pcall(fn)
  if deadline then
    debug.sethook(co)
  end
  return ok, ret
end

---Compile and run `code`. Must be called inside a util.async task.
---@param code string
---@param o { phase: string, source: string?, line: integer?, args: table?, meta: table?, lua: table?, vars: table?, timeout: integer?, max_rows: integer? }
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
    meta = require("dbdash.metadata").for_lua(o.meta or {}),
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
  local ok, ret = M.guard(fn, o.timeout)
  if not ok then
    if type(ret) == "table" and ret.timeout then
      dberr.raise("timeout", ret.message)
    end
    if type(ret) == "table" and ret.phase and ret.message then
      error(ret, 0) -- a DbError from dbdash.query
    end
    dberr.raise(o.phase, message_of(ret))
  end
  return ret
end

return M
