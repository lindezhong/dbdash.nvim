-- The pie chart type (ARCHITECTURE.md#extending):
-- shares of a whole (a proportional bar by default; circle).
local content = require("dbdash.render.content.chart")

local M = {
  renderers = { "bar", "circle" },
  -- series (a slice; .other), legend > legend-item > label, value, percent
  parts = content.parts(function(rs, show)
    local items = require("dbdash.render.charts.pie.common").items(rs, show, nil)
    local names, other = {}, {}
    for i, it in ipairs(items) do
      names[i] = it.label
      other[i] = it.other or false
    end
    return { series = names, other = other, legend = names, pie = true }
  end),
  style = {
    ["legend-item label"] = { color = "DbDashLegend" }, -- a pie legend's labels
    ["percent"] = { color = "DbDashMuted" },
    ["series.other"] = { color = "DbDashMuted" },
  },
}

return M
