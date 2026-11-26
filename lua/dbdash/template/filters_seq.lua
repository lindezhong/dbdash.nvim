-- Jinja's filters on sequences and mappings: attr, batch, dictsort, groupby, items, list,
-- map, max, min, random, reject, rejectattr, reverse, select, selectattr, slice, sort,
-- sum, unique. Filters that return generators in Jinja return lists here.
local R = require("dbdash.template.runtime")
local map = require("dbdash.util.map")
local errors = require("dbdash.template.errors")

local M = {}

local raise = errors.raise
local NONE = R.NONE

local function bind(...)
  return require("dbdash.template.filters").bind(...)
end

---Items of an iterable (a string's characters, a mapping's keys).
local function items_of(v)
  return R.iter(v)
end

---Jinja's environment.getitem: obj[part], else the attribute.
local function getitem(obj, part)
  local v = R.getitem(obj, part)
  if R.is_undef(v) and type(part) == "string" then
    local a = R.getattr(obj, part)
    if not R.is_undef(a) then
      return a
    end
  end
  return v
end

---"a.b.0" -> { "a", "b", 0 } (digit parts are indexes).
local function attr_parts(attr)
  if attr == nil or attr == NONE then
    return {}
  elseif type(attr) == "string" then
    local out = {}
    for _, p in ipairs(vim.split(attr, ".", { plain = true })) do
      out[#out + 1] = p:match("^%d+$") and tonumber(p) or p
    end
    return out
  end
  return { attr }
end

---Lowercase strings (case-insensitive comparisons).
local function ignore_case(v)
  if type(v) == "string" then
    return vim.fn.tolower(v)
  elseif R.is_safe(v) then
    return vim.fn.tolower(v.s)
  end
  return v
end

---Jinja's make_attrgetter.
local function attrgetter(attr, postprocess, default)
  local parts = attr_parts(attr)
  return function(item)
    for _, part in ipairs(parts) do
      item = getitem(item, part)
      if default ~= nil and default ~= NONE and R.is_undef(item) then
        item = default
      end
    end
    if postprocess then
      item = postprocess(item)
    end
    return item
  end
end

---Jinja's make_multi_attrgetter: "age,name" gives a list of values.
local function multi_attrgetter(attr, postprocess)
  if attr == nil or attr == NONE then
    return postprocess
  end
  local getters = {}
  local names = type(attr) == "string" and vim.split(attr, ",", { plain = true }) or { attr }
  for i, a in ipairs(names) do
    getters[i] = attrgetter(a, postprocess)
  end
  return function(item)
    local out = {}
    for i, g in ipairs(getters) do
      out[i] = R.check(g(item))
    end
    return out
  end
end

local F = {}

F.attr = function(_, v, args, kw)
  local name = bind("attr", args, kw, { { "name" } })
  if map.is_map(v) then
    return R.undef(("'dict object' has no attribute '%s'"):format(R.str(name)))
  end
  return R.getattr(v, R.str(name))
end

F.batch = function(_, v, args, kw)
  local count, fill = bind("batch", args, kw, { { "linecount" }, { "fill_with", NONE } })
  local n = R.num(count)
  local out, tmp = {}, {}
  for _, item in ipairs(items_of(v)) do
    if #tmp == n then
      out[#out + 1] = tmp
      tmp = {}
    end
    tmp[#tmp + 1] = item
  end
  if #tmp > 0 then
    if fill ~= NONE then
      while #tmp < n do
        tmp[#tmp + 1] = fill
      end
    end
    out[#out + 1] = tmp
  end
  return out
end

F.slice = function(_, v, args, kw)
  local slices, fill = bind("slice", args, kw, { { "slices" }, { "fill_with", NONE } })
  local seq = items_of(v)
  local n = R.num(slices)
  local per, extra = math.floor(#seq / n), #seq % n
  local out, offset = {}, 0
  for k = 0, n - 1 do
    local start = offset + k * per
    if k < extra then
      offset = offset + 1
    end
    local stop = offset + (k + 1) * per
    local tmp = {}
    for i = start + 1, stop do
      tmp[#tmp + 1] = seq[i]
    end
    if fill ~= NONE and k >= extra then
      tmp[#tmp + 1] = fill
    end
    out[#out + 1] = tmp
  end
  return out
end

F.dictsort = function(_, v, args, kw)
  local case_sensitive, by, reverse = bind("dictsort", args, kw, { { "case_sensitive", false }, { "by", "key" }, { "reverse", false } })
  if not map.is_map(v) then
    raise("type", "dictsort: expected a mapping, got '%s'", R.typename(v))
  end
  local pos = by == "key" and 1 or by == "value" and 2 or nil
  if not pos then
    raise("value", 'You can only sort by either "key" or "value"')
  end
  local pairs_ = {}
  for k, x in map.pairs(v) do
    pairs_[#pairs_ + 1] = R.tuple({ k, x })
  end
  return R.sorted(pairs_, function(item)
    local x = item[pos]
    return R.truthy(case_sensitive) and x or ignore_case(x)
  end, R.truthy(reverse))
end

F.groupby = function(_, v, args, kw)
  local attribute, default, case_sensitive = bind("groupby", args, kw, { { "attribute" }, { "default", NONE }, { "case_sensitive", false } })
  local cs = R.truthy(case_sensitive)
  local key = attrgetter(attribute, not cs and ignore_case or nil, default)
  local real = attrgetter(attribute, nil, default)
  local sorted = R.sorted(items_of(v), function(item)
    return R.check(key(item))
  end)
  local out = {}
  local cur
  for _, item in ipairs(sorted) do
    local k = key(item)
    if cur and R.eq(cur.k, k) then
      table.insert(cur.list, item)
    else
      cur = { k = k, list = { item } }
      out[#out + 1] = cur
    end
  end
  for i, g in ipairs(out) do
    -- The key of a group is the value of its first item (case kept).
    out[i] = R.named_tuple("_GroupTuple", { "grouper", "list" }, { cs and g.k or real(g.list[1]), g.list })
  end
  return out
end

F.items = function(_, v, args, kw)
  bind("items", args, kw, {})
  if R.is_undef(v) then
    return {}
  end
  if not map.is_map(v) then
    raise("type", "Can only get item pairs from a mapping.")
  end
  local out = {}
  for k, x in map.pairs(v) do
    out[#out + 1] = R.tuple({ k, x })
  end
  return out
end

F.list = function(_, v, args, kw)
  bind("list", args, kw, {})
  return vim.list_extend({}, items_of(v))
end

---map(attribute='x', default=d) or map('filter', args...).
F.map = function(env, v, args, kw)
  if not R.truthy(v) then
    return {}
  end
  local fn
  if #args == 0 and kw.attribute ~= nil then
    for k in pairs(kw) do
      if k ~= "attribute" and k ~= "default" then
        raise("value", "Unexpected keyword argument '%s'", k)
      end
    end
    fn = attrgetter(kw.attribute, nil, kw.default)
  else
    local name = args[1]
    if name == nil then
      raise("value", "map requires a filter argument")
    end
    name = R.str(name)
    if not R.filters[name] then
      raise("value", "No filter named '%s'.", name)
    end
    local rest = { unpack(args, 2) }
    fn = function(item)
      return R.filter(env, name, item, rest, kw)
    end
  end
  local out = {}
  for i, item in ipairs(items_of(v)) do
    out[i] = fn(item)
  end
  return out
end

---select / reject / selectattr / rejectattr.
local function select_or_reject(env, v, args, kw, keep, lookup_attr)
  if not R.truthy(v) then
    return {}
  end
  local trans, off = function(x)
    return x
  end, 0
  if lookup_attr then
    if args[1] == nil then
      raise("value", "Missing parameter for attribute name")
    end
    trans, off = attrgetter(args[1]), 1
  end
  local test
  local name = args[off + 1]
  if name == nil then
    test = function(x)
      return R.truthy(x)
    end
  else
    name = R.str(name)
    if not R.tests[name] then
      raise("value", "No test named '%s'.", name)
    end
    local rest = { unpack(args, off + 2) }
    test = function(x)
      return R.truthy(R.test(env, name, x, rest))
    end
  end
  local out = {}
  for _, item in ipairs(items_of(v)) do
    if test(trans(item)) == keep then
      out[#out + 1] = item
    end
  end
  return out
end

F.select = function(env, v, args, kw)
  return select_or_reject(env, v, args, kw, true, false)
end
F.reject = function(env, v, args, kw)
  return select_or_reject(env, v, args, kw, false, false)
end
F.selectattr = function(env, v, args, kw)
  return select_or_reject(env, v, args, kw, true, true)
end
F.rejectattr = function(env, v, args, kw)
  return select_or_reject(env, v, args, kw, false, true)
end

local function min_or_max(name, v, args, kw, want_max)
  local case_sensitive, attribute = bind(name, args, kw, { { "case_sensitive", false }, { "attribute", NONE } })
  local seq = items_of(v)
  if #seq == 0 then
    return R.undef("No aggregated item, sequence was empty.")
  end
  local key = attrgetter(attribute, not R.truthy(case_sensitive) and ignore_case or nil)
  local best, best_key = seq[1], R.check(key(seq[1]))
  for i = 2, #seq do
    local k = R.check(key(seq[i]))
    if (want_max and R.cmp("<", best_key, k)) or (not want_max and R.cmp("<", k, best_key)) then
      best, best_key = seq[i], k
    end
  end
  return best
end

F.max = function(_, v, args, kw)
  return min_or_max("max", v, args, kw, true)
end
F.min = function(_, v, args, kw)
  return min_or_max("min", v, args, kw, false)
end

F.random = function(_, v, args, kw)
  bind("random", args, kw, {})
  local seq = items_of(v)
  if #seq == 0 then
    return R.undef("No random item, sequence was empty.")
  end
  return seq[math.random(#seq)]
end

F.reverse = function(_, v, args, kw)
  bind("reverse", args, kw, {})
  if type(v) == "string" or R.is_safe(v) then
    return R.slice(v, nil, nil, -1)
  end
  local seq = items_of(v)
  local out = {}
  for i = #seq, 1, -1 do
    out[#out + 1] = seq[i]
  end
  return out
end

F.sort = function(_, v, args, kw)
  local reverse, case_sensitive, attribute = bind("sort", args, kw, { { "reverse", false }, { "case_sensitive", false }, { "attribute", NONE } })
  local key = multi_attrgetter(attribute, not R.truthy(case_sensitive) and ignore_case or nil)
  return R.sorted(items_of(v), key, R.truthy(reverse))
end

F.sum = function(_, v, args, kw)
  local attribute, start = bind("sum", args, kw, { { "attribute", NONE }, { "start", 0 } })
  local get = attribute ~= NONE and attrgetter(attribute) or nil
  local total = start
  for _, item in ipairs(items_of(v)) do
    total = R.add(total, get and get(item) or item)
  end
  return total
end

F.unique = function(_, v, args, kw)
  local case_sensitive, attribute = bind("unique", args, kw, { { "case_sensitive", false }, { "attribute", NONE } })
  local key = attrgetter(attribute, not R.truthy(case_sensitive) and ignore_case or nil)
  local out, seen = {}, {}
  for _, item in ipairs(items_of(v)) do
    local k = R.check(key(item))
    local found = false
    for _, s in ipairs(seen) do
      if R.eq(s, k) then
        found = true
        break
      end
    end
    if not found then
      seen[#seen + 1] = k
      out[#out + 1] = item
    end
  end
  return out
end

function M.install()
  for k, fn in pairs(F) do
    R.filters[k] = fn
  end
end

return M
