-- The progress chart type (an example of a chart type of your own, :help dbdash-extend): a
-- bar per row, value_column out of show.max, labelled by label_column. A chart type is a
-- directory render/charts/<type>/ on the runtimepath: this init.lua, its renderers and
-- (optionally) its validate.lua.
local content = require("dbdash.render.content.chart")
local C = require("dbdash.render.charts.lib.common")
local nn = require("dbdash.util.null").nn

local M = {
  -- its renderers (bar.lua next to this file), the first the default
  renderers = { "bar" },
  -- its content as DOM: one bar per row (bar[category] > value), styled by sheets
  parts = content.parts(function(rs, show)
    local li = C.col(rs, nn(show.label_column), "label_column")
    local bars = {}
    for i, row in ipairs(rs.rows) do
      bars[i] = { category = C.text(row[li]), series = nn(show.value_column) }
    end
    return { series = {}, legend = {}, bars = bars }
  end),
  -- the default style of its parts
  style = {
    ["chart.progress bar"] = { color = "DbDashSeries1" },
    ["chart.progress value"] = { color = "DbDashMuted" },
  },
}

return M
