-- Uniform ResultSet (design §8.3) and logical type helpers shared by drivers.
local map = require("dbdash.util.map")

local M = {}

M.NULL = vim.NIL

---@alias dbdash.db.LogicalType "null"|"boolean"|"integer"|"number"|"decimal"|"string"|"bytes"|"date"|"time"|"datetime"|"json"|"array"|"uuid"|"unknown"

---@class dbdash.db.Column
---@field name string
---@field type dbdash.db.LogicalType
---@field db_type string? the database's own type name

---@class dbdash.db.ResultSet
---@field columns dbdash.db.Column[]
---@field rows any[][] positional values; NULL is db.NULL (vim.NIL)
---@field row_count integer
---@field truncated boolean
---@field affected integer?
---@field elapsed_ms number
---@field warnings string[]
local ResultSet = {}
ResultSet.__index = ResultSet
M.ResultSet = ResultSet

---@param columns dbdash.db.Column[]
---@param rows any[][]
---@param extra { truncated: boolean?, affected: integer?, warnings: string[]? }?
---@return dbdash.db.ResultSet
function M.new(columns, rows, extra)
  extra = extra or {}
  return setmetatable({
    columns = columns,
    rows = rows,
    row_count = #rows,
    truncated = extra.truncated or false,
    affected = extra.affected,
    elapsed_ms = 0,
    warnings = extra.warnings or {},
  }, ResultSet)
end

function M.is(v)
  return getmetatable(v) == ResultSet
end

---Index of a column by name (first match), or nil.
function ResultSet:col_index(name)
  if not self._index then
    self._index = {}
    for i, c in ipairs(self.columns) do
      if self._index[c.name] == nil then
        self._index[c.name] = i
      end
    end
  end
  return self._index[name]
end

---Value at row `i` for column `name`.
function ResultSet:get(i, name)
  local c = self:col_index(name)
  local row = self.rows[i]
  if c and row then
    return row[c]
  end
end

---Rows as ordered mappings keyed by column name.
---@return table[]
function ResultSet:records()
  local out = {}
  for i, row in ipairs(self.rows) do
    local rec = map.new()
    for c, col in ipairs(self.columns) do
      if rec[col.name] == nil then
        map.set(rec, col.name, row[c])
      end
    end
    out[i] = rec
  end
  return out
end

---All values of one column.
function ResultSet:column(name)
  local c = self:col_index(name)
  if not c then
    return nil
  end
  local out = {}
  for i, row in ipairs(self.rows) do
    out[i] = row[c]
  end
  return out
end

---Column names in order.
function ResultSet:column_names()
  local out = {}
  for i, c in ipairs(self.columns) do
    out[i] = c.name
  end
  return out
end

-- Type helpers -----------------------------------------------------------------------------

local MAX_SAFE = 2 ^ 53

---Decimal integer text -> number when exactly representable, else the original string.
---@param s string
---@return number|string
function M.integer(s)
  local digits = s:gsub("^[-+]", "")
  if #digits <= 15 then
    return tonumber(s) or s
  end
  local n = tonumber(s)
  if n and math.abs(n) <= MAX_SAFE and ("%.0f"):format(n) == s:gsub("^%+", "") then
    return n
  end
  return s
end

---Raw bytes -> lower-case hex (how `bytes` values are displayed).
function M.hex(s)
  return (s:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

---Convert a logical-typed value to a number for charts; nil when not numeric.
function M.tonumber(v)
  if type(v) == "number" then
    return v
  elseif type(v) == "string" then
    return tonumber(v)
  elseif type(v) == "boolean" then
    return v and 1 or 0
  end
end

return M
