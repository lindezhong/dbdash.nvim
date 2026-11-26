-- Bar chart, horizontal bars.
local bars = require("dbdash.render.charts.bars")

return {
  name = "horizontal",
  render = function(rs, show, ctx)
    local list, legend = bars.from_show(rs, show, ctx)
    local o = bars.options(show, ctx, legend)
    o.fine = false
    return bars.horizontal(ctx, list, o)
  end,
}
