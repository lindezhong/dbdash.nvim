-- ASCII canvas: 1 pixel per character, for terminals without Unicode block glyphs.
local base = require("dbdash.render.canvas.base")

return base.define("ascii", 1, 1, function()
  return 1
end, function(mask)
  return mask == 0 and " " or "*"
end)
