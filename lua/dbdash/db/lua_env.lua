-- Running Lua from a config (lua:// queries and query.transform) inside a util.async task.
-- Scripts see the globals (vim, io, ...) plus:
--   args              the dashboard arguments
--   meta              the dashboard metadata (read-only; see dbdash/metadata.lua)
--   dbdash.system()   run a command without blocking the editor -> { code, stdout, stderr }
--   dbdash.query()    run a query on any database -> result set (columns, rows)
--   dbdash.sleep(ms), dbdash.checkpoint(), dbdash.null (NULL in results)
--   dbdash.safe(s)    (templates) output s as is, even with autoescape
--   store             the panel's table kept for as long as the dashboard runs
local dberr = require("dbdash.util.error")

local M = {}

local sandbox = require("dbdash.util.sandbox")

---The helpers given to scripts as `dbdash`: those of util/sandbox.lua and dbdash.query.
M.helpers = vim.tbl_extend("force", {}, sandbox.helpers, {
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
      local raw = rs ---@type any (a raw result: value, vars)
      return raw.value, raw.vars.response
    end
    return rs
  end,
})

M.guard, M.current_cancel = sandbox.guard, sandbox.current_cancel

---Message of an error raised by a script: strings keep their "file:line:" prefix, tables
---their message field.
local function message_of(e)
  if type(e) == "table" then
    return e.message or vim.inspect(e)
  end
  return tostring(e)
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
  -- Arguments the script assigned (args.x = v) apply now (see Run:sync_args, dashboard/run.lua).
  if g.after then
    local aok, aerr = pcall(g.after)
    if not aok then
      dberr.raise(o.phase, message_of(aerr))
    end
  end
  return ret
end

return M
