-- Bar chart, vertical bars.
local C = require("dbdash.render.charts.common")
local bars = require("dbdash.render.charts.bars")

return {
  name = "vertical",
  render = function(rs, show, ctx)
    local style = C.nn(show.style) or {}
    local axes = C.axes(show)
    return bars.vertical(ctx, bars.from_show(rs, show, ctx), {
      title = C.nn(show.title),
      xlabel = axes.xlabel,
      ylabel = axes.ylabel,
      show_values = C.nn(style.show_values) ~= false,
      fine = false,
      value_format = axes.yformat,
    })
  end,
}
