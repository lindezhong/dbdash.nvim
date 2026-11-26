-- Style resolution (after Stylo's RecalcStyle traversal): from the document's dirty root
-- (or the whole document when a sheet, the viewport or the theme changed) compute every
-- node's style:
--   1. collect the rules whose selectors match, from every sheet that applies (an inline
--      sheet only inside its scope);
--   2. cascade them: origin (ua < user < author < inline < runtime), then specificity,
--      then order;
--   3. compute: declared value, else the parent's (inherited properties), else initial;
--   4. diff against the previous computed style: the damage is the strongest damage of
--      the properties that changed (css/properties.lua), or rebuild for a new node.
-- The result is stored in node.style_data = { computed, damage, rules }.
local match = require("dbdash.css.match")
local properties = require("dbdash.css.properties")

local M = {}

M.ORIGINS = { ua = 1, user = 2, author = 3, inline = 4, runtime = 5 }

local D = properties.DAMAGE

---Rules of a sheet by the tag of their rightmost compound ("*" for any).
local function index(sheet)
  if sheet.index then
    return sheet.index
  end
  local idx = {}
  for _, r in ipairs(sheet.rules) do
    local parts = r.selector.parts
    local tag = parts[#parts].tag or "*"
    idx[tag] = idx[tag] or {}
    table.insert(idx[tag], r)
  end
  sheet.index = idx
  return idx
end

local function in_scope(n, scope)
  while n do
    if n == scope then
      return true
    end
    n = n.parent
  end
  return false
end

---Matching rules for a node, cascaded (weakest first).
---@return { rule: dbdash.css.Rule, origin: string, sheet: integer }[]
function M.matching(doc, n)
  local out = {}
  for si, sheet in ipairs(doc.sheets) do
    if not sheet.scope or in_scope(n, sheet.scope) then
      local idx = index(sheet)
      for _, list in ipairs({ idx[n.tag] or {}, idx["*"] or {} }) do
        for _, r in ipairs(list) do
          if match.selector(r.selector, n) then
            out[#out + 1] = { rule = r, origin = sheet.origin, sheet = si }
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    local oa, ob = M.ORIGINS[a.origin], M.ORIGINS[b.origin]
    if oa ~= ob then
      return oa < ob
    end
    local sa, sb = a.rule.selector.specificity, b.rule.selector.specificity
    for k = 1, 3 do
      if sa[k] ~= sb[k] then
        return sa[k] < sb[k]
      end
    end
    if a.sheet ~= b.sheet then
      return a.sheet < b.sheet
    end
    return a.rule.order < b.rule.order
  end)
  return out
end

---The computed style of a node from its matching rules and its parent's computed style.
---@return table<string, any> computed, table matched
function M.compute(doc, n, parent)
  local matched = M.matching(doc, n)
  local declared = {}
  for _, m in ipairs(matched) do
    for name, v in pairs(m.rule.decls) do
      declared[name] = v
    end
  end
  local computed = {}
  for name, p in pairs(properties.list) do
    local v = declared[name]
    if v == nil then
      if p.inherited and parent then
        v = parent[name]
      else
        v = p.initial
      end
    end
    computed[name] = v
  end
  return computed, matched
end

---Damage between two computed styles.
function M.damage(old, new)
  if not old then
    return D.rebuild
  end
  local worst = D.none
  for name in pairs(properties.list) do
    if not vim.deep_equal(old[name], new[name]) then
      worst = math.max(worst, properties.damage(name))
    end
  end
  return worst
end

local function restyle_subtree(doc, n, parent_computed, stats)
  local old = n.style_data and n.style_data.computed
  local computed, matched = M.compute(doc, n, parent_computed)
  local damage = M.damage(old, computed)
  n.style_data = { computed = computed, damage = damage, rules = matched }
  stats.nodes = stats.nodes + 1
  stats.damage = math.max(stats.damage, damage)
  for _, c in ipairs(n.children) do
    restyle_subtree(doc, c, computed, stats)
  end
end

---Bring the document's styles up to date.
---@param doc dbdash.dom.Document
---@return { nodes: integer, damage: integer, root: dbdash.dom.Node? } what was restyled
function M.restyle(doc)
  local root, pending, reasons = doc:take_dirty()
  local stats = { nodes = 0, damage = D.none, pending = pending }
  if next(reasons) then
    root = doc.root
  end
  if not root then
    return stats
  end
  stats.root = root
  local parent = root.parent and root.parent.style_data and root.parent.style_data.computed or nil
  restyle_subtree(doc, root, parent, stats)
  return stats
end

---The computed style of a node, restyling the document first when it is dirty (like
---getComputedStyle forcing a style flush).
---@return table<string, any>
function M.get(n)
  local doc = n.document
  if doc and (doc:needs_update() or not n.style_data) then
    if not n.style_data and not doc:needs_update() then
      doc:note_dirty(n, "other")
    end
    M.restyle(doc)
  end
  return n.style_data and n.style_data.computed or {}
end

return M
