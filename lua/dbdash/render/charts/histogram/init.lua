-- The histogram chart type (ARCHITECTURE.md#extending):
-- the values of one column counted in bins.
local content = require("dbdash.render.content.chart")
local nn = require("dbdash.util.null").nn

local M = {
  renderers = { "horizontal", "vertical" },
  -- bar (one per bin) > value, mark
  parts = content.parts(function(rs, show)
    local bins = require("dbdash.render.charts.lib.bars").bins(rs, show)
    local bars = {}
    for i, b in ipairs(bins) do
      bars[i] = { category = b.label, series = nn(show.value_column) }
    end
    return {
      series = { nn(show.value_column) },
      legend = {},
      bars = bars,
      marks = nn(show.mark_lines) or {},
    }
  end),
  style = {},
}

return M
