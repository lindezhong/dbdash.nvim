-- Block canvas: 1x2 pixels per character using half blocks.
local base = require("dbdash.render.canvas.base")

local GLYPHS = { [0] = " ", "▀", "▄", "█" }

return base.define("block", 1, 2, function(_, sy)
  return sy == 0 and 1 or 2
end, function(mask)
  return GLYPHS[mask]
end)
