-- Half-block canvas for line-style charts: same geometry as "block".
-- (The heatmap's halfblock style colors upper and lower halves separately; see
-- charts/heatmap/halfblock.lua.)
local base = require("dbdash.render.canvas.base")

local GLYPHS = { [0] = " ", "▀", "▄", "█" }

return base.define("halfblock", 1, 2, function(_, sy)
  return sy == 0 and 1 or 2
end, function(mask)
  return GLYPHS[mask]
end)
