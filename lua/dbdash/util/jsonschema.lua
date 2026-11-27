-- JSON Schema 2020-12 validation (the schema dialect of OpenAPI 3.1), on decoded JSON
-- values: mappings (dbdash.util.map), lists, vim.NIL (null), numbers, strings, booleans.
--
-- Keywords: type enum const; multipleOf minimum maximum exclusiveMinimum exclusiveMaximum;
-- minLength maxLength pattern (ECMA-262, util/ecma_regex); items prefixItems contains
-- minContains maxContains minItems maxItems uniqueItems; properties patternProperties
-- additionalProperties required dependentRequired dependentSchemas propertyNames
-- minProperties maxProperties; allOf anyOf oneOf not if/then/else; $ref (to "#..." in the
-- same document, or through opts.resolve) and $defs; format (checked only with
-- opts.formats: date-time date time email uri uuid ipv4 ipv6 hostname); OpenAPI 3.0's
-- `nullable` (opts.nullable). Annotations (title, description, default, examples,
-- readOnly, writeOnly, deprecated, discriminator, $comment) do not change validation.
local map = require("dbdash.util.map")
local regex = require("dbdash.util.ecma_regex")

local M = {}

local NULL = vim.NIL

local function is_map(v)
  return map.is_map(v)
end

local function is_list(v)
  return type(v) == "table" and v ~= NULL and not map.is_map(v)
end

---JSON type name of a value ("integer" for numbers without a fraction).
local function json_type(v)
  local t = type(v)
  if v == NULL or v == nil then
    return "null"
  elseif t == "boolean" then
    return "boolean"
  elseif t == "number" then
    return (v == math.floor(v) and v == v and v ~= math.huge and v ~= -math.huge) and "integer"
      or "number"
  elseif t == "string" then
    return "string"
  elseif is_map(v) then
    return "object"
  elseif is_list(v) then
    return "array"
  end
  return t
end
M.json_type = json_type

---JSON equality: numbers by value (1 == 1.0), objects by keys and values, arrays in order.
local function equal(a, b)
  local ta, tb = json_type(a), json_type(b)
  if (ta == "integer" or ta == "number") and (tb == "integer" or tb == "number") then
    return a == b
  end
  if ta ~= tb then
    return false
  end
  if ta == "object" then
    for k, v in pairs(a) do
      if b[k] == nil or not equal(v, b[k]) then
        return false
      end
    end
    for k in pairs(b) do
      if a[k] == nil then
        return false
      end
    end
    return true
  elseif ta == "array" then
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if not equal(a[i], b[i]) then
        return false
      end
    end
    return true
  end
  return a == b
end
M.equal = equal

local function ulen(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

local function show(v)
  if type(v) == "string" then
    return ("%q"):format(v)
  end
  local ok, s = pcall(vim.json.encode, v)
  return ok and s or tostring(v)
end

-- Formats -----------------------------------------------------------------------------------

local function valid_date(y, mo, d)
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if not (y and mo and d) or mo < 1 or mo > 12 or d < 1 then
    return false
  end
  local days = {
    31,
    (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  }
  return d <= days[mo]
end

local function valid_time(s)
  local h, mi, sec, rest = s:match("^(%d%d):(%d%d):(%d%d)(.*)$")
  if not h then
    return false
  end
  rest = rest:gsub("^%.%d+", "")
  local zone = rest:upper()
  if zone ~= "Z" and not zone:match("^[+-]%d%d:%d%d$") then
    return false
  end
  h, mi, sec = tonumber(h), tonumber(mi), tonumber(sec)
  if zone ~= "Z" then
    local zh, zm = zone:match("^[+-](%d%d):(%d%d)$")
    if tonumber(zh) > 23 or tonumber(zm) > 59 then
      return false
    end
  end
  return h <= 23 and mi <= 59 and sec <= 60
end

local function valid_ipv4(s)
  local parts = vim.split(s, ".", { plain = true })
  if #parts ~= 4 then
    return false
  end
  for _, p in ipairs(parts) do
    if not p:match("^%d+$") or #p > 3 or (#p > 1 and p:sub(1, 1) == "0") or tonumber(p) > 255 then
      return false
    end
  end
  return true
end

local function valid_ipv6(s)
  if s:find("[^%x:%.]") then
    return false
  end
  local v4 = s:match(":([%d%.]+)$")
  local groups_needed = 8
  if v4 and v4:find(".", 1, true) then
    if not valid_ipv4(v4) then
      return false
    end
    s = s:sub(1, #s - #v4) .. "0:0"
  end
  local dbl = select(2, s:gsub("::", "::"))
  if dbl > 1 then
    return false
  end
  local function groups(part)
    if part == "" then
      return {}
    end
    return vim.split(part, ":", { plain = true })
  end
  local head, tail = s:match("^(.-)::(.*)$")
  local list
  if head then
    local a, b = groups(head), groups(tail)
    if #a + #b > groups_needed - 1 then
      return false
    end
    list = vim.list_extend(a, b)
  else
    list = groups(s)
    if #list ~= groups_needed then
      return false
    end
  end
  for _, g in ipairs(list) do
    if not g:match("^%x%x?%x?%x?$") then
      return false
    end
  end
  return true
end

local function valid_hostname(s)
  if #s == 0 or #s > 253 then
    return false
  end
  for label in (s:gsub("%.$", "") .. "."):gmatch("([^.]*)%.") do
    if
      #label == 0
      or #label > 63
      or not label:match("^[%w-]+$")
      or label:sub(1, 1) == "-"
      or label:sub(-1) == "-"
    then
      return false
    end
  end
  return true
end

M.FORMATS = {
  ["date-time"] = function(s)
    local y, mo, d, t = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](.+)$")
    return y ~= nil and valid_date(y, mo, d) and valid_time(t)
  end,
  date = function(s)
    local y, mo, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    return y ~= nil and valid_date(y, mo, d)
  end,
  time = valid_time,
  email = function(s)
    local loc, dom = s:match("^([^@%s]+)@([^@%s]+)$")
    return loc ~= nil
      and not loc:match("^%.")
      and not loc:match("%.$")
      and not loc:find("..", 1, true)
      and valid_hostname(dom)
  end,
  uri = function(s)
    return s:match("^%a[%w+.-]*:[^%s]*$") ~= nil and not s:find('[<>"{}|\\^`]')
  end,
  uuid = function(s)
    return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
      ~= nil
  end,
  ipv4 = valid_ipv4,
  ipv6 = valid_ipv6,
  hostname = valid_hostname,
}

-- JSON Pointer ($ref "#/a/b") --------------------------------------------------------------

---The value at JSON Pointer `ptr` ("/a/0/b") in `doc`, or nil.
function M.pointer(doc, ptr)
  if ptr == "" then
    return doc
  end
  local v = doc
  for part in (ptr:sub(2) .. "/"):gmatch("([^/]*)/") do
    part = part
      :gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
      end)
      :gsub("~1", "/")
      :gsub("~0", "~")
    if is_map(v) then
      v = v[part]
    elseif is_list(v) and part:match("^%d+$") then
      v = v[tonumber(part) + 1]
    else
      return nil
    end
    if v == nil then
      return nil
    end
  end
  return v
end

-- Validation ----------------------------------------------------------------------------------

local V = {}
V.__index = V

---An error at `path` (JSON Pointer of the instance).
local function err(path, msg, ...)
  return { path = path == "" and "/" or path, message = msg:format(...) }
end

local function child(path, key)
  return path .. "/" .. tostring(key):gsub("~", "~0"):gsub("/", "~1")
end

function V:resolve(ref, base)
  if ref:sub(1, 1) == "#" then
    local target = M.pointer(base, ref:sub(2))
    if target == nil then
      error({ schema_error = true, message = ("$ref %s not found"):format(ref) }, 0)
    end
    return target, base
  end
  if self.opts.resolve then
    local target, doc = self.opts.resolve(ref, base)
    if target ~= nil then
      return target, doc or target
    end
  end
  error({ schema_error = true, message = ("$ref %s cannot be resolved"):format(ref) }, 0)
end

---Validate `v` against `schema`; returns the first error or nil.
function V:check(schema, v, path, base)
  if schema == true or schema == nil then
    return nil
  elseif schema == false then
    return err(path, "no value is allowed here")
  end
  self.depth = self.depth + 1
  if self.depth > 200 then
    error({ schema_error = true, message = "schema references nest too deeply (a loop?)" }, 0)
  end
  local e = self:check_keywords(schema, v, path, base)
  self.depth = self.depth - 1
  return e
end

function V:valid(schema, v, path, base)
  return self:check(schema, v, path, base) == nil
end

function V:check_keywords(s, v, path, base)
  local t = json_type(v)
  local e

  if s["$ref"] ~= nil then
    local target, doc = self:resolve(s["$ref"], base)
    e = self:check(target, v, path, doc)
    if e then
      return e
    end
  end

  -- Type and values.
  local nullable = self.opts.nullable and s.nullable == true and t == "null"
  if s.type ~= nil and not nullable then
    local types = type(s.type) == "string" and { s.type } or s.type
    local ok = false
    for _, want in ipairs(types) do
      ok = ok or want == t or (want == "number" and t == "integer")
    end
    if not ok then
      return err(path, "must be %s, got %s", table.concat(types, " or "), t)
    end
  end
  if s.enum ~= nil and not nullable then
    local ok = false
    for _, x in ipairs(s.enum) do
      ok = ok or equal(x, v)
    end
    if not ok then
      return err(path, "must be one of %s", show(s.enum))
    end
  end
  if s.const ~= nil and not equal(s.const, v) then
    return err(path, "must be %s", show(s.const))
  end

  -- Numbers.
  if t == "integer" or t == "number" then
    if s.multipleOf ~= nil then
      local q = v / s.multipleOf
      if
        q ~= q
        or q == math.huge
        or q == -math.huge
        or math.abs(q - math.floor(q + 0.5)) > 1e-9 * math.max(1, math.abs(q))
      then
        return err(path, "must be a multiple of %s", show(s.multipleOf))
      end
    end
    if s.minimum ~= nil and v < s.minimum then
      return err(path, "must be >= %s", show(s.minimum))
    end
    if s.maximum ~= nil and v > s.maximum then
      return err(path, "must be <= %s", show(s.maximum))
    end
    if type(s.exclusiveMinimum) == "number" and v <= s.exclusiveMinimum then
      return err(path, "must be > %s", show(s.exclusiveMinimum))
    end
    if type(s.exclusiveMaximum) == "number" and v >= s.exclusiveMaximum then
      return err(path, "must be < %s", show(s.exclusiveMaximum))
    end
  end

  -- Strings.
  if t == "string" then
    if s.minLength ~= nil and ulen(v) < s.minLength then
      return err(path, "must be at least %d characters long", s.minLength)
    end
    if s.maxLength ~= nil and ulen(v) > s.maxLength then
      return err(path, "must be at most %d characters long", s.maxLength)
    end
    if s.pattern ~= nil then
      local r, rerr = regex.get(s.pattern)
      if not r then
        error({
          schema_error = true,
          message = ("invalid pattern %s: %s"):format(show(s.pattern), rerr),
        }, 0)
      end
      if not r:test(v) then
        return err(path, "must match the pattern %s", show(s.pattern))
      end
    end
    if s.format ~= nil and self.opts.formats then
      local f = M.FORMATS[s.format]
      if f and not f(v) then
        return err(path, "must be a valid %s", s.format)
      end
    end
  end

  -- Arrays.
  if t == "array" then
    local n = #v
    if s.minItems ~= nil and n < s.minItems then
      return err(path, "must have at least %d items", s.minItems)
    end
    if s.maxItems ~= nil and n > s.maxItems then
      return err(path, "must have at most %d items", s.maxItems)
    end
    if s.uniqueItems == true then
      for i = 1, n do
        for j = i + 1, n do
          if equal(v[i], v[j]) then
            return err(path, "items %d and %d are equal", i - 1, j - 1)
          end
        end
      end
    end
    local prefix = s.prefixItems or {}
    for i = 1, math.min(#prefix, n) do
      e = self:check(prefix[i], v[i], child(path, i - 1), base)
      if e then
        return e
      end
    end
    if s.items ~= nil then
      for i = #prefix + 1, n do
        e = self:check(s.items, v[i], child(path, i - 1), base)
        if e then
          return e
        end
      end
    end
    if s.contains ~= nil then
      local count = 0
      for i = 1, n do
        if self:valid(s.contains, v[i], child(path, i - 1), base) then
          count = count + 1
        end
      end
      local min = s.minContains or 1
      if count < min then
        return err(path, "must contain at least %d matching item(s)", min)
      end
      if s.maxContains ~= nil and count > s.maxContains then
        return err(path, "must contain at most %d matching item(s)", s.maxContains)
      end
    end
  end

  -- Objects.
  if t == "object" then
    local keys = map.keys(v)
    if s.minProperties ~= nil and #keys < s.minProperties then
      return err(path, "must have at least %d properties", s.minProperties)
    end
    if s.maxProperties ~= nil and #keys > s.maxProperties then
      return err(path, "must have at most %d properties", s.maxProperties)
    end
    for _, name in ipairs(s.required or {}) do
      if v[name] == nil then
        return err(path, "missing required property %s", show(name))
      end
    end
    for name, needs in pairs(s.dependentRequired or {}) do
      if v[name] ~= nil then
        for _, other in ipairs(needs) do
          if v[other] == nil then
            return err(path, "property %s requires %s", show(name), show(other))
          end
        end
      end
    end
    for name, sub in pairs(s.dependentSchemas or {}) do
      if v[name] ~= nil then
        e = self:check(sub, v, path, base)
        if e then
          return e
        end
      end
    end
    local props, patterns = s.properties or {}, s.patternProperties or {}
    for _, k in ipairs(keys) do
      local x = v[k]
      local p = child(path, k)
      local covered = false
      if props[k] ~= nil then
        covered = true
        e = self:check(props[k], x, p, base)
        if e then
          return e
        end
      end
      for pat, sub in pairs(patterns) do
        local r = regex.get(pat)
        if not r then
          error({ schema_error = true, message = ("invalid pattern %s"):format(show(pat)) }, 0)
        end
        if type(k) == "string" and r:test(k) then
          covered = true
          e = self:check(sub, x, p, base)
          if e then
            return e
          end
        end
      end
      if not covered and s.additionalProperties ~= nil then
        if s.additionalProperties == false then
          return err(p, "property %s is not allowed", show(k))
        end
        e = self:check(s.additionalProperties, x, p, base)
        if e then
          return e
        end
      end
      if s.propertyNames ~= nil then
        e = self:check(s.propertyNames, k, p, base)
        if e then
          return err(p, "invalid property name %s: %s", show(k), e.message)
        end
      end
    end
  end

  -- Combinations.
  for _, sub in ipairs(s.allOf or {}) do
    e = self:check(sub, v, path, base)
    if e then
      return e
    end
  end
  if s.anyOf ~= nil then
    local first
    for _, sub in ipairs(s.anyOf) do
      local se = self:check(sub, v, path, base)
      if not se then
        first = nil
        break
      end
      first = first or se
    end
    if first then
      return err(path, "must match one of the schemas in anyOf (%s)", first.message)
    end
  end
  if s.oneOf ~= nil then
    local count, first = 0, nil
    for _, sub in ipairs(s.oneOf) do
      local se = self:check(sub, v, path, base)
      if se then
        first = first or se
      else
        count = count + 1
      end
    end
    if count == 0 then
      return err(
        path,
        "must match one of the schemas in oneOf (%s)",
        first and first.message or "none"
      )
    elseif count > 1 then
      return err(path, "must match exactly one schema in oneOf, matches %d", count)
    end
  end
  if s["not"] ~= nil and self:valid(s["not"], v, path, base) then
    return err(path, "must not match the schema in not")
  end
  if s["if"] ~= nil then
    if self:valid(s["if"], v, path, base) then
      if s["then"] ~= nil then
        e = self:check(s["then"], v, path, base)
      end
    elseif s["else"] ~= nil then
      e = self:check(s["else"], v, path, base)
    end
    if e then
      return e
    end
  end
  return nil
end

---@class dbdash.jsonschema.Opts
---@field formats boolean?
---@field nullable boolean?
---@field resolve fun(ref: string, base: any): any, any a $ref to its schema and base

---Validate `value` against `schema` (in `doc`, the document its $refs point into; default:
---the schema itself).
---@param opts dbdash.jsonschema.Opts?
---@return { path: string, message: string }? error the first problem, nil when valid
function M.validate(schema, value, opts, doc)
  local v = setmetatable({ opts = opts or {}, depth = 0 }, V)
  local ok, res = pcall(V.check, v, schema, value, "", doc or schema)
  if not ok then
    if type(res) == "table" and res.schema_error then
      return { path = "/", message = "invalid schema: " .. res.message, schema_error = true }
    end
    error(res, 0)
  end
  return res
end

return M
