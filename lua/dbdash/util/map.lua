-- Ordered mappings: plain Lua tables tagged with vim.empty_dict()'s metatable, so they are
-- distinguishable from lists even when empty (and vim.json encodes them as objects).
-- Insertion order is tracked in a weak side table.
local M = {}

M.mt = getmetatable(vim.empty_dict())

local order = setmetatable({}, { __mode = "k" })

---Create an empty ordered mapping.
---@return table
function M.new()
  local t = setmetatable({}, M.mt)
  order[t] = {}
  return t
end

---True when `t` is a mapping (as opposed to a list or scalar).
---@param t any
---@return boolean
function M.is_map(t)
  return type(t) == "table" and getmetatable(t) == M.mt
end

---True when `t` is a list: a table that is not a mapping.
---@param t any
---@return boolean
function M.is_list(t)
  return type(t) == "table" and getmetatable(t) ~= M.mt and t ~= vim.NIL
end

---Set `t[k] = v`, remembering first-insertion order.
---@param t table
---@param k any
---@param v any
function M.set(t, k, v)
  local ks = order[t]
  if not ks then
    ks = {}
    order[t] = ks
  end
  if rawget(t, k) == nil then
    ks[#ks + 1] = k
  end
  rawset(t, k, v)
end

---Remove key `k` (set again, it goes last, like a Python dict).
---@param t table
---@param k any
function M.delete(t, k)
  rawset(t, k, nil)
  local ks = order[t]
  for i = #(ks or {}), 1, -1 do
    if ks[i] == k then
      table.remove(ks, i)
    end
  end
end

---Keys of `t` in insertion order; keys set without `M.set` follow, sorted.
---@param t table
---@return any[]
function M.keys(t)
  local out, seen = {}, {}
  for _, k in ipairs(order[t] or {}) do
    if rawget(t, k) ~= nil and not seen[k] then
      out[#out + 1] = k
      seen[k] = true
    end
  end
  local extra = {}
  for k in pairs(t) do
    if not seen[k] then
      extra[#extra + 1] = k
    end
  end
  table.sort(extra, function(a, b)
    return tostring(a) < tostring(b)
  end)
  vim.list_extend(out, extra)
  return out
end

---Iterate `(k, v)` in insertion order.
---@param t table
function M.pairs(t)
  local ks, i = M.keys(t), 0
  return function()
    i = i + 1
    local k = ks[i]
    if k ~= nil then
      return k, t[k]
    end
  end
end

---Build an ordered mapping from a list of `{k, v}` pairs.
---@param kvs {[1]: any, [2]: any}[]
---@return table
function M.from_pairs(kvs)
  local t = M.new()
  for _, kv in ipairs(kvs) do
    M.set(t, kv[1], kv[2])
  end
  return t
end

return M
