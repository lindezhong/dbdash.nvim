-- The bar chart type (ARCHITECTURE.md#extending):
-- one value per category, grouped or stacked series.
local content = require("dbdash.render.content.chart")
local nn = require("dbdash.util.null").nn

local M = {
  renderers = { "horizontal", "vertical" },
  -- series, bar[category][series] > value, legend > legend-item (several series), mark
  parts = content.parts(function(rs, show)
    local names, cats = content.bar_model(rs, show)
    local bars = {}
    for _, c in ipairs(cats) do
      for _, s in ipairs(names) do
        bars[#bars + 1] = { category = c, series = s }
      end
    end
    return {
      series = names,
      legend = #names > 1 and names or {},
      bars = bars,
      marks = nn(show.mark_lines) or {},
    }
  end),
  style = {},
}

return M
