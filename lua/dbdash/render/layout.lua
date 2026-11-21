-- Grid layout for multi-panel dashboards (pure: no Neovim API calls).
--
-- plan() assigns each panel a cell (grid row, column, width); panels flow left to right
-- and wrap when their span does not fit. compose() places rendered outputs into one
-- buffer: cells in a grid row sit side by side (padded by display width, highlights
-- shifted by byte offsets), shorter cells are padded with empty lines, and grid rows are
-- separated by a blank line.
local W = require("dbdash.util.width")

local M = {}

---@class dbdash.layout.Cell
---@field row integer grid row (1-based)
---@field col integer first grid column (0-based)
---@field width integer display width
---@field x integer display column where the cell starts

---@param spans integer[] span of each panel
---@param width integer available display width
---@param columns integer
---@param gap integer spaces between cells
---@return dbdash.layout.Cell[]
function M.plan(spans, width, columns, gap)
  columns = math.max(1, columns)
  local col_w = math.max(10, math.floor((width - gap * (columns - 1)) / columns))
  local cells, row, used = {}, 1, 0
  for i, span in ipairs(spans) do
    span = math.max(1, math.min(span, columns))
    if used > 0 and used + span > columns then
      row, used = row + 1, 0
    end
    cells[i] = {
      row = row,
      col = used,
      width = col_w * span + gap * (span - 1),
      x = used * (col_w + gap),
    }
    used = used + span
  end
  return cells
end

---@param cells dbdash.layout.Cell[]
---@param outputs dbdash.render.Output[] one per cell
---@return { lines: string[], hl: table[], regions: { row_s: integer, row_e: integer, x: integer, width: integer }[] }
function M.compose(cells, outputs)
  local lines, hl, regions = {}, {}, {}
  local rows = {}
  for i, c in ipairs(cells) do
    rows[c.row] = rows[c.row] or {}
    table.insert(rows[c.row], i)
  end
  local nrows = 0
  for r in pairs(rows) do
    nrows = math.max(nrows, r)
  end
  for r = 1, nrows do
    local members = rows[r] or {}
    table.sort(members, function(a, b)
      return cells[a].col < cells[b].col
    end)
    local height = 0
    for _, i in ipairs(members) do
      height = math.max(height, #outputs[i].lines)
    end
    if r > 1 and height > 0 then
      lines[#lines + 1] = ""
    end
    local top = #lines -- 0-based row of this grid row's first line
    -- Index highlights by output line once.
    local by_line = {}
    for _, i in ipairs(members) do
      by_line[i] = {}
      for _, h in ipairs(outputs[i].hl) do
        by_line[i][h.row] = by_line[i][h.row] or {}
        table.insert(by_line[i][h.row], h)
      end
      regions[i] = { row_s = top, row_e = top + height - 1, x = cells[i].x, width = cells[i].width }
    end
    for k = 1, height do
      local parts, pos, dcol = {}, 0, 0
      for _, i in ipairs(members) do
        local c = cells[i]
        if c.x > dcol then
          local pad = string.rep(" ", c.x - dcol)
          parts[#parts + 1] = pad
          pos = pos + #pad
          dcol = c.x
        end
        local text = outputs[i].lines[k] or ""
        local cut = W.truncate(text, c.width, "")
        local base = pos
        for _, h in ipairs(by_line[i][k - 1] or {}) do
          local s, e = math.min(h.col_s, #cut), math.min(h.col_e, #cut)
          if e > s then
            hl[#hl + 1] = { row = #lines, col_s = base + s, col_e = base + e, group = h.group }
          end
        end
        local cell = W.pad(cut, c.width)
        parts[#parts + 1] = cell
        pos = pos + #cell
        dcol = dcol + c.width
      end
      lines[#lines + 1] = (table.concat(parts):gsub("%s+$", ""))
    end
  end
  return { lines = lines, hl = hl, regions = regions }
end

return M
