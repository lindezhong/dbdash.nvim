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
  local seen = {}
  for _, n in ipairs(a:ancestors()) do
    seen[n] = true
  end
  for _, n in ipairs(b:ancestors()) do
    if seen[n] then
      return n
    end
  end
  return nil
end

---Record a dirty node (Servo: Element::restyle + note_dirty_element).
function Document:note_dirty(n, kind)
  self.version = self.version + 1
  n:bump()
  local prev = self.pending[n]
  -- the strongest kind wins: other > content > style
  local rank = { style = 1, content = 2, other = 3 }
  if not prev or rank[kind] > rank[prev] then
    self.pending[n] = kind
  end
  local p = n.parent
  while p and not p.dirty_descendants do
    p.dirty_descendants = true
    p = p.parent
  end
  self.dirty_root = self.dirty_root and common_ancestor(self.dirty_root, n) or n
end

---A document-wide reason to restyle (Servo's RestyleReason): "sheets", "viewport",
---"theme".
function Document:note_reason(reason)
  self.version = self.version + 1
  self.reasons[reason] = true
end

---Is there anything for the next update to do?
function Document:needs_update()
  return self.dirty_root ~= nil or next(self.reasons) ~= nil
end

---Hand the dirty state to an update and reset it.
---@return dbdash.dom.Node? dirty_root, table<dbdash.dom.Node, string> pending, table<string, boolean> reasons
function Document:take_dirty()
  local root, pending, reasons = self.dirty_root, self.pending, self.reasons
  self.dirty_root, self.pending, self.reasons = nil, {}, {}
  if root then
    -- the flags are set from each dirty node up to the document root
    self.root:walk(function(n)
      if not n.dirty_descendants and n ~= root then
        return n.parent == nil -- nothing flagged below a clean node, except at the root
      end
      n.dirty_descendants = false
    end)
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
