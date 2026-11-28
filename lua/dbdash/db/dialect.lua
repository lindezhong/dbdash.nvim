-- Literal and identifier quoting (:help dbdash-template-dialects): how a dialect is made,
-- and standard SQL. Each driver has its own (its `dialect`, db/drivers/<name>/init.lua).
-- Template SQL filters and autoescape only use these functions.
local map = require("dbdash.util.map")

local M = {}

---@class dbdash.template.Dialect
---@field name string
---@field quote_string fun(s: string): string
---@field quote_ident fun(s: string): string
---@field literal fun(v: any): string
---@field boolean_literal fun(b: boolean): string
---@field null string

local function numstr(v)
  return require("dbdash.util.number").numstr(v)
end

---@return any (it raises: `x or fail(...)` keeps x's type)
local function fail(msg, ...)
  require("dbdash.util.error").raise("template", msg:format(...), { kind = "value" })
end

---Validate an identifier: letters, digits, underscore, optionally dotted (schema.table).
function M.ident_parts(s)
  if type(s) ~= "string" then
    fail("SQL identifier must be a string")
  end
  local parts = vim.split(s, ".", { plain = true })
  for _, p in ipairs(parts) do
    if not p:match("^[%a_][%w_]*$") then
      fail("Invalid SQL identifier: %s", s)
    end
  end
  return parts
end

function M.quoter(open, close)
  return function(s)
    local parts = M.ident_parts(s)
    for i, p in ipairs(parts) do
      parts[i] = open .. p .. close
    end
    return table.concat(parts, ".")
  end
end

function M.standard_string(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

---Build a dialect from its string/identifier/boolean rules (a driver's `dialect`:
---db/drivers/<name>/init.lua); without rules, standard SQL.
function M.make(name, spec)
  local d = { name = name, null = spec.null or "NULL" }
  d.quote_string = spec.quote_string or M.standard_string
  d.quote_ident = spec.quote_ident or M.quoter('"', '"')
  d.boolean_literal = spec.boolean_literal or function(b)
    return b and "TRUE" or "FALSE"
  end
  function d.literal(v)
    if v == nil or v == vim.NIL then
      return d.null
    elseif type(v) == "boolean" then
      return d.boolean_literal(v)
    elseif type(v) == "number" then
      if v ~= v or v == math.huge or v == -math.huge then
        fail("cannot use %s as a SQL literal", numstr(v))
      end
      return numstr(v)
    elseif type(v) == "string" then
      return d.quote_string(v)
    elseif require("dbdash.util.markup").is_safe(v) then
      return v.s
    elseif require("dbdash.util.number").is_float_box(v) then
      return require("dbdash.util.number").floatstr(v) -- 2.0 (a template float)
    elseif map.is_map(v) then
      if spec.map_literal then
        return spec.map_literal(v)
      end
      fail("a mapping cannot be used as a SQL literal")
    elseif type(v) == "table" then
      if spec.list_literal then
        return spec.list_literal(v, d)
      end
      if #v == 0 then
        return "(" .. d.null .. ")"
      end
      local parts = {}
      for i, x in ipairs(v) do
        parts[i] = d.literal(x)
      end
      return "(" .. table.concat(parts, ", ") .. ")"
    end
    fail("unsupported value for a SQL literal: %s", type(v))
  end
  return d
end

---A template value as JSON (a dialect's literal for JSON-based query languages): the
---template engine's encoder, which it sets here (template/filters.lua; it knows its values).
---@type fun(v: any): string
M.json = function()
  error("no JSON encoder: the template engine sets db.dialect.json", 0)
end

-- Standard SQL: single-quoted strings, double-quoted identifiers, TRUE/FALSE.
M.standard = M.make("standard", {})

---A dialect as is; without one, standard SQL.
---@param d dbdash.template.Dialect?
---@return dbdash.template.Dialect
function M.get(d)
  return type(d) == "table" and d or M.standard
end

return M
