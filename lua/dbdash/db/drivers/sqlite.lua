-- SQLite driver (:help dbdash-databases): LuaJIT FFI over the system libsqlite3.
--
-- FFI calls block, so open/prepare/step/close run in a vim.uv.new_work thread. The thread
-- returns JSON with tagged cells, decoded and type-mapped on the main loop:
--   "N" null, "I" integer (decimal text, exact), "R" real, "S" real that JSON cannot carry
--   ("inf", "-inf", "nan"), "T" UTF-8 text, "X" text that is not valid UTF-8 (hex),
--   "B" blob (hex).
-- A progress handler enforces the query timeout inside SQLite (SQLITE_INTERRUPT).
--
-- database.options: lib_path (library to load), readonly (open read-only),
-- create (create the file when missing; off by default so a typo does not create a db).
local async = require("dbdash.util.async")
local dberr = require("dbdash.util.error")
local resultset = require("dbdash.db.resultset")

local M = {
  name = "sqlite",
  schemes = { "sqlite", "sqlite3" },
  dialect = "sqlite",
  capabilities = { tls = false, sql = true, query_language = "sql" },
}

-- Runs in a worker thread (it shares nothing with the main loop: no upvalues): loads
-- sqlite_thread.lua from its source (`code`) there and runs the query. Arguments and
-- result are strings.
local function worker(code, ...)
  return assert(loadstring(code, "=sqlite_thread.lua"))().run(...)
end

---The source of sqlite_thread.lua (read once).
local thread_code
local function thread_source()
  if not thread_code then
    local here = debug.getinfo(1, "S").source:sub(2)
    local f = assert(io.open(vim.fs.dirname(here) .. "/sqlite_thread.lua", "rb"))
    thread_code = f:read("*a")
    f:close()
  end
  return thread_code
end

-- Main-loop side -------------------------------------------------------------------------

local function unhex(s)
  return (s:gsub("%x%x", function(h)
    return string.char(tonumber(h, 16))
  end))
end

---Logical type from a declared type, following SQLite's affinity rules plus common names.
---@param decl string
---@return dbdash.db.LogicalType?
function M.decl_type(decl)
  local d = decl:upper()
  if d == "" then
    return nil
  elseif d:find("BOOL") then
    return "boolean"
  elseif d:find("DATETIME") or d:find("TIMESTAMP") then
    return "datetime"
  elseif d == "DATE" then
    return "date"
  elseif d == "TIME" then
    return "time"
  elseif d:find("JSON") then
    return "json"
  elseif d:find("UUID") then
    return "uuid"
  elseif d:find("INT") then
    return "integer"
  elseif d:find("CHAR") or d:find("CLOB") or d:find("TEXT") then
    return "string"
  elseif d:find("BLOB") then
    return "bytes"
  elseif d:find("REAL") or d:find("FLOA") or d:find("DOUB") then
    return "number"
  elseif d:find("DEC") or d:find("NUMERIC") then
    return "decimal"
  end
  return "unknown"
end

local CLASS_TYPE =
  { I = "integer", R = "number", S = "number", T = "string", X = "bytes", B = "bytes" }

---Decode one tagged cell into a Lua value of the column's logical type.
local function cell(tag, raw, ltype)
  if tag == "N" then
    return resultset.NULL
  end
  local v
  if tag == "I" then
    v = resultset.integer(raw)
  elseif tag == "R" then
    v = raw
  elseif tag == "S" then
    v = raw == "nan" and 0 / 0 or (raw == "inf" and math.huge or -math.huge)
  elseif tag == "T" then
    v = raw
  else -- X, B
    v = unhex(raw)
  end
  if ltype == "boolean" and (tag == "I" or tag == "R") then
    return v ~= 0 and v ~= "0"
  elseif ltype == "json" and tag == "T" then
    return require("dbdash.util.json").decode(v)
  elseif ltype == "decimal" and (tag == "I" or tag == "R") then
    return type(v) == "number" and require("dbdash.util.number").numstr(v) or v
  end
  return v
end

---@param res table decoded worker result
---@return dbdash.db.ResultSet
local function build(res)
  local ncol = #res.columns
  local columns = {}
  for i, c in ipairs(res.columns) do
    local lt = M.decl_type(c.decltype)
    if not lt then -- no declared type (expressions): use the first non-NULL storage class
      lt = "null"
      for _, row in ipairs(res.rows) do
        local tag = row[2 * i - 1]
        if tag ~= "N" then
          lt = CLASS_TYPE[tag]
          break
        end
      end
    end
    columns[i] = { name = c.name, type = lt, db_type = c.decltype ~= "" and c.decltype or nil }
  end
  local rows = {}
  for r, row in ipairs(res.rows) do
    local out = {}
    for i = 1, ncol do
      out[i] = cell(row[2 * i - 1], row[2 * i], columns[i].type)
    end
    rows[r] = out
  end
  return resultset.new(columns, rows, { truncated = res.truncated, affected = res.affected })
end

---Resolve relative and ~ paths against the config directory.
---@param info dbdash.db.ConnInfo
function M.parse_url(info)
  local p = info.database
  if p ~= ":memory:" and not p:match("^file:") then
    if jit.os == "Windows" then
      p = p:gsub("^/(%a:[/\\])", "%1") -- sqlite:///C:/data/app.db
    end
    p = vim.fs.normalize(p)
    if not (p:sub(1, 1) == "/" or p:match("^%a:[/\\]")) and info.base_dir then
      p = vim.fs.joinpath(info.base_dir, p)
    end
    info.database = p
  end
  return info
end

local Conn = {}
Conn.__index = Conn

function M.connect(info)
  return setmetatable({ info = info }, Conn)
end

---Library names tried in order: database.options.lib_path, or the usual names per OS.
---@param lib_path string?
---@return string[]
function M.lib_candidates(lib_path)
  if lib_path and lib_path ~= "" then
    return { (lib_path:gsub("^~", vim.uv.os_homedir() or "~")) }
  elseif jit.os == "Windows" then
    return { "sqlite3.dll", "winsqlite3.dll" }
  elseif jit.os == "OSX" then
    return { "/usr/lib/libsqlite3.dylib", "libsqlite3.dylib", "sqlite3" }
  end
  return { "libsqlite3.so.0", "libsqlite3.so", "sqlite3" }
end

function Conn:execute(sql, opts)
  local o = self.info.options or {}
  local lib_path = o.lib_path ~= nil and o.lib_path ~= vim.NIL and o.lib_path or nil
  -- The flag M.cancel sets; the worker's progress handler reads it. The connection keeps
  -- it alive until the worker is done.
  local ffi = require("ffi")
  local flag = ffi.new("int32_t[1]")
  self.cancel_flag = flag
  local raw = async.await(function(cb)
    local work = vim.uv.new_work(worker, cb)
    work:queue(
      thread_source(),
      self.info.database,
      sql,
      tostring(opts.max_rows),
      tostring(opts.timeout),
      table.concat(M.lib_candidates(lib_path), "\n"),
      o.readonly == true and "1" or "0",
      o.create == true and "1" or "0",
      ("%.0f"):format(tonumber(ffi.cast("uintptr_t", flag))) -- (tostring keeps 14 digits)
    )
  end)
  self.cancel_flag = nil
  local res = vim.json.decode(raw, { luanil = { object = true, array = true } })
  if res.error or res.phase then
    local e = res.error or res
    dberr.raise(e.phase, e.message, { code = e.code, detail = e.detail })
  end
  self.version = res.version
  return build(res)
end

function Conn:close() end

---Stop the query running on `conn`: its worker's progress handler interrupts SQLite.
function M.cancel(conn)
  if conn.cancel_flag then
    conn.cancel_flag[0] = 1
  end
end

function Conn:server_version()
  return self.version
end

-- database.options this driver reads (dbdash.db.options)
M.options = { lib_path = "string", readonly = "boolean", create = "boolean" }

return M
