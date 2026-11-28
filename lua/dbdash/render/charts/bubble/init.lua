-- The bubble chart type (ARCHITECTURE.md#extending):
-- scatter points sized by size_column.
local content = require("dbdash.render.content.chart")
local nn = require("dbdash.util.null").nn

local M = {
  renderers = { "canvas" },
  canvas = "braille",
  -- series (> point), legend > legend-item, mark (mark_lines)
  parts = content.parts(function(rs, show)
    local names = content.xy_series(rs, show)
    return { series = names, legend = names, marks = nn(show.mark_lines) or {} }
  end),
  style = {},
}

return M
