-- Selector matching (after the `selectors` crate): right to left, the rightmost compound
-- against the node, the others against its ancestors (descendant combinator).
local M = {}

---Does a compound selector match the node?
---@param c dbdash.css.Compound
---@param n dbdash.dom.Node
function M.compound(c, n)
  if c.tag and c.tag ~= n.tag then
    return false
  end
  if c.id and c.id ~= n.id then
    return false
  end
  for _, cls in ipairs(c.classes) do
    if not n:has_class(cls) then
      return false
    end
  end
  for _, a in ipairs(c.attrs) do
    local v = n.attrs[a.name]
    if v == nil or (a.value ~= nil and tostring(v) ~= a.value) then
      return false
    end
  end
  for _, p in ipairs(c.pseudos) do
    local index, count = n:position()
    if p.name == "first-child" then
      if index ~= 1 then
        return false
      end
    elseif p.name == "last-child" then
      if index ~= count then
        return false
      end
    elseif p.name == "nth-child" then
      if p.arg == "odd" then
        if index % 2 ~= 1 then
          return false
        end
      elseif p.arg == "even" then
        if index % 2 ~= 0 then
          return false
        end
      elseif index ~= p.arg then
        return false
      end
    end
  end
  return true
end

---Does a selector match the node?
---@param sel dbdash.css.Selector
---@param n dbdash.dom.Node
function M.selector(sel, n)
  local parts = sel.parts
  if not M.compound(parts[#parts], n) then
    return false
  end
  local k, a = #parts - 1, n.parent
  while k >= 1 do
    while a and not M.compound(parts[k], a) do
      a = a.parent
    end
    if not a then
      return false
    end
    k, a = k - 1, a.parent
  end
  return true
end

return M
