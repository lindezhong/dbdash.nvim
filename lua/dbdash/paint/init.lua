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
    -- the rows of elements inside a part (a table's rows, a text's lines) move with it
    for _, h in ipairs(part.hits or {}) do
      out.hits = out.hits or {}
      out.hits[#out.hits + 1] = { row_s = h.row_s + off, row_e = h.row_e + off, node = h.node }
    end
  end
  return out
end
M.stack = stack

---Paint one panel fragment: its content in order, wrapped in its box.
---@param frag dbdash.layout.Fragment
---@return dbdash.render.Output
function M.fragment(frag)
  if frag.painted then -- a fragment reused from the layout cache paints the same
    return frag.painted
  end
  local parts, hits = {}, {}
  -- hit-test regions of the parts, relative to the box (inside its border and padding)
  local st = frag.box or { pad = { 0, 0, 0, 0 } }
  local b = st.border and 1 or 0
  local top, left = b + st.pad[1], b + st.pad[4]
  local inner_w = frag.width - left - b - st.pad[2]
  local function add(part, node)
    if node and #part.lines > 0 then
      hits[#hits + 1] = { row_s = top, row_e = top + #part.lines - 1, x = left, width = inner_w, node = node }
    end
    for _, h in ipairs(part.hits or {}) do -- elements inside the part, by rows
      hits[#hits + 1] = { row_s = top + h.row_s, row_e = top + h.row_e, x = left, width = inner_w, node = h.node }
    end
    top = top + #part.lines
    parts[#parts + 1] = part
  end
  for _, r in ipairs(frag.rows or {}) do
    add(r.out, r.node)
  end
  if frag.chart then
    add(frag.chart.out, frag.chart.node)
  end
  if frag.after then
    add(frag.after.out, frag.after.node)
  end
  frag.painted = box.wrap(stack(parts), frag.box, frag.width, frag.height, frag.border_title)
  frag.painted.hits = hits
  return frag.painted
end

---The display list of a view: layers with their position (cells), in painting order.
---@return { header: dbdash.render.Output, layers: { x: integer, y: integer, width: integer, height: integer, out: dbdash.render.Output, node: dbdash.dom.Node? }[], body: dbdash.render.Output? }
function M.view(tree)
  local list = { header = tree.header, layers = {} }
  if tree.single then
    local painted = M.fragment(tree.single)
    local body, shift = painted, 0
    if tree.args then
      body = stack({ tree.args, { lines = { "" }, hl = {} }, painted })
      shift = 2
    end
    list.body = body
    list.hits = {}
    for _, h in ipairs(painted.hits or {}) do
      list.hits[#list.hits + 1] = { row_s = h.row_s + shift, row_e = h.row_e + shift, x = h.x, width = h.width, node = h.node }
    end
    list.hits[#list.hits + 1] = { row_s = 0, row_e = #body.lines - 1, x = 0, width = tree.single.width, node = tree.single.node }
  else
    if tree.grid.error then
      list.header = stack({ tree.header, { lines = { tree.grid.error }, hl = { { row = 0, col_s = 0, col_e = #tree.grid.error, group = "DbDashError" } } } })
    end
    for _, f in ipairs(tree.grid.fragments) do
      list.layers[#list.layers + 1] = { x = f.x, y = f.y, width = f.width, height = f.height, out = M.fragment(f), node = f.node }
    end
    list.hits = {}
    for _, l in ipairs(list.layers) do
      list.hits[#list.hits + 1] = { row_s = l.y, row_e = l.y + l.height - 1, x = l.x, width = l.width, node = l.node }
      for _, h in ipairs(l.out.hits or {}) do
        list.hits[#list.hits + 1] = { row_s = l.y + h.row_s, row_e = l.y + h.row_e, x = l.x + h.x, width = h.width, node = h.node }
      end
    end
  end
  return list
end

return M
