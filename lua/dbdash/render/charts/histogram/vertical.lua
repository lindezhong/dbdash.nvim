-- Histogram, vertical bars with 1/8-cell precision.
local bars = require("dbdash.render.charts.bars")
local fmt = require("dbdash.render.format")

return {
  name = "vertical",
  render = function(rs, show, ctx)
    local bins, vals = bars.histogram(rs, show, ctx)
    local o = bars.options(show, ctx)
    o.fine, o.marks, o.stacked, o.axes = true, nil, false, nil
    -- Columns are labeled with their lower bin edge; "[a, b)" does not fit under a column.
    for _, b in ipairs(bins) do
      b.label = fmt.number(b.lower)
    end
    -- mark_lines are values of the data: the bin they fall in is colored
    for _, m in ipairs(bars.histogram_marks(show, bins, vals)) do
      m.bin.group = m.color and ctx.color(m.color) or "DbDashMark"
    end
    return bars.vertical(ctx, bins, o)
  end,
}
