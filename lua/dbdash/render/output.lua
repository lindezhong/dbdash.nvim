-- Rendered blocks (dbdash.render.Output: lines and highlights) put together, and a title
-- line.
local W = require("dbdash.util.width")

local M = {}

---A title line of `width` cells: `text` aligned left, center or right.
---@return string line, integer col_s, integer col_e byte range of the text
function M.title_line(text, width, align, ellipsis)
  local t = W.truncate(text, width, ellipsis)
  local gap = math.max(0, width - W.width(t))
  local lead = align == "center" and math.floor(gap / 2) or (align == "right" and gap or 0)
  local line = string.rep(" ", lead) .. t
  return line, lead, lead + #t
end

---`parts` (painted blocks) one after another.
function M.stack(parts)
  local out = { lines = {}, hl = {} }
  for _, part in ipairs(parts) do
    local off = #out.lines
    vim.list_extend(out.lines, part.lines)
    for _, h in ipairs(part.hl) do
      out.hl[#out.hl + 1] = {
        row = h.row + off,
        col_s = h.col_s,
        col_e = h.col_e,
        group = h.group,
        priority = h.priority,
      }
    end
    -- the rows of elements inside a part (a table's rows, a text's lines) move with it
    for _, h in ipairs(part.hits or {}) do
      out.hits = out.hits or {}
      out.hits[#out.hits + 1] = { row_s = h.row_s + off, row_e = h.row_e + off, node = h.node }
    end
  end
  return out
end

---`parts` side by side, each `width` cells wide (cut to it), `gap` cells apart; lines as
---many as the tallest, without trailing blanks.
---@param parts dbdash.render.Output[]
---@return dbdash.render.Output
function M.beside(parts, width, gap)
  local out = { lines = {}, hl = {} }
  local rows = 0
  for _, part in ipairs(parts) do
    rows = math.max(rows, #part.lines)
  end
  for row = 0, rows - 1 do
    local texts, pos = {}, 0
    for i, part in ipairs(parts) do
      if i > 1 then
        texts[#texts + 1] = string.rep(" ", gap)
        pos = pos + gap
      end
      local cut = W.truncate(part.lines[row + 1] or "", width, "")
      for _, h in ipairs(part.hl) do
        local s, e = math.min(h.col_s, #cut), math.min(h.col_e, #cut)
        if h.row == row and e > s then
          out.hl[#out.hl + 1] =
            { row = row, col_s = pos + s, col_e = pos + e, group = h.group, priority = h.priority }
        end
      end
      local cell = W.pad(cut, width)
      texts[#texts + 1] = cell
      pos = pos + #cell
    end
    out.lines[#out.lines + 1] = (table.concat(texts):gsub("%s+$", ""))
  end
  return out
end

return M
