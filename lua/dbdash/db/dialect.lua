-- Per-database literal and identifier quoting (design §8.7). Template SQL filters and
-- autoescape only use these functions.
local map = require("dbdash.util.map")

local M = {}

---@class dbdash.db.Dialect
---@field name string
---@field quote_string fun(s: string): string
---@field quote_ident fun(s: string): string
---@field literal fun(v: any): string
---@field boolean_literal fun(b: boolean): string
---@field null string

local function numstr(v)
  return require("dbdash.template.runtime").numstr(v)
end

local function fail(msg, ...)
  error({ phase = "template", kind = "value", message = msg:format(...) }, 0)
end

---Validate an identifier: letters, digits, underscore, optionally dotted (schema.table).
local function ident_parts(s)
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

local function quoter(open, close)
  return function(s)
    local parts = ident_parts(s)
    for i, p in ipairs(parts) do
      parts[i] = open .. p .. close
    end
    return table.concat(parts, ".")
  end
end

local function standard_string(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

local MYSQL_ESC = {
  ["\\"] = "\\\\",
  ["'"] = "''",
  ["\0"] = "\\0",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\26"] = "\\Z",
}

---Build a dialect from its string/identifier/boolean rules.
local function make(name, spec)
  local d = { name = name, null = spec.null or "NULL" }
  d.quote_string = spec.quote_string or standard_string
  d.quote_ident = spec.quote_ident or quoter('"', '"')
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
    elseif require("dbdash.template.runtime").is_safe(v) then
      return v.s
    elseif require("dbdash.template.runtime").is_float_box(v) then
      return require("dbdash.template.runtime").floatstr(v) -- 2.0 (a template float)
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

local function json(v)
  return require("dbdash.template.filters").to_json(v)
end

M.dialects = {
  sqlite = make("sqlite", {}),
  postgres = make("postgres", {}),
  cassandra = make("cassandra", {}),
  mysql = make("mysql", {
    quote_string = function(s)
      return "'" .. s:gsub("[\\'%z\n\r\26]", MYSQL_ESC) .. "'"
    end,
    quote_ident = function(s)
      local parts = ident_parts(s)
      for i, p in ipairs(parts) do
        parts[i] = "`" .. p .. "`"
      end
      return table.concat(parts, ".")
    end,
  }),
  mssql = make("mssql", {
    quote_string = function(s)
      local q = standard_string(s)
      return s:find("[\128-\255]") and ("N" .. q) or q
    end,
    quote_ident = quoter("[", "]"),
    boolean_literal = function(b)
      return b and "1" or "0"
    end,
  }),
  mongodb = make("mongodb", {
    null = "null",
    quote_string = json,
    quote_ident = function(s)
      ident_parts(s)
      return json(s)
    end,
    boolean_literal = function(b)
      return b and "true" or "false"
    end,
    list_literal = function(v)
      return json(v)
    end,
    map_literal = json,
  }),
  redis = make("redis", {
    -- Redis commands are tokenized shell-style; double quotes with backslash escapes.
    quote_string = function(s)
      return '"' .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
    end,
    quote_ident = function(s)
      return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
    end,
    boolean_literal = function(b)
      return b and "1" or "0"
    end,
    null = '""',
  }),
}

---@param name string database type
---@return dbdash.db.Dialect
function M.get(name)
  return M.dialects[name] or M.dialects.sqlite
end

return M
