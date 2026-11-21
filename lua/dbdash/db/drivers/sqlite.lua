-- SQLite driver (design §8.4): LuaJIT FFI over the system libsqlite3.
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
local dberr = require("dbdash.db.error")
local dialect = require("dbdash.db.dialect")
local resultset = require("dbdash.db.resultset")

local M = {
  name = "sqlite",
  schemes = { "sqlite", "sqlite3" },
  dialect = dialect.get("sqlite"),
  capabilities = { tls = false, sql = true, query_language = "sql" },
}

-- Runs in a worker thread: must not use upvalues. Arguments and result are strings.
local function worker(path, sql, max_rows, timeout_ms, lib_path, readonly, create)
  -- The progress handler is a Lua callback called from sqlite3_step. LuaJIT raises "bad
  -- callback" (and Neovim aborts) when a callback runs inside a JIT-compiled FFI call, which
  -- happens once the step loop gets hot in the reused thread VM. Keep this code interpreted.
  jit.off(true, true)
  local ffi = require("ffi")
  pcall(
    ffi.cdef,
    [[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    int sqlite3_open_v2(const char*, sqlite3**, int, const char*);
    int sqlite3_close_v2(sqlite3*);
    int sqlite3_busy_timeout(sqlite3*, int);
    void sqlite3_progress_handler(sqlite3*, int, int(*)(void*), void*);
    int sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_finalize(sqlite3_stmt*);
    int sqlite3_column_count(sqlite3_stmt*);
    const char* sqlite3_column_name(sqlite3_stmt*, int);
    const char* sqlite3_column_decltype(sqlite3_stmt*, int);
    int sqlite3_column_type(sqlite3_stmt*, int);
    const unsigned char* sqlite3_column_text(sqlite3_stmt*, int);
    const void* sqlite3_column_blob(sqlite3_stmt*, int);
    int sqlite3_column_bytes(sqlite3_stmt*, int);
    double sqlite3_column_double(sqlite3_stmt*, int);
    const char* sqlite3_errmsg(sqlite3*);
    int sqlite3_extended_errcode(sqlite3*);
    int sqlite3_changes(sqlite3*);
    const char* sqlite3_libversion(void);
  ]]
  )

  local function result(t)
    return vim.json.encode(t)
  end

  local candidates
  if lib_path ~= "" then
    candidates = { lib_path }
  elseif jit.os == "Windows" then
    candidates = { "sqlite3.dll", "winsqlite3.dll" }
  elseif jit.os == "OSX" then
    candidates = { "/usr/lib/libsqlite3.dylib", "libsqlite3.dylib", "sqlite3" }
  else
    candidates = { "libsqlite3.so.0", "libsqlite3.so", "sqlite3" }
  end
  local lib, load_errs = nil, {}
  for _, name in ipairs(candidates) do
    local ok, l = pcall(ffi.load, name)
    if ok then
      lib = l
      break
    end
    load_errs[#load_errs + 1] = tostring(l)
  end
  if not lib then
    return result({
      phase = "connect",
      message = "cannot load the SQLite library (tried "
        .. table.concat(candidates, ", ")
        .. "); set database.options.lib_path",
      detail = table.concat(load_errs, "\n"),
    })
  end

  local hex = function(s)
    return (s:gsub(".", function(c)
      return string.format("%02x", c:byte())
    end))
  end
  local function valid_utf8(s)
    if not s:find("[\128-\255]") then
      return true
    end
    local i, n = 1, #s
    while i <= n do
      local c = s:byte(i)
      local len = c < 0x80 and 1 or (c >= 0xC2 and c < 0xE0) and 2 or (c >= 0xE0 and c < 0xF0) and 3
        or (c >= 0xF0 and c < 0xF5) and 4 or nil
      if not len or i + len - 1 > n then
        return false
      end
      for k = i + 1, i + len - 1 do
        local b = s:byte(k)
        if b < 0x80 or b > 0xBF then
          return false
        end
      end
      i = i + len
    end
    return true
  end

  local READONLY, READWRITE, CREATE, URI = 0x01, 0x02, 0x04, 0x40
  local flags = readonly == "1" and READONLY or READWRITE
  if path == ":memory:" or (create == "1" and readonly ~= "1") then
    flags = READWRITE + CREATE
  end
  local pdb = ffi.new("sqlite3*[1]")
  local rc = lib.sqlite3_open_v2(path, pdb, flags + URI, nil)
  local db = pdb[0]
  local function db_error(phase)
    local msg = db ~= nil and ffi.string(lib.sqlite3_errmsg(db)) or ("open failed (" .. rc .. ")")
    local code = db ~= nil and lib.sqlite3_extended_errcode(db) or rc
    return { phase = phase, message = msg, code = "SQLITE_" .. code }
  end
  if rc ~= 0 then
    local e = db_error("connect")
    if db ~= nil then
      lib.sqlite3_close_v2(db)
    end
    e.message = e.message .. ": " .. path
    return result(e)
  end

  local timeout = tonumber(timeout_ms)
  lib.sqlite3_busy_timeout(db, math.min(timeout, 5000))
  local deadline = vim.uv.hrtime() + timeout * 1e6
  local timed_out = false
  local progress = ffi.cast("int(*)(void*)", function()
    if vim.uv.hrtime() > deadline then
      timed_out = true
      return 1
    end
    return 0
  end)
  lib.sqlite3_progress_handler(db, 1000, progress, nil)

  local limit = tonumber(max_rows)
  local out = { columns = {}, rows = {}, truncated = false, version = ffi.string(lib.sqlite3_libversion()) }
  local err
  local pstmt = ffi.new("sqlite3_stmt*[1]")
  local tail = ffi.new("const char*[1]")
  local buf = ffi.new("char[?]", #sql + 1, sql)
  local cur = buf

  while true do
    rc = lib.sqlite3_prepare_v2(db, cur, -1, pstmt, tail)
    if rc ~= 0 then
      err = db_error("query")
      break
    end
    local stmt = pstmt[0]
    if stmt == nil then -- only whitespace or comments left
      break
    end
    cur = tail[0]
    local ncol = lib.sqlite3_column_count(stmt)
    local rows, columns, truncated = {}, {}, false
    for i = 0, ncol - 1 do
      local decl = lib.sqlite3_column_decltype(stmt, i)
      columns[i + 1] = {
        name = ffi.string(lib.sqlite3_column_name(stmt, i)),
        decltype = decl ~= nil and ffi.string(decl) or "",
      }
    end
    while true do
      rc = lib.sqlite3_step(stmt)
      if rc == 100 then -- SQLITE_ROW
        if #rows >= limit then
          truncated = true
          break
        end
        local row = {}
        for i = 0, ncol - 1 do
          local t = lib.sqlite3_column_type(stmt, i)
          if t == 1 then
            row[#row + 1] = "I"
            row[#row + 1] = ffi.string(lib.sqlite3_column_text(stmt, i))
          elseif t == 2 then
            local d = lib.sqlite3_column_double(stmt, i)
            if d ~= d or d == math.huge or d == -math.huge then
              row[#row + 1] = "S"
              row[#row + 1] = d ~= d and "nan" or (d > 0 and "inf" or "-inf")
            else
              row[#row + 1] = "R"
              row[#row + 1] = d
            end
          elseif t == 3 then
            local p = lib.sqlite3_column_text(stmt, i)
            local s = ffi.string(p, lib.sqlite3_column_bytes(stmt, i))
            if valid_utf8(s) then
              row[#row + 1] = "T"
              row[#row + 1] = s
            else
              row[#row + 1] = "X"
              row[#row + 1] = hex(s)
            end
          elseif t == 4 then
            local p = lib.sqlite3_column_blob(stmt, i)
            local n = lib.sqlite3_column_bytes(stmt, i)
            row[#row + 1] = "B"
            row[#row + 1] = n > 0 and hex(ffi.string(p, n)) or ""
          else
            row[#row + 1] = "N"
            row[#row + 1] = 0
          end
        end
        rows[#rows + 1] = row
      elseif rc == 101 then -- SQLITE_DONE
        break
      else
        err = db_error(timed_out and "timeout" or "query")
        break
      end
    end
    lib.sqlite3_finalize(stmt)
    if err then
      break
    end
    -- The last statement that returns columns provides the result.
    if ncol > 0 then
      out.columns, out.rows, out.truncated = columns, rows, truncated
      out.affected = nil
    else
      out.affected = lib.sqlite3_changes(db)
    end
  end

  lib.sqlite3_progress_handler(db, 0, nil, nil)
  progress:free()
  lib.sqlite3_close_v2(db)
  if err then
    if timed_out then
      err.phase = "timeout"
      err.message = "query interrupted after " .. timeout .. "ms"
    end
    return result({ error = err })
  end
  return result(out)
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

local CLASS_TYPE = { I = "integer", R = "number", S = "number", T = "string", X = "bytes", B = "bytes" }

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
    return require("dbdash.db.json").decode(v)
  elseif ltype == "decimal" and (tag == "I" or tag == "R") then
    return type(v) == "number" and require("dbdash.template.runtime").numstr(v) or v
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

function Conn:execute(sql, opts)
  local o = self.info.options or {}
  local lib_path = o.lib_path ~= nil and o.lib_path ~= vim.NIL and o.lib_path:gsub("^~", vim.uv.os_homedir() or "~") or ""
  local raw = async.await(function(cb)
    local work = vim.uv.new_work(worker, cb)
    work:queue(
      self.info.database,
      sql,
      tostring(opts.max_rows),
      tostring(opts.timeout),
      lib_path,
      o.readonly == true and "1" or "0",
      o.create == true and "1" or "0"
    )
  end)
  local res = vim.json.decode(raw, { luanil = { object = true, array = true } })
  if res.error or res.phase then
    local e = res.error or res
    dberr.raise(e.phase, e.message, { code = e.code, detail = e.detail })
  end
  self.version = res.version
  return build(res)
end

function Conn:close() end

function Conn:server_version()
  return self.version
end

return M
