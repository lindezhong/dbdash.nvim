-- bubble chart on a pixel canvas (braille by default; see show.canvas).
local M = {
  name = "canvas",
  render = function(rs, show, ctx)
    return require("dbdash.render.charts.lib.xy").render(rs, show, ctx, "bubble")
  end,
}

return M
