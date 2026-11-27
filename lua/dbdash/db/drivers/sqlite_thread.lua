-- The SQLite driver's work in a vim.uv.new_work thread (db/drivers/sqlite.lua): open,
-- prepare, step and close over LuaJIT FFI, the rows as JSON with tagged cells. The thread
-- loads this file from its source (a thread shares nothing with the main loop): it may
-- use only Lua, ffi, vim.json and vim.uv.
local ffi = require("ffi")

local M = {}

-- The progress handler is a Lua callback called from sqlite3_step. LuaJIT raises "bad
-- callback" (and Neovim aborts) when a callback runs inside a JIT-compiled FFI call, which
-- happens once the step loop gets hot in the reused thread VM. Keep this code interpreted.
jit.off(true, true)

-- (pcall: the thread VM is reused, and declaring the types again fails)
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

---The first library of `candidates` that loads, or nil and the errors.
local function load_lib(candidates)
  local errs = {}
  for _, name in ipairs(candidates) do
    local ok, l = pcall(ffi.load, name)
    if ok then
      return l
    end
    errs[#errs + 1] = tostring(l)
  end
  return nil, table.concat(errs, "\n")
end

local function hex(s)
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
    local len = c < 0x80 and 1
      or (c >= 0xC2 and c < 0xE0) and 2
      or (c >= 0xE0 and c < 0xF0) and 3
      or (c >= 0xF0 and c < 0xF5) and 4
      or nil
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

---@class dbdash.db.sqlite.Run
---@field lib table the loaded library
---@field db any sqlite3*
---@field rc integer the last return code
---@field timed_out boolean
---@field cancelled boolean

---The error of the connection (or of opening it).
local function db_error(r, phase)
  local lib, db = r.lib, r.db
  local msg = db ~= nil and ffi.string(lib.sqlite3_errmsg(db)) or ("open failed (" .. r.rc .. ")")
  local code = db ~= nil and lib.sqlite3_extended_errcode(db) or r.rc
  return { phase = phase, message = msg, code = "SQLITE_" .. code }
end

---Open `path` (read-only, read-write, created when asked); returns an error or nil.
---@return table? err
local function open(r, path, readonly, create)
  local READONLY, READWRITE, CREATE, URI = 0x01, 0x02, 0x04, 0x40
  local flags = readonly == "1" and READONLY or READWRITE
  if path == ":memory:" or (create == "1" and readonly ~= "1") then
    flags = READWRITE + CREATE
  end
  local pdb = ffi.new("sqlite3*[1]")
  r.rc = r.lib.sqlite3_open_v2(path, pdb, flags + URI, nil)
  r.db = pdb[0]
  if r.rc ~= 0 then
    local e = db_error(r, "connect")
    if r.db ~= nil then
      r.lib.sqlite3_close_v2(r.db)
    end
    e.message = e.message .. ": " .. path
    return e
  end
end

---A progress handler that interrupts SQLite at the deadline or when the main loop sets
---the cancel flag (the int32 at `cancel_addr`).
---@return any progress the callback (a cdata, freed after the query)
local function guard(r, timeout, cancel_addr)
  local deadline = vim.uv.hrtime() + timeout * 1e6
  local cancel_flag = ffi.cast("volatile int32_t*", ffi.cast("uintptr_t", tonumber(cancel_addr)))
  local progress = ffi.cast("int(*)(void*)", function()
    if cancel_flag[0] ~= 0 then
      r.cancelled = true
      return 1
    end
    if vim.uv.hrtime() > deadline then
      r.timed_out = true
      return 1
    end
    return 0
  end)
  r.lib.sqlite3_progress_handler(r.db, 1000, progress, nil)
  return progress
end

---Column i of the current row, tagged: N null, I integer (decimal text), R real, S real
---JSON cannot carry, T text, X text that is not UTF-8 (hex), B blob (hex).
local function cell(lib, stmt, i, row)
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

---Step a prepared statement: its columns, rows (at most `limit`) and whether it had more;
---or an error.
local function step_all(r, stmt, limit)
  local lib = r.lib
  local ncol = lib.sqlite3_column_count(stmt)
  local rows, columns = {}, {}
  for i = 0, ncol - 1 do
    local decl = lib.sqlite3_column_decltype(stmt, i)
    columns[i + 1] = {
      name = ffi.string(lib.sqlite3_column_name(stmt, i)),
      decltype = decl ~= nil and ffi.string(decl) or "",
    }
  end
  while true do
    local rc = lib.sqlite3_step(stmt)
    if rc == 100 then -- SQLITE_ROW
      if #rows >= limit then
        return columns, rows, true
      end
      local row = {}
      for i = 0, ncol - 1 do
        cell(lib, stmt, i, row)
      end
      rows[#rows + 1] = row
    elseif rc == 101 then -- SQLITE_DONE
      return columns, rows, false
    else
      return nil, db_error(r, r.timed_out and "timeout" or "query")
    end
  end
end

---Run every statement of `sql`; the last one that returns columns gives the result (or the
---number of rows the last one changed). Returns the result or nil and an error.
---@return table? result, table? err
local function run_all(r, sql, limit)
  local lib = r.lib
  local out =
    { columns = {}, rows = {}, truncated = false, version = ffi.string(lib.sqlite3_libversion()) }
  local pstmt = ffi.new("sqlite3_stmt*[1]")
  local tail = ffi.new("const char*[1]")
  local buf = ffi.new("char[?]", #sql + 1, sql)
  local cur = buf
  while true do
    r.rc = lib.sqlite3_prepare_v2(r.db, cur, -1, pstmt, tail)
    if r.rc ~= 0 then
      return nil, db_error(r, "query")
    end
    local stmt = pstmt[0]
    if stmt == nil then -- only whitespace or comments left
      return out
    end
    cur = tail[0]
    local columns, rows, truncated = step_all(r, stmt, limit)
    lib.sqlite3_finalize(stmt)
    if not columns then
      return nil, rows
    end
    if #columns > 0 then
      out.columns, out.rows, out.truncated = columns, rows, truncated
      out.affected = nil
    else
      out.affected = lib.sqlite3_changes(r.db)
    end
  end
end

---The work of one query; arguments and result are strings (JSON).
function M.run(path, sql, max_rows, timeout_ms, libs, readonly, create, cancel_addr)
  local candidates = {}
  for name in libs:gmatch("[^\n]+") do
    candidates[#candidates + 1] = name
  end
  local lib, load_errs = load_lib(candidates)
  if not lib then
    return vim.json.encode({
      phase = "connect",
      message = "cannot load the SQLite library (tried "
        .. table.concat(candidates, ", ")
        .. "); set database.options.lib_path",
      detail = load_errs,
    })
  end
  local r = { lib = lib, timed_out = false, cancelled = false }
  local err = open(r, path, readonly, create)
  if err then
    return vim.json.encode(err)
  end
  local timeout = tonumber(timeout_ms) or 0
  lib.sqlite3_busy_timeout(r.db, math.min(timeout, 5000))
  local progress = guard(r, timeout, cancel_addr)
  local out
  out, err = run_all(r, sql, tonumber(max_rows) or 0)
  lib.sqlite3_progress_handler(r.db, 0, nil, nil)
  progress:free()
  lib.sqlite3_close_v2(r.db)
  if err then
    if r.cancelled then
      err.phase = "cancelled"
      err.message = "query cancelled"
    elseif r.timed_out then
      err.phase = "timeout"
      err.message = "query interrupted after " .. timeout .. "ms"
    end
    return vim.json.encode({ error = err })
  end
  return vim.json.encode(out)
end

return M
