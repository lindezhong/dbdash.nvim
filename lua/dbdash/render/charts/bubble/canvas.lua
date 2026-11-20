-- bubble chart on a pixel canvas (braille by default; see show.canvas).
return {
  name = "canvas",
  render = function(rs, show, ctx)
    return require("dbdash.render.charts.xy").render(rs, show, ctx, "bubble")
  end,
}
