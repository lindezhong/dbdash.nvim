-- Braille canvas: 2x4 pixels per character (U+2800..U+28FF).
local base = require("dbdash.render.canvas.base")

-- Dot bits by (sub-x, sub-y from top).
local BITS = {
  [0] = { [0] = 0x01, 0x02, 0x04, 0x40 },
  [1] = { [0] = 0x08, 0x10, 0x20, 0x80 },
}

local cache = {}

local M = base.define("braille", 2, 4, function(sx, sy)
  return BITS[sx][sy]
end, function(mask)
  local g = cache[mask]
  if not g then
    local cp = 0x2800 + mask
    g = string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
    cache[mask] = g
  end
  return g
end)

return M
