-- A document (after Servo's script/dom/document): the root of a node tree plus what the
-- next rendering update has to do. Changes only mark state here; the work happens once
-- per update (dbdash.pipeline): restyle from the dirty root, then layout and paint.
--   pending      nodes that changed since the last update, with the kind of change
--   dirty_root   the lowest common ancestor of the dirty nodes (restyle starts there)
--   reasons      document-wide reasons to restyle (sheets changed, viewport, theme)
local node = require("dbdash.dom.node")

local M = {}

---@class dbdash.dom.Document
---@field root dbdash.dom.Node
---@field sheets table[] style sheets, each { origin, rules, scope? } (css/cascade.lua)
---@field pending table<dbdash.dom.Node, string>
---@field dirty_root dbdash.dom.Node?
---@field reasons table<string, boolean>
---@field version integer bumped by every change
---@field on_update fun()? called when the document gets something to update (set by its view)
---@field updating boolean? a frame is updating it (changes then need no other frame)
---@field data_changed boolean? an element's data changed (Node:set_data) since the last frame
---@field restyled table? what the last restyle did (css/style.lua, for tests and :DbDashInspect)
---@field drawn_version integer? the version the last frame showed (Document:drawn)
local Document = {}
Document.__index = Document

---@param root_tag string? the root element (default "dashboard")
---@return dbdash.dom.Document
function M.new(root_tag)
  local doc = setmetatable({ sheets = {}, pending = {}, reasons = {}, version = 0 }, Document)
  doc.root = node.new(root_tag or "dashboard")
  doc.root:adopt(doc)
  doc:note_dirty(doc.root, node.OTHER)
  return doc
end

---Lowest common ancestor of two nodes of the same tree.
local function common_ancestor(a, b)
  -- the usual case: the dirty root is already an ancestor of the new dirty node
  local n = b
  while n do
    if n == a then
      return a
    end
    n = n.parent
  end
  local seen = {}
  for _, x in ipairs(a:ancestors()) do
    seen[x] = true
  end
  for _, x in ipairs(b:ancestors()) do
    if seen[x] then
      return x
    end
  end
  return nil
end

---Record a dirty node (Servo: Element::restyle + note_dirty_element).
function Document:note_dirty(n, kind)
  local idle = not self:needs_update()
  self.version = self.version + 1
  n:bump()
  local prev = self.pending[n]
  -- style (restyle) and content (relayout) are different needs: both together are other
  if not prev or prev == kind then
    self.pending[n] = kind
  else
    self.pending[n] = "other"
  end
  local p = n.parent
  while p and not p.dirty_descendants do
    p.dirty_descendants = true
    p = p.parent
  end
  self.dirty_root = self.dirty_root and common_ancestor(self.dirty_root, n) or n
  if idle then
    self:updated()
  end
end

---The document has something to update now (it had nothing): on_update, set by the view
---showing it, asks for a frame (as a DOM change schedules a rendering update in a browser).
function Document:updated()
  if self.on_update and not self.updating then
    self.on_update()
  end
end

---A document-wide reason to restyle (Servo's RestyleReason): "sheets", "viewport",
---"theme".
function Document:note_reason(reason)
  local idle = not self:needs_update()
  self.version = self.version + 1
  self.reasons[reason] = true
  if idle then
    self:updated()
  end
end

---An element's data changed: the next frame shows it (nothing to restyle or lay out).
function Document:note_data()
  local idle = not self:needs_update() and not self.data_changed
  self.data_changed = true
  if idle then
    self:updated()
  end
end

---Does the next frame have to update the rendering (data changes aside)? Something changed
---since the last frame: a style query (css/style.get) may have restyled it already, as
---getComputedStyle flushes styles in a browser, but it is not drawn yet.
function Document:needs_frame()
  return self.version ~= self.drawn_version or self:needs_update()
end

---The view drew the document as it is now (the end of a frame).
function Document:drawn()
  self.drawn_version = self.version
end

---Is there anything for the next update to do (data changes aside)?
function Document:needs_update()
  return self.dirty_root ~= nil or next(self.reasons) ~= nil
end

---Hand the dirty state to an update and reset it: the dirty root, the pending kind of
---each node, the reasons.
---@return dbdash.dom.Node? dirty_root
---@return table<dbdash.dom.Node, string> pending
---@return table<string, boolean> reasons
function Document:take_dirty()
  local root, pending, reasons = self.dirty_root, self.pending, self.reasons
  self.dirty_root, self.pending, self.reasons = nil, {}, {}
  -- the flags were set from each dirty node up: clear those paths only
  for n in pairs(pending) do
    local p = n.parent
    while p and p.dirty_descendants do
      p.dirty_descendants = false
      p = p.parent
    end
  end
  return root, pending, reasons
end

---Replace the style sheets of one origin (and scope); a document-wide restyle.
---@param origin string
---@param rules table[] parsed rules (css/parser.lua)
---@param scope dbdash.dom.Node? an inline sheet applies to this subtree only
function Document:set_sheet(origin, rules, scope)
  for i = #self.sheets, 1, -1 do
    local s = self.sheets[i]
    if s.origin == origin and s.scope == scope then
      table.remove(self.sheets, i)
    end
  end
  self.sheets[#self.sheets + 1] = { origin = origin, rules = rules, scope = scope }
  self:note_reason("sheets")
end

---Node by id (the first one).
function Document:get_by_id(id)
  return self.root:find(function(n)
    return n.id == id
  end)
end

M.Document = Document

return M
