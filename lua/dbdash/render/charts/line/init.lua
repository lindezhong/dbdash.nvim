-- The line chart type (ARCHITECTURE.md#extending):
-- series over an x axis (canvas: braille by default; asciichart).
local content = require("dbdash.render.content.chart")
local nn = require("dbdash.util.null").nn

local M = {
  renderers = { "canvas", "asciichart" },
  canvas = "braille",
  -- series (> point), legend > legend-item, mark (mark_lines)
  parts = content.parts(function(rs, show)
    local names = content.xy_series(rs, show)
    return { series = names, legend = names, marks = nn(show.mark_lines) or {} }
  end),
  style = {
    ["chart.line point"] = { display = "none" }, -- markers on lines
  },
}

return M
