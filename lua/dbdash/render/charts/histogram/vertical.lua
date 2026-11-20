-- Histogram, vertical bars with 1/8-cell precision.
local C = require("dbdash.render.charts.common")
local bars = require("dbdash.render.charts.bars")

return {
  name = "vertical",
  render = function(rs, show, ctx)
    local style = C.nn(show.style) or {}
    local axes = C.axes(show)
    -- Columns are labeled with their lower bin edge; "[a, b)" does not fit under a column.
    local bins = bars.histogram(rs, show, ctx)
    for _, b in ipairs(bins) do
      b.label = require("dbdash.render.format").number(b.lower)
    end
    return bars.vertical(ctx, bins, {
      title = C.nn(show.title),
      xlabel = axes.xlabel,
      ylabel = axes.ylabel,
      show_values = C.nn(style.show_values) ~= false,
      fine = true,
    })
  end,
}
