-- The heatmap chart type (ARCHITECTURE.md#extending):
-- a value per x / y cell, as a color.
local content = require("dbdash.render.content.chart")

local M = {
  renderers = { "halfblock", "block" },
  -- cell[x][y]
  parts = content.parts(function(rs, show)
    local g = require("dbdash.render.charts.heatmap.common").grid(rs, show)
    local cells = {}
    for _, y in ipairs(g.ys) do
      for _, x in ipairs(g.xs) do
        cells[#cells + 1] = { x = x, y = y }
      end
    end
    return { series = {}, legend = {}, cells = cells }
  end),
  style = {
    ["chart.heatmap value"] = { display = "none" }, -- numbers in cells
  },
}

return M
