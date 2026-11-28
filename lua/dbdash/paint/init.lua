-- Painting (Servo's display list builder): fragments become painted layers in painting
-- order. A panel fragment paints its rows (title, arguments), its chart raster, then its
-- box: padding, border (with the title in it), background (paint/box.lua's wrap). The
-- view's display list is the header, then each panel's layer at its position.
local box = require("dbdash.paint.box")
local stack = require("dbdash.render.output").stack

local M = {}

---Where a panel's status goes (view/dashboard.lua): the free part of its title line, after
---the title and ⓘ, in cells of the painted panel: `from` up to `to` (exclusive), `start`
---the line's first cell (countdown_position = "overlay"). On a border: its top line.
---@return dbdash.paint.StatusSlot?
local function status_slot(frag, painted, title_top, left, inner_w)
  local line = frag.title_line
  if not line then
    return nil
  end
  if frag.box and frag.box.border then
    local from = painted.title_end and painted.title_end + 1 or 2
    return { row = 0, start = 2, from = from, to = frag.width - 1 }
  end
  if not title_top then
    return nil
  end
  local used = line.used + (line.used > 0 and 1 or 0) -- a space after the title
  return { row = title_top, start = left, from = left + used, to = left + inner_w }
end

---@class dbdash.paint.StatusSlot
---@field row integer
---@field start integer the line's first cell
---@field from integer the first free cell
---@field to integer the end of the free cells (exclusive)

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
  local title_top -- the row of the title line (its status goes there)
  local function add(part, node)
    if part.title_line then
      title_top = top
    end
    if node and #part.lines > 0 then
      hits[#hits + 1] =
        { row_s = top, row_e = top + #part.lines - 1, x = left, width = inner_w, node = node }
    end
    for _, h in ipairs(part.hits or {}) do -- elements inside the part, by rows
      hits[#hits + 1] =
        { row_s = top + h.row_s, row_e = top + h.row_e, x = left, width = inner_w, node = h.node }
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
  frag.painted.status_slot = status_slot(frag, frag.painted, title_top, left, inner_w)
  return frag.painted
end

---@class dbdash.paint.Layer
---@field x integer
---@field y integer
---@field width integer
---@field height integer
---@field out dbdash.render.Output
---@field node dbdash.dom.Node?

---@class dbdash.paint.DisplayList
---@field header dbdash.render.Output
---@field layers dbdash.paint.Layer[]
---@field hits dbdash.paint.Hit[]?

---@class dbdash.paint.Hit where an element is drawn
---@field row_s integer
---@field row_e integer
---@field x integer
---@field width integer
---@field node dbdash.dom.Node

---The display list of a view: layers with their position (cells), in painting order.
---@return dbdash.paint.DisplayList
function M.view(tree)
  local list = { header = tree.header, layers = {}, hits = {} }
  if tree.grid.error then
    list.header = stack({
      tree.header,
      {
        lines = { tree.grid.error },
        hl = { { row = 0, col_s = 0, col_e = #tree.grid.error, group = "DbDashError" } },
      },
    })
  end
  for _, f in ipairs(tree.grid.fragments) do
    list.layers[#list.layers + 1] =
      { x = f.x, y = f.y, width = f.width, height = f.height, out = M.fragment(f), node = f.node }
  end
  for _, l in ipairs(list.layers) do
    list.hits[#list.hits + 1] =
      { row_s = l.y, row_e = l.y + l.height - 1, x = l.x, width = l.width, node = l.node }
    for _, h in ipairs(l.out.hits or {}) do
      list.hits[#list.hits + 1] = {
        row_s = l.y + h.row_s,
        row_e = l.y + h.row_e,
        x = l.x + h.x,
        width = h.width,
        node = h.node,
      }
    end
  end
  return list
end

return M
