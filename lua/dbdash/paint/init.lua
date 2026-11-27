-- Painting (Servo's display list builder): fragments become painted layers in painting
-- order. A panel fragment paints its rows (title, arguments), its chart raster, then its
-- box: padding, border (with the title in it), background (render/box.lua's wrap). The
-- view's display list is the header, then each panel's layer at its position.
local box = require("dbdash.render.box")
local stack = require("dbdash.render.output").stack

local M = {}

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
---@field body dbdash.render.Output?

---The display list of a view: layers with their position (cells), in painting order.
---@return dbdash.paint.DisplayList
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
      list.hits[#list.hits + 1] = {
        row_s = h.row_s + shift,
        row_e = h.row_e + shift,
        x = h.x,
        width = h.width,
        node = h.node,
      }
    end
    list.hits[#list.hits + 1] = {
      row_s = 0,
      row_e = #body.lines - 1,
      x = 0,
      width = tree.single.width,
      node = tree.single.node,
    }
  else
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
    list.hits = {}
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
  end
  return list
end

return M
