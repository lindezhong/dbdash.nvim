-- Helpers shared by chart styles: column access, series, colors, axes and legends.
local map = require("dbdash.util.map")
local resultset = require("dbdash.db.resultset")
local fmt = require("dbdash.render.format")

local M = {}

function M.nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
end
local nn = M.nn

---Raise a render error shown in place of the chart.
function M.fail(msg, ...)
  error({ phase = "render", message = msg:format(...) }, 0)
end

---Column index, failing with the available names when missing.
function M.col(rs, name, field)
  if not name then
    M.fail("show.%s is required for this chart", field)
  end
  local i = rs:col_index(name)
  if not i then
    M.fail("column '%s' (show.%s) not found; available: %s", name, field, table.concat(rs:column_names(), ", "))
  end
  return i
end

---Number from a cell, or nil.
function M.num(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  return resultset.tonumber(v)
end

---Text for a cell (labels and categories).
function M.text(v)
  if v == nil or v == vim.NIL then
    return "NULL"
  elseif type(v) == "number" then
    return fmt.number(v)
  elseif type(v) == "boolean" then
    return v and "true" or "false"
  elseif type(v) == "table" then
    local ok, s = pcall(vim.json.encode, v)
    return ok and s or "?"
  end
  return (tostring(v):gsub("\n", " "))
end

local NUMERIC = { integer = true, number = true, decimal = true }

---@class dbdash.render.XAxis
---@field numeric boolean
---@field values number[] x position of each row (row index for categories)
---@field labels string[] label of each row

---X positions for the rows: numeric columns map directly, others become categories.
---@return dbdash.render.XAxis
function M.x_axis(rs, name)
  local i = M.col(rs, name, "x_column")
  local numeric = NUMERIC[rs.columns[i].type] == true
  local values, labels = {}, {}
  for r, row in ipairs(rs.rows) do
    local v = row[i]
    labels[r] = M.text(v)
    if numeric then
      values[r] = M.num(v)
    else
      values[r] = r
    end
  end
  return { numeric = numeric, values = values, labels = labels }
end

---@class dbdash.render.Series
---@field column string
---@field index integer
---@field label string
---@field color string? color spec from the config

---Series from y_columns (list of strings or {column, label, color}) or y_column.
---@return dbdash.render.Series[]
function M.series(rs, show)
  local out = {}
  local list = nn(show.y_columns)
  if type(list) == "string" then
    list = { list }
  end
  if not list or #list == 0 then
    local y = nn(show.y_column)
    if not y then
      M.fail("show.y_column or show.y_columns is required for this chart")
    end
    list = { y }
  end
  for _, s in ipairs(list) do
    local col = type(s) == "string" and s or nn(s.column)
    local i = M.col(rs, col, "y_columns")
    out[#out + 1] = {
      column = col,
      index = i,
      label = type(s) == "table" and nn(s.label) or col,
      color = type(s) == "table" and nn(s.color) or nil,
    }
  end
  return out
end

---Highlight group for the i-th series / named category.
---Order: explicit color > show.colors (list by index, map by name) > style.color > palette.
function M.color(ctx, show, i, explicit, name)
  if explicit then
    return ctx.color(explicit)
  end
  local colors = nn(show.colors)
  if map.is_map(colors) then
    local c = name and nn(colors[name])
    if c then
      return ctx.color(c)
    end
    if i == 1 and nn(colors.primary) then
      return ctx.color(colors.primary)
    end
    if i == 2 and nn(colors.secondary) then
      return ctx.color(colors.secondary)
    end
  elseif type(colors) == "table" and #colors > 0 then
    return ctx.color(colors[(i - 1) % #colors + 1])
  end
  local style = nn(show.style) or {}
  if i == 1 and nn(style.color) then
    return ctx.color(style.color)
  end
  return ctx.palette(i)
end

---Axis settings from show.axes.{x_axis,y_axis} or x_label/y_label.
---@return { xlabel: string?, ylabel: string?, ymin: number?, ymax: number?, xmin: number?, xmax: number?, yformat: string?, xformat: string? }
function M.axes(show)
  local axes = nn(show.axes) or {}
  local xa = nn(axes.x_axis) or {}
  local ya = nn(axes.y_axis) or {}
  return {
    xlabel = nn(show.x_label) or nn(xa.title),
    ylabel = nn(show.y_label) or nn(ya.title),
    ymin = tonumber(nn(ya.min_value)),
    ymax = tonumber(nn(ya.max_value)),
    xmin = tonumber(nn(xa.min_value)),
    xmax = tonumber(nn(xa.max_value)),
    yformat = nn(ya.format),
    xformat = nn(xa.format),
  }
end

---Legend position: "right", "bottom" or "none".
function M.legend_position(show, count)
  local legend = nn(show.legend)
  if legend == false then
    return "none"
  end
  legend = type(legend) == "table" and legend or {}
  if nn(legend.show) == false then
    return "none"
  end
  if nn(legend.show) == nil and count < 2 then
    return "none"
  end
  local pos = tostring(nn(legend.position) or "right")
  if pos:find("bottom") or pos == "top" or pos == "below" then
    return "bottom"
  elseif pos == "none" then
    return "none"
  end
  return "right"
end

---Numeric y ticks for a canvas with `rows` character rows: labels on rows that are hit.
---@return { row: integer, label: string }[] ticks, string[] all_labels
function M.y_ticks(ctx, lo, hi, rows, yformat)
  local values, labels = ctx.ticks(lo, hi, math.max(2, math.min(6, math.floor(rows / 2) + 1)))
  local ticks, all = {}, {}
  for i, v in ipairs(values) do
    local label = yformat and fmt.python(v, yformat) or labels[i]
    local frac = (hi == lo) and 0 or (v - lo) / (hi - lo)
    local row = rows - 1 - math.floor(frac * (rows - 1) + 0.5)
    ticks[#ticks + 1] = { row = row, label = label }
    all[#all + 1] = label
  end
  return ticks, all
end

---Data limits over several series, with optional overrides and padding for ticks.
function M.limits(ctx, lo, hi, override_lo, override_hi)
  lo = override_lo or lo
  hi = override_hi or hi
  if not lo or not hi then
    return 0, 1
  end
  local nlo, nhi = ctx.limits(lo, hi, 5)
  return override_lo or nlo, override_hi or nhi
end

return M
