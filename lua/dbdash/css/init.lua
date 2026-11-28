-- CSS entry points: the UA sheet as parsed rules, documents with it installed, and a
-- query API for code that styles the parts of an element (getComputedStyle on a part):
--   local css = require("dbdash.css").scope(chart_node)
--   css:hl("axis")                       -> highlight group of chart > axis
--   css:hl("series", { classes = { "EU" }, attrs = { name = "EU" }, index = 2 })
--   css:get("plot")["border"]            -> a computed value
-- Parts are child nodes of the scope's node, created on first use and kept, so their
-- computed styles are cached like any other node's.
local document = require("dbdash.dom.document")
local dom = require("dbdash.dom.node")
local parser = require("dbdash.css.parser")
local style = require("dbdash.css.style")
local hl = require("dbdash.css.hl")

local M = {}

local ua_rules
local ua_added = {} -- rules added to the UA sheet (M.add_ua), by who added them

---Add (or replace) rules of the UA sheet: the default style of a chart type's parts
---(render/registry adds each type's `style` under its name; css knows no chart type).
---@param key string who adds them (a chart type)
---@param rules table<string, table>? selector -> properties (nil: none any more)
function M.add_ua(key, rules)
  ua_added[key] = rules
  ua_rules = nil
end

---The UA sheet (css/ua.lua and what was added), parsed once.
function M.ua()
  if not ua_rules then
    local ua = vim.deepcopy(require("dbdash.css.ua"))
    local adders = vim.tbl_keys(ua_added)
    table.sort(adders)
    for _, key in ipairs(adders) do
      for sel, props in pairs(ua_added[key]) do
        ua[sel] = props
      end
    end
    local keys = vim.tbl_keys(ua)
    table.sort(keys)
    ua_rules = assert(parser.sheet(ua, keys))
  end
  return ua_rules
end

---A document with the UA sheet (and the user sheet of setup({ style })).
---@param root_tag string?
---@return dbdash.dom.Document
function M.document(root_tag)
  local doc = document.new(root_tag)
  doc:set_sheet("ua", M.ua())
  local user = M.user_rules()
  if user then
    doc:set_sheet("user", user)
  end
  return doc
end

---The user sheet: setup({ style = ... }), set by dbdash.options.
---@type table?
M.user_style = nil

local user_rules, user_src

---The user sheet, parsed when it changes.
function M.user_rules()
  local src = M.user_style
  if src == nil or src == vim.NIL or next(src) == nil then
    return nil
  end
  if src ~= user_src then
    user_src = src
    user_rules = parser.sheet(src)
  end
  return user_rules
end

---Highlight group of a node's own computed style (nil when it sets none).
---@param n dbdash.dom.Node
---@return string?
function M.hl_of(n)
  return hl.group(style.get(n))
end

---@class dbdash.css.Scope
---@field node dbdash.dom.Node
---@field parts table<string, dbdash.dom.Node>
local Scope = {}
Scope.__index = Scope

---@param node dbdash.dom.Node? the element whose parts are styled (default: a chart in
---a document of its own, for rendering outside a dashboard)
---@param chart_type string?
---@return dbdash.css.Scope
---@param sheet table? for a chart of its own: a style sheet (selector -> properties)
function M.scope(node, chart_type, sheet)
  if not node then
    local doc = M.document()
    if sheet then
      local keys = require("dbdash.util.map").keys(sheet)
      if #keys == 0 then
        keys = vim.tbl_keys(sheet)
        table.sort(keys)
      end
      local rules, err = parser.sheet(sheet, keys)
      if not rules then
        ---@cast err -nil
        require("dbdash.util.error").raise("render", ("style %s: %s"):format(err.key, err.message))
      end
      ---@cast rules -nil
      doc:set_sheet("author", rules)
    end
    node = doc.root:append(dom.new("chart", {
      classes = { chart_type },
      attrs = {
        type = chart_type --[[@as string]],
      },
    }))
  end
  -- the parts live on the node, so every render of the same chart reuses them
  node.css_parts = node.css_parts or {}
  return setmetatable({ node = node, parts = node.css_parts }, Scope)
end

---@class dbdash.css.PartSpec
---@field classes string[]?
---@field attrs table<string, string>?
---@field index integer? position among parts of the same tag (for :nth-child)
---@field within string? the tag of an intermediate part (e.g. "legend" for legend-item)

---The part node for (tag, spec), created on first use.
---@param tag string
---@param spec dbdash.css.PartSpec?
function Scope:part(tag, spec)
  spec = spec or {}
  -- a part at a position is one node whose classes and attributes follow the data (a
  -- row that turns "danger" stays the 3rd row); other parts are keyed by what they match
  local key = spec.index and (tag .. "#" .. spec.index)
    or (tag .. "|" .. table.concat(spec.classes or {}, ".") .. "|" .. vim.inspect(spec.attrs or {}))
  local n = self.parts[key]
  if n and spec.index then
    n:set_classes(spec.classes or {})
    for k, v in pairs(spec.attrs or {}) do
      n:set_attr(k, v)
    end
  end
  if not n then
    n = dom.new(tag, { classes = spec.classes, attrs = spec.attrs })
    -- position among siblings: pad with placeholders so :nth-child sees the index
    if spec.index then
      local count = (self.node.tag_counts or {})[tag] or 0
      for _ = count + 1, spec.index - 1 do
        self.node:append(dom.new(tag, { attrs = { placeholder = "1" } }))
      end
    end
    self.node:append(n)
    self.parts[key] = n
  end
  return n
end

---Computed style of a part (or of the scope's node itself when tag is nil).
---@return table<string, any>
function Scope:get(tag, spec)
  local n = tag and self:part(tag, spec) or self.node
  return style.get(n)
end

---Highlight group of a part's color and glyphs (nil when it sets none).
---@return string?
function Scope:hl(tag, spec)
  return hl.group(self:get(tag, spec))
end

---Highlight group of a part's border color.
function Scope:border_hl(tag, spec)
  local c = self:get(tag, spec)
  return hl.group({ color = c["border-color"], ["text-decoration"] = "none" })
end

M.Scope = Scope

---The cut marker of a computed text-overflow: "ellipsis" -> "…", "clip" -> "", else
---the string itself (CSS text-overflow: "<string>").
function M.ellipsis(c)
  local v = c["text-overflow"]
  if v == nil or v == "ellipsis" then
    return "…"
  elseif v == "clip" then
    return ""
  end
  return v
end

---A countdown element (under the header or a panel): shown?, its format (content).
---@return boolean shown, string format
function M.countdown(parent)
  local c = require("dbdash.css.style").get(require("dbdash.dom.node").child(parent, "countdown"))
  return c.display ~= "none", c.content or "Next update: {time}s"
end

return M
