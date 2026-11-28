-- The content of the plotted chart types as DOM, like an SVG chart's elements (one per
-- item of the data; the pixels, lines and ticks are the raster's, like path data). A chart
-- type (render/charts/<type>/init.lua) gives its model, the items in the order its
-- renderers draw them; this builds their elements:
--   series[name] (> point, or > value, outlier, mean for boxes), legend > legend-item[name]
--   (> label, value, percent for a pie), mark[label], bar[category][series] > value,
--   cell[x][y], stat > value, unit, label, delta, sparkline.
-- A series or item named like an identifier also has its name as a class (series.EU).
-- The elements are kept in chart.content.items for the renderers.
local content = require("dbdash.render.content")
local C = require("dbdash.render.charts.lib.common")

local M = {}

local nn = require("dbdash.util.null").nn

---The show fields the content depends on: all but the titles and the refresh settings.
function M.key(show)
  local k = {}
  for name, v in pairs(show) do
    if name ~= "title" and name ~= "subtitle" and name ~= "description" and name ~= "interval" then
      k[name] = v
    end
  end
  return k
end

local function ident(name)
  return type(name) == "string" and name:match("^[%a_][%w_-]*$") ~= nil
end

local function named(name, extra)
  local classes = vim.list_extend({}, extra or {})
  if ident(name) then
    classes[#classes + 1] = name
  end
  return { classes = classes, attrs = { name = tostring(name) } }
end

-- Models' helpers (the chart types' models use them) ------------------------------------

---Series names of an xy chart (as render/charts/lib/xy.lua collects them).
function M.xy_series(rs, show)
  if show.type == "scatter" or show.type == "bubble" then
    local xi = C.col(rs, nn(show.x_column), "x_column")
    local yi = C.col(rs, nn(show.y_column), "y_column")
    local ci = nn(show.color_column) and C.col(rs, show.color_column, "color_column")
    local seen, out = {}, {}
    for _, row in ipairs(rs.rows) do
      if C.num(row[xi]) and C.num(row[yi]) then
        local cat = ci and C.text(row[ci]) or ""
        if not seen[cat] then
          seen[cat] = true
          out[#out + 1] = cat ~= "" and cat or nn(show.y_column)
        end
      end
    end
    return out
  end
  if nn(show.series_column) then
    local _, long = C.long(rs, show)
    return vim.tbl_map(function(s)
      return s.label
    end, long)
  end
  return vim.tbl_map(function(s)
    return s.label
  end, C.series(rs, show))
end

---Bar chart: series names, and the categories in result order (before sorting).
function M.bar_model(rs, show)
  if nn(show.series_column) then
    local xaxis, long = C.long(rs, show)
    return vim.tbl_map(function(s)
      return s.label
    end, long), xaxis.labels
  end
  local xi = C.col(rs, nn(show.x_column), "x_column")
  local series = C.series(rs, show)
  local cats = {}
  for _, row in ipairs(rs.rows) do
    if #series > 1 or C.num(row[series[1].index]) then
      cats[#cats + 1] = C.text(row[xi])
    end
  end
  return vim.tbl_map(function(s)
    return s.label
  end, series), cats
end

-- Elements ------------------------------------------------------------------------------

local function empty()
  return {}
end

---Children `tags` (one each) of an item element: its parts (a bar's value, ...).
local function parts(tags)
  return function(node)
    for _, tag in ipairs(tags) do
      content.children(node, tag, { 1 }, empty)
    end
  end
end

-- How each group of items is built: the parent, the tag, its fields, its parts, and the
-- signature of an item (a group whose signatures did not change keeps its elements).
local GROUPS = {
  {
    kind = "series",
    tag = "series",
    fields = function(name, i, model)
      return named(name, model.other and model.other[i] and { "other" } or nil)
    end,
    parts = function(model)
      return parts(
        model.boxes and { "value", "outlier", "mean" } or (model.pie and {} or { "point" })
      )
    end,
    sig = function(name, i, model)
      return tostring(name) .. (model.other and model.other[i] and "\2o" or "")
    end,
  },
  {
    kind = "legend",
    tag = "legend-item",
    legend = true,
    fields = function(name)
      return named(name)
    end,
    parts = function(model)
      return model.pie and parts({ "label", "value", "percent" }) or nil
    end,
    sig = tostring,
  },
  {
    kind = "marks",
    tag = "mark",
    fields = function(m)
      return {
        classes = nn(m.class) and { m.class } or {},
        attrs = { label = tostring(nn(m.label) or nn(m.value) or "") },
      }
    end,
    sig = function(m)
      return tostring(nn(m.class)) .. "\2" .. tostring(nn(m.label) or nn(m.value))
    end,
  },
  {
    kind = "bars",
    tag = "bar",
    fields = function(b)
      local f = named(b.category)
      f.attrs = { category = tostring(b.category), series = tostring(b.series) }
      return f
    end,
    parts = function()
      return parts({ "value" })
    end,
    sig = function(b)
      return tostring(b.category) .. "\2" .. tostring(b.series)
    end,
  },
  {
    kind = "cells",
    tag = "cell",
    fields = function(c)
      return { attrs = { x = c.x, y = c.y } }
    end,
    sig = function(c)
      return c.x .. "\2" .. c.y
    end,
  },
  {
    kind = "stats",
    tag = "stat",
    fields = function(st)
      return named(st.name)
    end,
    parts = function()
      return function(node, st, i)
        local tags = i == 1 and { "value", "unit", "label", "delta", "sparkline" }
          or { "value", "unit", "label" }
        for _, tag in ipairs(tags) do
          -- the value carries its threshold class
          content.children(node, tag, { 1 }, function()
            return tag == "value" and { classes = st.classes } or {}
          end)
        end
      end
    end,
    -- the class is part of the signature: a value crossing a threshold updates its element
    sig = function(st)
      return st.name .. "\2" .. table.concat(st.classes, ".")
    end,
  },
}

---Build the elements of a model (a chart type's items).
---@return dbdash.dom.Node chart
function M.build(chart, model)
  local legend = require("dbdash.css").scope(chart):part("legend")
  local prev, sigs = chart.content_items or {}, chart.content_sigs or {}
  local items, new_sigs = {}, {}
  for _, g in ipairs(GROUPS) do
    local list = model[g.kind] or {}
    local s = {}
    for i, it in ipairs(list) do
      s[i] = g.sig(it, i, model)
    end
    local sig = table.concat(s, "\1")
    new_sigs[g.kind] = sig
    if prev[g.kind] and sigs[g.kind] == sig then
      -- a new result of the same shape: the items' elements stay as they are (the
      -- values they show are read by layout from the result)
      items[g.kind] = prev[g.kind]
    else
      items[g.kind] = content.children(g.legend and legend or chart, g.tag, list, function(it, i)
        return g.fields(it, i, model)
      end, g.parts and g.parts(model) or nil)
    end
  end
  chart.content_items, chart.content_sigs = items, new_sigs
  return chart
end

---A chart type's parts (its `parts`: render/content builds them with it) from its model:
---fun(rs, show) -> { series, legend, marks, bars, cells, stats, ... }.
---@param model fun(rs: dbdash.db.ResultSet, show: table): table
function M.parts(model)
  return {
    key = M.key,
    build = function(chart, rs, show)
      return M.build(chart, model(rs, show))
    end,
  }
end

return M
