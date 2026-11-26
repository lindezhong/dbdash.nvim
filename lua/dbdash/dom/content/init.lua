-- The content of a chart as DOM (the "script" stage, like D3 or Vega building SVG
-- elements): one element per semantic item of the data (a table row and its cells, a
-- line of text, a series, a bar, a slice, a legend item, ...), built from the result set
-- and the show config before styles are computed. Layout and paint (render/) read these
-- elements: their text, their data and their computed style.
--
-- A new result reuses the elements by position, as a keyed diff would: only text,
-- classes, attributes and data that differ are set, so an unchanged element is not dirty
-- and a value change is only content (relayout), not a restyle.
local M = {}

---Counters for tests: elements created and reused, builds skipped (nothing changed).
M.stats = { created = 0, reused = 0, skipped = 0 }

local BUILDERS = {
  table = "dbdash.dom.content.table",
  text = "dbdash.dom.content.text",
}

local function same_list(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function same_data(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if b[k] ~= v then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

---Set an element's text, classes, attributes and data; only what differs marks it dirty.
---@param node dbdash.dom.Node
---@param f { text: string?, classes: string[]?, attrs: table<string, string>?, data: table? }
function M.set(node, f)
  if node.text ~= f.text then
    node:set_text(f.text)
  end
  local classes = f.classes or {}
  if not same_list(node.classes, classes) then
    node:set_classes(classes)
  end
  local attrs = f.attrs or {}
  for k, v in pairs(attrs) do
    if node.attrs[k] ~= v then
      node:set_attr(k, v)
    end
  end
  for k in pairs(node.attrs) do
    if attrs[k] == nil then
      node:set_attr(k, nil)
    end
  end
  if not same_data(node.data, f.data) then
    node.data = f.data
    node:dirty("content")
  end
end

---The children of `tag` of `parent` for `items`: reused by position, new ones appended,
---extra ones removed. `fields(item, i)` gives each element's text, classes, attrs and data;
---`fill(node, item, i)` builds an element's own children, before a new element is attached
---(a new subtree is one insertion, as when a script appends a built fragment).
---@return dbdash.dom.Node[]
function M.children(parent, tag, items, fields, fill)
  local dom = require("dbdash.dom.node")
  local existing = {}
  for _, c in ipairs(parent.children) do
    if c.tag == tag then
      existing[#existing + 1] = c
    end
  end
  local out = {}
  for i, item in ipairs(items) do
    local f = fields(item, i)
    local node = existing[i]
    if node then
      M.stats.reused = M.stats.reused + 1
      M.set(node, f)
      if fill then
        fill(node, item, i)
      end
    else
      M.stats.created = M.stats.created + 1
      node = dom.new(tag, { classes = f.classes, attrs = f.attrs, text = f.text })
      node.data = f.data
      if fill then
        fill(node, item, i)
      end
      parent:append(node)
    end
    out[i] = node
  end
  parent:truncate(tag, #items)
  return out
end

---All children of `tag`, in order.
function M.list(parent, tag)
  local out = {}
  for _, c in ipairs(parent.children) do
    if c.tag == tag then
      out[#out + 1] = c
    end
  end
  return out
end

---Build (or bring up to date) the content of a chart element from a result: skipped when
---the result and the show config are the ones it was built from. Errors of the data (a
---missing column) are raised as render errors.
---@param chart dbdash.dom.Node the chart element
---@param rs dbdash.db.ResultSet
---@param show table
---@return dbdash.dom.Node? root the content's root element (nil for types without one)
function M.build(chart, rs, show)
  local mod = BUILDERS[show.type]
  if not mod then
    return nil
  end
  local key = vim.json.encode(require(mod).key(show))
  local built = chart.content
  if built and built.rs == rs and built.key == key and built.type == show.type then
    M.stats.skipped = M.stats.skipped + 1
    return built.root
  end
  if built and built.type ~= show.type then
    -- another chart type (:DbDashStyle): all of the chart's elements go
    chart:set_children({})
    chart.css_parts = {}
  end
  local root = require(mod).build(chart, rs, show)
  chart.content = { rs = rs, key = key, type = show.type, root = root }
  return root
end

return M
