-- Pixel canvas shared by all canvas types (after UnicodePlots).
--
-- A canvas is `cols` x `rows` characters; each character holds px_x * px_y pixels.
-- Pixel coordinates start at the bottom-left (y grows upwards); data coordinates map onto
-- [xlim] x [ylim]. Each character cell has one color: the last one drawn wins.
local M = {}

---@class dbdash.render.Canvas
---@field cols integer
---@field rows integer
---@field px_x integer
---@field px_y integer
---@field xlim number[]
---@field ylim number[]
---@field glyph fun(mask: integer): string
local Canvas = {}
Canvas.__index = Canvas

---Define a canvas type.
---@param name string
---@param px_x integer pixels per character horizontally
---@param px_y integer pixels per character vertically
---@param bit fun(sx: integer, sy: integer): integer mask bit for sub-pixel (sx, sy from top-left)
---@param glyph fun(mask: integer): string
function M.define(name, px_x, px_y, bit, glyph)
  local T = { name = name, px_per_char = { x = px_x, y = px_y } }
  ---@return dbdash.render.Canvas
  function T.new(cols, rows, xlim, ylim)
    local c = setmetatable({
      cols = cols,
      rows = rows,
      px_x = px_x,
      px_y = px_y,
      xlim = xlim or { 0, 1 },
      ylim = ylim or { 0, 1 },
      glyph = glyph,
      bit = bit,
      masks = {},
      colors = {},
      texts = {},
    }, Canvas)
    return c
  end
  return T
end

function Canvas:width_px()
  return self.cols * self.px_x
end

function Canvas:height_px()
  return self.rows * self.px_y
end

---Set a pixel (0-based, origin bottom-left). Out-of-range pixels are ignored.
function Canvas:pixel(px, py, color)
  px, py = math.floor(px), math.floor(py)
  if px < 0 or py < 0 or px >= self.cols * self.px_x or py >= self.rows * self.px_y then
    return
  end
  local col = math.floor(px / self.px_x)
  local top = self.rows * self.px_y - 1 - py -- pixel row from the top
  local row = math.floor(top / self.px_y)
  local idx = row * self.cols + col
  local b = self.bit(px % self.px_x, top % self.px_y)
  self.masks[idx] = bit.bor(self.masks[idx] or 0, b)
  if color then
    self.colors[idx] = color
  end
end

---Data x -> pixel x (float).
function Canvas:to_px(x)
  local lo, hi = self.xlim[1], self.xlim[2]
  if hi == lo then
    return 0
  end
  return (x - lo) / (hi - lo) * (self.cols * self.px_x - 1)
end

---Data y -> pixel y (float).
function Canvas:to_py(y)
  local lo, hi = self.ylim[1], self.ylim[2]
  if hi == lo then
    return 0
  end
  return (y - lo) / (hi - lo) * (self.rows * self.px_y - 1)
end

function Canvas:point(x, y, color)
  self:pixel(math.floor(self:to_px(x) + 0.5), math.floor(self:to_py(y) + 0.5), color)
end

---Line between data points (DDA in pixel space).
function Canvas:line(x1, y1, x2, y2, color)
  local ax, ay = self:to_px(x1), self:to_py(y1)
  local bx, by = self:to_px(x2), self:to_py(y2)
  local dx, dy = bx - ax, by - ay
  local n = math.max(math.abs(dx), math.abs(dy))
  if n < 1 then
    self:pixel(math.floor(ax + 0.5), math.floor(ay + 0.5), color)
    return
  end
  for i = 0, math.ceil(n) do
    local t = i / math.ceil(n)
    self:pixel(math.floor(ax + dx * t + 0.5), math.floor(ay + dy * t + 0.5), color)
  end
end

---Vertical fill from data point (x, y) down to `base` (default: bottom of the canvas).
function Canvas:fill_below(x, y, color, base)
  local px = math.floor(self:to_px(x) + 0.5)
  local top = math.floor(self:to_py(y) + 0.5)
  local bottom = base and math.floor(self:to_py(base) + 0.5) or 0
  if bottom > top then
    top, bottom = bottom, top
  end
  for py = bottom, top do
    self:pixel(px, py, color)
  end
end

---Circle outline of radius r (pixels) around a data point.
function Canvas:circle(x, y, r, color)
  local cx, cy = self:to_px(x), self:to_py(y)
  local steps = math.max(8, math.ceil(2 * math.pi * r))
  for i = 0, steps - 1 do
    local a = 2 * math.pi * i / steps
    self:pixel(math.floor(cx + r * math.cos(a) + 0.5), math.floor(cy + r * math.sin(a) * self.px_y / self.px_x * 0.5 + 0.5), color)
  end
end

---Put text into character cells (row/col 0-based from top-left).
function Canvas:text(row, col, s, color)
  local W = require("dbdash.util.width")
  for ch in W.chars(s) do
    if col >= self.cols then
      break
    end
    local idx = row * self.cols + col
    self.texts[idx] = ch
    self.colors[idx] = color
    col = col + W.width(ch)
  end
end

---Render to lines and highlight spans (byte offsets within each line).
---@return string[] lines, { row: integer, col_s: integer, col_e: integer, group: string }[]
function Canvas:render()
  local lines, hl = {}, {}
  local blank = self.glyph(0)
  for r = 0, self.rows - 1 do
    local parts, pos = {}, 0
    local cur_group, cur_start
    for c = 0, self.cols - 1 do
      local idx = r * self.cols + c
      local ch = self.texts[idx] or (self.masks[idx] and self.glyph(self.masks[idx]) or blank)
      local group = (self.texts[idx] or self.masks[idx]) and self.colors[idx] or nil
      if group ~= cur_group then
        if cur_group then
          hl[#hl + 1] = { row = r, col_s = cur_start, col_e = pos, group = cur_group }
        end
        cur_group, cur_start = group, pos
      end
      parts[#parts + 1] = ch
      pos = pos + #ch
    end
    if cur_group then
      hl[#hl + 1] = { row = r, col_s = cur_start, col_e = pos, group = cur_group }
    end
    lines[#lines + 1] = table.concat(parts)
  end
  return lines, hl
end

M.Canvas = Canvas

return M
