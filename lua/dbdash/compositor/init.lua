-- The compositor (Servo's Paint, for a text buffer): places painted layers (each a block
-- of lines with highlights at a cell position) into the buffer's lines, padded by display
-- width, highlights shifted to byte offsets; records each layer's region for hit testing.
local W = require("dbdash.util.width")

local M = {}

---@param cells { row: integer, x: integer, width: integer, y: integer?, height: integer? }[]
---@param outputs dbdash.render.Output[] one per cell
---@return { lines: string[], hl: table[], regions: { row_s: integer, row_e: integer, x: integer, width: integer }[] }
function M.compose(cells, outputs)
  -- Without y / height (the old flow layout): rows as tall as their tallest output,
  -- separated by a blank line.
  if cells[1] and not cells[1].y then
    local heights, nrows = {}, 0
    for i, c in ipairs(cells) do
      heights[c.row] = math.max(heights[c.row] or 0, #outputs[i].lines)
      nrows = math.max(nrows, c.row)
    end
    local y, top = 0, {}
    for r = 1, nrows do
      local h = heights[r] or 0
      if r > 1 and h > 0 then
        y = y + 1
      end
      top[r] = y
      y = y + h
    end
    for i, c in ipairs(cells) do
      c.y, c.height = top[c.row], heights[c.row]
      outputs[i] = outputs[i]
    end
  end
  local lines, hl, regions = {}, {}, {}
  local total = 0
  local by_line = {} -- highlights by cell and output line
  for i, c in ipairs(cells) do
    total = math.max(total, c.y + c.height)
    regions[i] = { row_s = c.y, row_e = c.y + c.height - 1, x = c.x, width = c.width }
    by_line[i] = {}
    for _, h in ipairs(outputs[i].hl) do
      by_line[i][h.row] = by_line[i][h.row] or {}
      table.insert(by_line[i][h.row], h)
    end
  end
  local order = {}
  for i in ipairs(cells) do
    order[i] = i
  end
  table.sort(order, function(a, b)
    return cells[a].x < cells[b].x
  end)
  for L = 0, total - 1 do
    local parts, pos, dcol, keep = {}, 0, 0, false
    for _, i in ipairs(order) do
      local c = cells[i]
      local k = L - c.y + 1
      if k >= 1 and k <= c.height then
        keep = keep or outputs[i].full == true
        if c.x > dcol then
          local pad = string.rep(" ", c.x - dcol)
          parts[#parts + 1] = pad
          pos = pos + #pad
          dcol = c.x
        end
        local text = outputs[i].lines[k] or ""
        local cut = W.truncate(text, c.width, "")
        for _, h in ipairs(by_line[i][k - 1] or {}) do
          local s, e = math.min(h.col_s, #cut), math.min(h.col_e, #cut)
          if e > s then
            hl[#hl + 1] = { row = L, col_s = pos + s, col_e = pos + e, group = h.group, priority = h.priority }
          end
        end
        local cell = W.pad(cut, c.width)
        parts[#parts + 1] = cell
        pos = pos + #cell
        dcol = dcol + c.width
      end
    end
    -- Boxed cells (a background or border) keep their full width.
    local line = table.concat(parts)
    lines[#lines + 1] = keep and line or (line:gsub("%s+$", ""))
  end
  return { lines = lines, hl = hl, regions = regions }
end

return M
