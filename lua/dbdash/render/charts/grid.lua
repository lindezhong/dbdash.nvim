-- A grid of character cells with their highlights, row 0 at the top (charts drawn cell by
-- cell: box plots, bars, asciichart lines), and its output as lines.
local M = {}

---@class dbdash.render.charts.Grid cells of a chart, row 0 at the top
---@field rows integer
---@field cols integer
---@field cells table<integer, table<integer, string>>
---@field colors table<integer, table<integer, string>>
local Grid = {}
Grid.__index = Grid

---@return dbdash.render.charts.Grid
function M.new(rows, cols)
  local g = setmetatable({ rows = rows, cols = cols, cells = {}, colors = {} }, Grid)
  for r = 0, rows - 1 do
    g.cells[r], g.colors[r] = {}, {}
  end
  return g
end

---Put `ch` (highlight `group`) at (r, c) inside the grid; only_blank: not over another.
function Grid:put(r, c, ch, group, only_blank)
  if
    r >= 0
    and r < self.rows
    and c >= 0
    and c < self.cols
    and (not only_blank or not self.cells[r][c])
  then
    self.cells[r][c], self.colors[r][c] = ch, group
  end
end

---Text from (r, c) on, a character per cell.
function Grid:text(r, c, text, group, only_blank)
  for k = 1, #text do
    self:put(r, c + k - 1, text:sub(k, k), group, only_blank)
  end
end

---The grid as lines with highlights.
function Grid:output()
  local lines, hl = {}, {}
  for r = 0, self.rows - 1 do
    local parts, pos = {}, 0
    for c = 0, self.cols - 1 do
      local ch = self.cells[r][c] or " "
      if self.colors[r][c] then
        hl[#hl + 1] = { row = r, col_s = pos, col_e = pos + #ch, group = self.colors[r][c] }
      end
      parts[#parts + 1] = ch
      pos = pos + #ch
    end
    lines[#lines + 1] = table.concat(parts)
  end
  return { lines = lines, hl = hl }
end

return M
