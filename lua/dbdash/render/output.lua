-- Rendered blocks (dbdash.render.Output: lines and highlights) put together.
local M = {}

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

return M
