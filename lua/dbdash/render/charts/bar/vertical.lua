-- Bar chart, vertical bars.
local bars = require("dbdash.render.charts.lib.bars")

local M = {
  name = "vertical",
  render = function(rs, show, ctx)
    local list, legend = bars.from_show(rs, show, ctx)
    local o = bars.options(show, ctx, legend)
    o.fine = false
    return bars.vertical(ctx, list, o)
  end,
}

return M
