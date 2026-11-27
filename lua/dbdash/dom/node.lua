-- DOM nodes (after Servo's script/dom/node): a tree of elements (and text) with an id,
-- classes and attributes for selectors, and two slots that later stages fill in:
--   style_data   the computed style and the damage of the last restyle (css/style.lua)
--   layout_data  the node's box, kept between frames so it can be reused (layout/)
-- Changes go through node:dirty(), which records the node in its document's pending
-- restyles and moves the dirty root (the lowest common ancestor of dirty nodes).
local M = {}

---@class dbdash.dom.Node
---@field tag string element name ("#text" for text nodes)
---@field id string?
---@field classes string[] in the order written
---@field attrs table<string, string>
---@field text string? text of a text node (or an element's own text)
---@field parent dbdash.dom.Node?
---@field children dbdash.dom.Node[]
---@field document dbdash.dom.Document?
---@field dirty_descendants boolean HAS_DIRTY_DESCENDANTS
---@field style_data table? { computed: table, damage: integer }
---@field layout_data table? the box of the last layout
---@field handlers table<string, fun(ev: table)[]>?
---@field data table<string, any>? values no selector reads (a browser's dataset), e.g. the
---  status a view shows next to the element
---@field css_parts table<string, dbdash.dom.Node>? parts of a chart created when first
---  styled (css.scope)
---@field content table? what render/content built from the result (its kind and data)
---@field content_items table? the chart's items by kind (render/content)
---@field content_sigs table? signatures of the built items, to update only what changed
---@field items table? the argument line's items (dashboard/commit.lua)
---@field scope boolean? the root of an inline style sheet's scope (a panel)
---@field version integer bumped when the node or a descendant changes (Servo's
---  inclusive_descendants_version): caches of a subtree's layout and paint key on it
---@field layout_version integer bumped only by changes that can change sizes (DOM changes,
---  relayout or rebuild damage); caches of intrinsic sizes key on it
---@field tag_index integer? position among the parent's children of the same tag, kept on
---  insertion so :nth-child does not count siblings
---@field tag_counts table<string, integer>? children per tag
---@field last_by_tag table<string, dbdash.dom.Node>? the last child of each tag
local Node = {}
Node.__index = Node

---@param tag string
---@param opts { id: string?, classes: string[]?, attrs: table<string, string>?, text: string? }?
---@return dbdash.dom.Node
function M.new(tag, opts)
  opts = opts or {}
  return setmetatable({
    tag = tag,
    id = opts.id,
    classes = opts.classes or {},
    attrs = opts.attrs or {},
    text = opts.text,
    children = {},
    dirty_descendants = false,
    version = 0,
    layout_version = 0,
  }, Node)
end

---Kinds of change (Servo's NodeDamage):
---  style    the node's selectors may match differently (class, id, attribute)
---  content  its text or children changed (relayout of it and its ancestors)
---  other    anything else: rebuild it
M.STYLE, M.CONTENT, M.OTHER = "style", "content", "other"

---Record a child's position among its siblings of the same tag.
local function place(self, child)
  self.tag_counts = self.tag_counts or {}
  self.last_by_tag = self.last_by_tag or {}
  local prev = self.last_by_tag[child.tag]
  child.tag_index = (self.tag_counts[child.tag] or 0) + 1
  self.tag_counts[child.tag] = child.tag_index
  self.last_by_tag[child.tag] = child
  return prev
end

---Insert a child at the end. The new child needs a style (Servo: an inserted element is
---dirty), the previous last sibling of its tag too (it is no longer :last-child); the
---parent only changed content: it is laid out again, not restyled.
---@param child dbdash.dom.Node
---@return dbdash.dom.Node child
function Node:append(child)
  child.parent = self
  child.document = self.document
  self.children[#self.children + 1] = child
  local prev = place(self, child)
  if self.document then
    child:adopt(self.document)
    self:dirty(M.CONTENT)
    child:dirty(M.OTHER)
    if prev then
      prev:dirty(M.STYLE)
    end
  end
  return child
end

---Insert several children at the end at once (a script appending a fragment): the parent
---is marked for a restyle of its subtree once, instead of every child on its own.
---@param children dbdash.dom.Node[]
function Node:append_many(children)
  for _, child in ipairs(children) do
    child.parent = self
    self.children[#self.children + 1] = child
    place(self, child)
    if self.document then
      child:adopt(self.document)
    end
  end
  if self.document and #children > 0 then
    self:dirty(M.OTHER)
  end
end

---Set the document of a subtree.
function Node:adopt(doc)
  self.document = doc
  for _, c in ipairs(self.children) do
    c:adopt(doc)
  end
end

---Replace all children.
---@param children dbdash.dom.Node[]
function Node:set_children(children)
  for _, c in ipairs(self.children) do
    c.parent = nil
  end
  self.children = {}
  self.tag_counts, self.last_by_tag = {}, {}
  for _, c in ipairs(children) do
    c.parent = self
    self.children[#self.children + 1] = c
    place(self, c)
    if self.document then
      c:adopt(self.document)
      c:dirty(M.OTHER)
    end
  end
  self:dirty(M.CONTENT)
end

---Remove the children of `tag` past the first `keep` (they are the last of their tag:
---content builders append in order). The new last one is no longer followed: restyle it
---(:last-child).
function Node:truncate(tag, keep)
  local count = (self.tag_counts or {})[tag] or 0
  if count <= keep then
    return
  end
  local kept, last = {}, nil
  for _, c in ipairs(self.children) do
    if c.tag ~= tag or c.tag_index <= keep then
      kept[#kept + 1] = c
      if c.tag == tag then
        last = c
      end
    else
      c.parent = nil
    end
  end
  self.children = kept
  self.tag_counts[tag] = keep
  self.last_by_tag[tag] = last
  if self.document then
    self:dirty(M.CONTENT)
    if last then
      last:dirty(M.STYLE)
    end
  end
end

function Node:has_class(name)
  for _, c in ipairs(self.classes) do
    if c == name then
      return true
    end
  end
  return false
end

---Set the classes (a style change when they differ).
function Node:set_classes(list)
  if not vim.deep_equal(list, self.classes) then
    self.classes = list
    self:dirty(M.STYLE)
  end
end

function Node:set_attr(name, value)
  if self.attrs[name] ~= value then
    self.attrs[name] = value
    self:dirty(M.STYLE)
  end
end

---Set a value of the element's data: no restyle, the document only asks for a frame.
function Node:set_data(name, value)
  self.data = self.data or {}
  if self.data[name] ~= value then
    self.data[name] = value
    if self.document then
      self.document:note_data()
    end
  end
end

function Node:set_text(text)
  if self.text ~= text then
    self.text = text
    self:dirty(M.CONTENT)
  end
end

---Index among the parent's children with the same tag (1-based) and their count, for
---:nth-child / :first-child / :last-child (Servo counts all element siblings; here a
---node's siblings of other tags are separate parts, so counting by tag is what users mean).
---@return integer index, integer count
function Node:position()
  local p = self.parent
  if not p then
    return 1, 1
  end
  return self.tag_index or 1, (p.tag_counts or {})[self.tag] or 1
end

---Record a change: the document restyles from the dirty root on the next update.
---@param kind "style"|"content"|"other"?
function Node:dirty(kind)
  local doc = self.document
  if not doc then
    return
  end
  doc:note_dirty(self, kind or M.OTHER)
end

---Bump the version of the node and its ancestors; `paint_only` (repaint damage) leaves
---the layout version alone.
function Node:bump(paint_only)
  local n = self
  while n do
    n.version = n.version + 1
    if not paint_only then
      n.layout_version = n.layout_version + 1
    end
    n = n.parent
  end
end

---Walk the subtree depth first (pre-order).
---@param fn fun(n: dbdash.dom.Node): boolean? return false to skip the children
function Node:walk(fn)
  if fn(self) == false then
    return
  end
  for _, c in ipairs(self.children) do
    c:walk(fn)
  end
end

---Inclusive ancestors, nearest first.
function Node:ancestors()
  local out, n = {}, self
  while n do
    out[#out + 1] = n
    n = n.parent
  end
  return out
end

---First descendant (or self) matching `pred`.
function Node:find(pred)
  local found
  self:walk(function(n)
    if found then
      return false
    end
    if pred(n) then
      found = n
      return false
    end
  end)
  return found
end

---A short description for messages and the inspector: tag#id.class1.class2
function Node:describe()
  local s = self.tag
  if self.id then
    s = s .. "#" .. self.id
  end
  for _, c in ipairs(self.classes) do
    s = s .. "." .. c
  end
  return s
end

---Event listeners (dispatched by events/: capture and bubble along the ancestors).
---@param event string
---@param fn fun(ev: dbdash.events.Event)
---@param opts { capture: boolean? }?
function Node:on(event, fn, opts)
  self.handlers = self.handlers or {}
  self.handlers[event] = self.handlers[event] or {}
  table.insert(self.handlers[event], { fn = fn, capture = opts and opts.capture or false })
end

M.Node = Node

---The direct child of `parent` with `tag` (created at the end when missing).
function M.child(parent, tag)
  for _, c in ipairs(parent.children) do
    if c.tag == tag then
      return c
    end
  end
  return parent:append(M.new(tag))
end

return M
