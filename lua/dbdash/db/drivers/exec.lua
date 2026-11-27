-- exec:// push source: query.sql is a script run by database.options.interpreter (default
-- sh -c, cmd /c on Windows); what it writes (stdout, stderr or both) is cut into items at
-- the delimiter (:help dbdash-exec). It ends when the script exits.
local async = require("dbdash.util.async")
local dberr = require("dbdash.util.error")
local options = require("dbdash.db.options")

local M = {
  name = "exec",
  schemes = { "exec" },
  capabilities = { tls = false, sql = false, query_language = "script" },
}

local function strings(v)
  if type(v) ~= "table" or #v == 0 then
    return "must be a non-empty list of strings"
  end
  for _, x in ipairs(v) do
    if type(x) ~= "string" then
      return "must be a non-empty list of strings"
    end
  end
end

local SPEC = {
  interpreter = strings,
  capture = function(v)
    if v ~= "stdout" and v ~= "stderr" and v ~= "both" then
      return 'must be "stdout", "stderr" or "both"'
    end
  end,
  delimiter = options.delimiter,
  ok_codes = function(v)
    if type(v) ~= "table" or #v == 0 then
      return "must be a non-empty list of exit codes"
    end
    for _, x in ipairs(v) do
      if type(x) ~= "number" or x ~= math.floor(x) then
        return "must be a non-empty list of exit codes"
      end
    end
  end,
  cwd = "string",
  env = "map",
  stdin = "string",
}

---The interpreter used when database.options.interpreter is not set.
function M.default_interpreter()
  if jit.os == "Windows" then
    return { "cmd.exe", "/d", "/s", "/c" }
  end
  return { "sh", "-c" }
end

---@param ctx dbdash.db.StreamCtx
function M.produce(info, script, ctx)
  local o = options.check(
    "exec",
    info.options,
    SPEC,
    { capture = "stdout", delimiter = "\n", ok_codes = { 0 } }
  )
  local argv = vim.list_extend(vim.deepcopy(o.interpreter or M.default_interpreter()), { script })
  local cwd = options.dir("exec", o.cwd, ctx.base_dir)
  local env = {}
  for k, v in pairs(o.env or {}) do
    env[k] = tostring(v)
  end
  local out = o.capture ~= "stderr" and ctx.writer(o.delimiter, { stream = "stdout" }) or nil
  local err_w = o.capture ~= "stdout" and ctx.writer(o.delimiter, { stream = "stderr" }) or nil
  local tail = {} -- the last lines of stderr, for the error message
  local partial = ""
  local function keep_tail(data)
    partial = partial .. data
    for line in partial:gmatch("([^\n]*)\n") do
      tail[#tail + 1] = line:gsub("\r$", "")
      if #tail > 20 then
        table.remove(tail, 1)
      end
    end
    partial = partial:match("[^\n]*$")
  end

  local proc, exited
  ctx.on_stop(function()
    if proc and not exited then
      pcall(proc.kill, proc, "sigterm")
      vim.defer_fn(function()
        if not exited then
          pcall(proc.kill, proc, "sigkill")
        end
      end, 2000)
    end
  end)
  local res = async.await(function(cb)
    local ok, p = pcall(vim.system, argv, {
      cwd = cwd,
      env = next(env) and env or nil,
      stdin = o.stdin or false,
      text = false,
      stdout = out and function(_, data)
        if data then
          out(data)
        end
      end or false,
      stderr = function(_, data)
        if data then
          keep_tail(data)
          if err_w then
            err_w(data)
          end
        end
      end,
    }, function(r)
      exited = true
      cb(r)
    end)
    if not ok then
      exited = true
      cb({ spawn_error = tostring(p) })
    else
      proc = p
    end
  end)
  if res.spawn_error then
    dberr.raise("connect", ("cannot run %s: %s"):format(argv[1], res.spawn_error))
  end
  if ctx.cancel.cancelled then
    return
  end
  if partial ~= "" then
    tail[#tail + 1] = partial
  end
  if not vim.tbl_contains(o.ok_codes, res.code) then
    local why = res.signal and res.signal ~= 0 and ("killed by signal %d"):format(res.signal)
      or ("exited with code %d"):format(res.code)
    dberr.raise(
      "query",
      ("the script %s%s"):format(why, #tail > 0 and (":\n" .. table.concat(tail, "\n")) or "")
    )
  end
end

-- database.options this driver reads (dbdash.db.options)
M.options = SPEC

return M
