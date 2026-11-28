-- Histogram, vertical bars with 1/8-cell precision.
local bars = require("dbdash.render.charts.lib.bars")
local fmt = require("dbdash.render.format")

local M = {
  name = "vertical",
  render = function(rs, show, ctx)
    local bins, vals = bars.histogram(rs, show, ctx)
    local o = bars.options(show, ctx)
    o.fine, o.marks, o.stacked, o.axes = true, nil, false, nil
    -- Columns are labeled with their lower bin edge; "[a, b)" does not fit under a column.
    -- as many decimals as the bin width needs (a width of 5.4: one decimal; 10: none)
    local width = #bins > 0 and (bins[1].upper - bins[1].lower) or 1
    local decimals = width >= 1 and 0 or math.min(6, math.ceil(-math.log10(width)) + 1)
    for _, b in ipairs(bins) do
      b.label = fmt.number(b.lower, decimals)
    end
    -- mark_lines are values of the data: the bin they fall in is colored
    for _, m in ipairs(bars.histogram_marks(show, bins, vals)) do
      m.bin.group = bars.mark_group(ctx, m)
    end
    return bars.vertical(ctx, bins, o)
  end,
}

return M
