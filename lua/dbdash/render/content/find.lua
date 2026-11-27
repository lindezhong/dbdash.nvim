-- Finding a chart's content elements, for its renderer: an item by kind and position, a
-- child of an item.
local M = {}

---The element of a kind of item at a position (nil when the content has none).
---@param chart dbdash.dom.Node
---@param kind "series"|"legend"|"marks"|"bars"|"cells"|"stats"
function M.item(chart, kind, i)
  local items = chart and chart.content_items
  return items and items[kind] and items[kind][i] or nil
end

---A child element of an item (`value` of a bar, `label` of a legend item, ...).
function M.child(node, tag)
  if not node then
    return nil
  end
  for _, c in ipairs(node.children) do
    if c.tag == tag then
      return c
    end
  end
end

return M
