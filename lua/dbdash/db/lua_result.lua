-- Every query goes: driver -> query.transform (if any) -> rows check (normalize). Drivers
-- of SQL-like databases return result sets, which pass the check as they are; lua:// and
-- http(s):// return raw values (M.raw) that must have one of these shapes, directly or
-- after the transform:
--   { columns = { "a", "b" }, rows = { { 1, "x" }, ... } }   rows by position
--   { columns = { "a", "b" }, rows = { { a = 1, b = "x" } } } rows by name
--   { { a = 1, b = "x" }, ... }                                 records (columns sorted by
--                                                               name unless `columns` is given)
--   a result set (e.g. from dbdash.query)                       used as is
-- nil values are NULL; column types follow the first non-NULL value.
local resultset = require("dbdash.db.resultset")
local dberr = require("dbdash.util.error")

local M = {}

local NULL = resultset.NULL

local HINT = "; add query.transform to reshape it (:help dbdash-transform)"

---@return any (it raises: `x or fail(...)` keeps x's type)
local function fail(o, msg, ...)
  dberr.raise(o.phase or "query", msg:format(...) .. (o.hint and HINT or ""))
end

local RawMT = {}

---A driver's raw result (a script's return value, a decoded HTTP body) with the extra
---variables query.transform gets besides `rs` (e.g. `response`).
---@param value any
---@param vars table?
function M.raw(value, vars)
  return setmetatable({ value = value, vars = vars or {} }, RawMT)
end

function M.is_raw(v)
  return getmetatable(v) == RawMT
end

local function logical(v)
  local t = type(v)
  if t == "number" then
    return v == math.floor(v) and "integer" or "number"
  elseif t == "boolean" then
    return "boolean"
  elseif t == "string" then
    return "string"
  elseif t == "table" then
    return "json"
  end
  return "unknown"
end

local function is_record(row)
  return type(row) == "table" and not vim.islist(row) and next(row) ~= nil
end

---@param v any the script's return value
---@param o { max_rows: integer?, phase: string?, hint: boolean? }? hint: suggest query.transform
---@return dbdash.db.ResultSet
function M.normalize(v, o)
  o = o or {}
  if M.is_raw(v) then
    v = v.value
  end
  if resultset.is(v) then
    return v
  end
  if type(v) ~= "table" then
    fail(o, "the result is not rows (got %s)", v == vim.NIL and "null" or type(v))
  end
  local names, rows
  if v.rows ~= nil then
    if type(v.rows) ~= "table" then
      fail(o, "rows must be a list")
    end
    names, rows = v.columns, v.rows
  else
    names, rows = v.columns, v -- records, optionally with columns = { ... } for the order
    local keys = {}
    for k in pairs(v) do
      if type(k) ~= "number" and k ~= "columns" then
        keys[#keys + 1] = tostring(k)
      end
    end
    if #keys > 0 then
      table.sort(keys)
      fail(
        o,
        "the result is an object (%s), not rows",
        table.concat(vim.list_slice(keys, 1, 5), ", ")
      )
    end
  end
  if names ~= nil and type(names) ~= "table" then
    fail(o, "columns must be a list of names")
  end
  local first = rows[1]
  if names == nil then
    if is_record(first) then
      names = vim.tbl_keys(first)
      table.sort(names, function(a, b)
        return tostring(a) < tostring(b)
      end)
    elseif type(first) == "table" then
      names = {}
      for i = 1, #first do
        names[i] = "c" .. i
      end
    else
      names = {}
    end
  end
  for i, n in ipairs(names) do
    names[i] = tostring(n)
  end
  local max = o.max_rows or math.huge
  local out, truncated = {}, false
  for r, row in ipairs(rows) do
    if r > max then
      truncated = true
      break
    end
    if type(row) ~= "table" then
      fail(o, "row %d is a %s, not a table", r, type(row))
    end
    local by_name = is_record(row)
    local cells = {}
    for i, n in ipairs(names) do
      local x
      if by_name then
        x = row[n]
      else
        x = row[i]
      end
      cells[i] = x == nil and NULL or x
    end
    out[r] = cells
  end
  local columns = {}
  for i, n in ipairs(names) do
    local t = "unknown"
    for _, row in ipairs(out) do
      if row[i] ~= NULL then
        t = logical(row[i])
        break
      end
    end
    columns[i] = { name = n, type = t }
  end
  return resultset.new(columns, out, { truncated = truncated })
end

---A result set as plain Lua data for a script: { columns, types, rows } with nil for NULL.
function M.to_lua(rs)
  local names, types, rows = {}, {}, {}
  for i, c in ipairs(rs.columns) do
    names[i], types[i] = c.name, c.type
  end
  for r, row in ipairs(rs.rows) do
    local copy = {}
    for i = 1, #names do
      local x = row[i]
      if x ~= NULL then
        copy[i] = x
      end
    end
    rows[r] = copy
  end
  return { columns = names, types = types, rows = rows }
end

return M
