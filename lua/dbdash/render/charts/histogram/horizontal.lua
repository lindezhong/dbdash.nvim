-- Histogram, horizontal bars with 1/8-cell precision.
local C = require("dbdash.render.charts.common")
local bars = require("dbdash.render.charts.bars")

return {
  name = "horizontal",
  render = function(rs, show, ctx)
    local style = C.nn(show.style) or {}
    local axes = C.axes(show)
    return bars.horizontal(ctx, bars.histogram(rs, show, ctx), {
      title = C.nn(show.title),
      xlabel = axes.xlabel,
      ylabel = axes.ylabel,
      show_values = C.nn(style.show_values) ~= false,
      fine = true,
    })
  end,
}
