-- Painting (Servo's display list builder): fragments become painted layers in painting
-- order. A panel fragment paints its rows (title, arguments), its chart raster, then its
-- box: padding, border (with the title in it), background (render/box.lua's wrap). The
-- view's display list is the header, then each panel's layer at its position.
local box = require("dbdash.render.box")

local M = {}

---`parts` (painted blocks) one after another.
local function stack(parts)
  local out = { lines = {}, hl = {} }
  for _, part in ipairs(parts) do
    local off = #out.lines
    vim.list_extend(out.lines, part.lines)
    for _, h in ipairs(part.hl) do
      out.hl[#out.hl + 1] = { row = h.row + off, col_s = h.col_s, col_e = h.col_e, group = h.group, priority = h.priority }
    end
  end
  return out
end
M.stack = stack

---Paint one panel fragment: its content in order, wrapped in its box.
---@param frag dbdash.layout.Fragment
---@return dbdash.render.Output
function M.fragment(frag)
  local parts = {}
  for _, r in ipairs(frag.rows or {}) do
    parts[#parts + 1] = r.out
  end
  if frag.chart then
    parts[#parts + 1] = frag.chart.out
  end
  if frag.after then
    parts[#parts + 1] = frag.after.out
  end
  return box.wrap(stack(parts), frag.box, frag.width, frag.height, frag.border_title)
end

---The display list of a view: layers with their position (cells), in painting order.
---@return { header: dbdash.render.Output, layers: { x: integer, y: integer, width: integer, height: integer, out: dbdash.render.Output, node: dbdash.dom.Node? }[], body: dbdash.render.Output? }
function M.view(tree)
  local list = { header = tree.header, layers = {} }
  if tree.single then
    local body = M.fragment(tree.single)
    if tree.args then
      body = stack({ tree.args, { lines = { "" }, hl = {} }, body })
    end
    list.body = body
  else
    for _, f in ipairs(tree.grid.fragments) do
      list.layers[#list.layers + 1] = { x = f.x, y = f.y, width = f.width, height = f.height, out = M.fragment(f), node = f.node }
    end
  end
  return list
end

return M
