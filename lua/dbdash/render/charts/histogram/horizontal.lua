-- Histogram, horizontal bars with 1/8-cell precision.
local bars = require("dbdash.render.charts.lib.bars")

local M = {
  name = "horizontal",
  render = function(rs, show, ctx)
    local bins, vals = bars.histogram(rs, show, ctx)
    local o = bars.options(show, ctx)
    o.fine, o.marks, o.stacked, o.axes = true, nil, false, nil
    -- mark_lines are values of the data: the bin they fall in is colored and labeled
    for _, m in ipairs(bars.histogram_marks(show, bins, vals)) do
      m.bin.group = bars.mark_group(ctx, m)
      m.bin.label = m.bin.label .. " ◀ " .. m.label
    end
    return bars.horizontal(ctx, bins, o)
  end,
}

return M
