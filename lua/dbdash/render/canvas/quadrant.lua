-- Quadrant canvas: 2x2 pixels per character using block quadrants.
local base = require("dbdash.render.canvas.base")

-- Index = bits (1 top-left, 2 top-right, 4 bottom-left, 8 bottom-right).
local GLYPHS = {
  [0] = " ",
  "▘",
  "▝",
  "▀",
  "▖",
  "▌",
  "▞",
  "▛",
  "▗",
  "▚",
  "▐",
  "▜",
  "▄",
  "▙",
  "▟",
  "█",
}

return base.define("quadrant", 2, 2, function(sx, sy)
  return sy == 0 and (sx == 0 and 1 or 2) or (sx == 0 and 4 or 8)
end, function(mask)
  return GLYPHS[mask]
end)
