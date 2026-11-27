-- Helpers shared by chart styles: column access, series, colors, axes and legends.
local resultset = require("dbdash.db.resultset")
local fmt = require("dbdash.render.format")

local M = {}

local nn = require("dbdash.util.null").nn

---Raise a render error shown in place of the chart.
function M.fail(msg, ...)
  require("dbdash.util.error").raise("render", msg:format(...))
end

---Column index, failing with the available names when missing.
function M.col(rs, name, field)
  if not name then
    M.fail("show.%s is required for this chart", field)
  end
  local i = rs:col_index(name)
  if not i then
    M.fail(
      "column '%s' (show.%s) not found; available: %s",
      name,
      field,
      table.concat(rs:column_names(), ", ")
    )
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

---@class dbdash.render.LongSeries
---@field label string
---@field points { x: number, y: number }[]

---Long data (one row per x and series, show.series_column) as series: the distinct x
---values in order of appearance, one series per distinct series_column value.
---@return dbdash.render.XAxis xaxis
---@return dbdash.render.LongSeries[] series
function M.long(rs, show)
  local xi = M.col(rs, nn(show.x_column), "x_column")
  local yi = M.col(rs, nn(show.y_column), "y_column")
  local si = M.col(rs, nn(show.series_column), "series_column")
  local numeric = NUMERIC[rs.columns[xi].type] == true
  local xs, labels, index = {}, {}, {}
  local series, by_name = {}, {}
  for _, row in ipairs(rs.rows) do
    local label = M.text(row[xi])
    if index[label] == nil then
      labels[#labels + 1] = label
      index[label] = numeric and M.num(row[xi]) or #labels
      xs[#xs + 1] = index[label]
    end
    local name = M.text(row[si])
    local s = by_name[name]
    if not s then
      s = { label = name, points = {} }
      by_name[name] = s
      series[#series + 1] = s
    end
    local x, y = index[label], M.num(row[yi])
    if x and y then
      s.points[#s.points + 1] = { x = x, y = y }
    end
  end
  return { numeric = numeric, values = xs, labels = labels }, series
end

---@class dbdash.render.Series
---@field column string
---@field index integer
---@field label string

---Series from y_columns (list of strings or {column, label}) or y_column.
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
    }
  end
  return out
end

---The element of the i-th series / named category: series:nth-child(i), with the name
---as an attribute (series[name="EU"]) and, when it is an identifier, a class (series.EU).
function M.series_spec(i, name, classes)
  local cls = vim.list_extend({}, classes or {})
  if type(name) == "string" and name:match("^[%a_][%w_-]*$") then
    cls[#cls + 1] = name
  end
  return { index = i, classes = cls, attrs = name and { name = tostring(name) } or nil }
end

---Highlight group for the i-th series / named category: the color of its series element
---(render/content/chart.lua) in the style sheets, else the palette's i-th color. Without a
---context (building the DOM) there is none.
function M.color(ctx, _, i, _, name)
  if not ctx then
    return nil
  end
  local node = require("dbdash.render.content.find").item(ctx.css.node, "series", i)
  if node then
    return require("dbdash.css").hl_of(node) or ctx.palette(i)
  end
  return ctx.css:hl("series", M.series_spec(i, name)) or ctx.palette(i)
end

---Highlight group of an item's element (render/content/chart.lua: "legend", "marks", ...),
---else of the chart's part `tag` (charts drawn without their content).
function M.item_hl(ctx, kind, i, tag, child)
  local chart = require("dbdash.render.content.find")
  local node = chart.item(ctx.css.node, kind, i)
  if child then
    node = chart.child(node, child)
  end
  if node then
    return require("dbdash.css").hl_of(node)
  end
  return ctx.css:hl(tag)
end

---A part of the i-th box / item (`child` of its element): shown?, and its highlight
---group (else `fallback`, e.g. the series color).
function M.item_part(ctx, kind, i, child, fallback)
  local st = M.item_style(ctx, kind, i, child, child)
  if st.display == "none" then
    return false
  end
  local g = st.color and M.item_hl(ctx, kind, i, child, child) or nil
  return true, g or fallback
end

---Computed style of an item's element (or of the chart's part `tag`).
function M.item_style(ctx, kind, i, tag, child)
  local chart = require("dbdash.render.content.find")
  local node = chart.item(ctx.css.node, kind, i)
  if child then
    node = chart.child(node, child)
  end
  if node then
    return require("dbdash.css.style").get(node)
  end
  return ctx.css:get(tag)
end

---@class dbdash.render.Axes
---@field xlabel string?
---@field ylabel string?
---@field ymin number?
---@field ymax number?
---@field xmin number?
---@field xmax number?
---@field yformat string?
---@field xformat string?

---Axis settings from show.axes.{x_axis,y_axis} or x_label/y_label.
---@return dbdash.render.Axes
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
    -- Chart.js scales: type (linear | log), ticks.count (grid lines are the grid.x /
    -- grid.y elements' display)
    yscale = nn(ya.scale) or "linear",
    xscale = nn(xa.scale) or "linear",
    yticks = tonumber(nn(ya.ticks)),
    xticks = tonumber(nn(xa.ticks)),
  }
end

---Legend position from the legend element: "right" (default), "bottom" (position:
---bottom) or "none" (display: none, or a single series without a position set).
function M.legend_position(ctx, count)
  local c = ctx.css:get("legend")
  if c.display == "none" or (count < 2 and not c.position) then
    return "none"
  end
  return c.position == "bottom" and "bottom" or "right"
end

---Numeric y ticks for a canvas with `rows` character rows: labels on rows that are hit.
---@return { row: integer, label: string }[] ticks, string[] all_labels
function M.y_ticks(ctx, lo, hi, rows, yformat, count, log)
  local values, labels
  if log then
    values, labels = M.log_ticks(lo, hi)
  else
    values, labels = ctx.ticks(lo, hi, count or math.max(2, math.min(6, math.floor(rows / 2) + 1)))
  end
  local ticks, all = {}, {}
  for i, v in ipairs(values) do
    local label = yformat and fmt.python(log and 10 ^ v or v, yformat) or labels[i]
    local frac = (hi == lo) and 0 or (v - lo) / (hi - lo)
    local row = rows - 1 - math.floor(frac * (rows - 1) + 0.5)
    ticks[#ticks + 1] = { row = row, label = label }
    all[#all + 1] = label
  end
  return ticks, all
end

---Ticks of a log10 axis: lo and hi are exponents; one tick per power of ten.
---@return number[] values (exponents), string[] labels
function M.log_ticks(lo, hi)
  local values, labels = {}, {}
  for e = math.ceil(lo - 1e-9), math.floor(hi + 1e-9) do
    values[#values + 1] = e
    labels[#labels + 1] = fmt.number(10 ^ e)
  end
  return values, labels
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
