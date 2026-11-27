-- A table's content as DOM, like an HTML table:
--   table > header[column] (one per column), row (one per result row, in show.sort order;
--           the class of show.row_thresholds) > cell[column] (.null for NULL, the class of
--           the column's thresholds)
-- The table element keeps the columns' layout data (label, alignment, column_list width /
-- height, type); a cell's text is its formatted value (newlines kept: layout wraps or
-- marks them), a NULL cell has no text (cell.null { content } gives it one).
local content = require("dbdash.render.content")
local T = require("dbdash.render.thresholds")

local M = {}

local NUMERIC = { integer = true, number = true, decimal = true }

local nn = require("dbdash.util.null").nn

local function fail(msg, ...)
  require("dbdash.util.error").raise("render", msg:format(...))
end

---The show fields the content depends on.
function M.key(show)
  return { show.column_list, show.sort, show.row_thresholds }
end

---Columns to show: { index, label, width?, height?, align, format?, ltype, thresholds?, below }.
function M.columns(rs, show)
  local cols = {}
  local list = nn(show.column_list)
  if list and #list > 0 then
    for _, spec in ipairs(list) do
      local name = type(spec) == "string" and spec or nn(spec.column)
      if name then
        local idx = rs:col_index(name)
        local ltype = idx and rs.columns[idx].type
        local t = type(spec) == "table"
        cols[#cols + 1] = {
          index = idx,
          label = t and nn(spec.alias) or name,
          width = t and tonumber(nn(spec.width)) or nil,
          height = t and tonumber(nn(spec.height)) or nil,
          format = t and nn(spec.format) or nil,
          align = (t and nn(spec.align)) or ((ltype and NUMERIC[ltype]) and "right" or "left"),
          ltype = ltype,
          thresholds = t and nn(spec.thresholds) and T.steps(
            spec.thresholds,
            nn(spec.thresholds_below) == true
          ) or nil,
          below = t and nn(spec.thresholds_below) == true,
        }
      end
    end
  else
    for i, c in ipairs(rs.columns) do
      cols[i] =
        { index = i, label = c.name, align = NUMERIC[c.type] and "right" or "left", ltype = c.type }
    end
  end
  return cols
end

---The result rows in show.sort order (DataTables order; NULLs last).
local function sorted(rs, show)
  local rows = rs.rows
  local sort = nn(show.sort)
  if not sort then
    return rows
  end
  local sc = type(sort) == "table" and nn(sort.column) or sort
  local desc = type(sort) == "table" and nn(sort.order) == "desc"
  local si = rs:col_index(sc)
  if not si then
    fail("show.sort: no column '%s'", tostring(sc))
  end
  rows = vim.list_extend({}, rows)
  local function key(r)
    local v = r[si]
    if v == vim.NIL then
      return nil
    end
    return v
  end
  table.sort(rows, function(a, b)
    local x, y = key(a), key(b)
    if x == nil or y == nil then
      return y == nil and x ~= nil
    end
    if type(x) ~= type(y) then
      x, y = tostring(x), tostring(y)
    end
    if desc then
      return x > y
    end
    return x < y
  end)
  return rows
end

---@param chart dbdash.dom.Node
---@return dbdash.dom.Node table
function M.build(chart, rs, show)
  local tbl = require("dbdash.css").scope(chart):part("table")
  local cols = M.columns(rs, show)
  local rows = sorted(rs, show)
  local row_th = nn(show.row_thresholds)
  local row_steps, row_col, row_below
  if row_th then
    row_col = rs:col_index(nn(row_th.column) or "")
    if not row_col then
      fail("show.row_thresholds: no column '%s'", tostring(nn(row_th.column)))
    end
    row_below = nn(row_th.below) == true
    row_steps = T.steps(nn(row_th.steps) or {}, row_below)
  end
  local fmt = require("dbdash.render.table").format_value
  local python = require("dbdash.render.format").python
  content.set(tbl, {
    data = { columns = cols, total = #rs.rows, truncated = rs.truncated or false },
  })
  content.children(tbl, "header", cols, function(col)
    return { text = col.label, attrs = { column = col.label } }
  end)
  local function cells(node, row)
    content.children(node, "cell", cols, function(col)
      local v
      if col.index then
        v = row[col.index] -- not `and ... or nil`: that turned false into NULL
      end
      if v == nil or v == vim.NIL then
        return { classes = { "null" }, attrs = { column = col.label } }
      end
      local text = fmt(v, col.ltype, "", true)
      if col.format and type(v) == "number" then
        text = python(v, col.format) or text
      end
      local classes
      if col.thresholds then
        local _, step = T.level(v, col.thresholds, col.below)
        classes = T.classes(step)
      end
      return { text = text, classes = classes, attrs = { column = col.label } }
    end)
  end
  content.children(tbl, "row", rows, function(row)
    local classes = {}
    if row_steps then
      local _, step = T.level(row[row_col], row_steps, row_below)
      classes = T.classes(step)
    end
    return { classes = classes }
  end, cells)
  return tbl
end

return M
