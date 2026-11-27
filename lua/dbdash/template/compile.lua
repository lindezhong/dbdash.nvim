-- Template source -> compiled template (cached by source text), and its render method.
local lexer = require("dbdash.template.lexer")
local parser = require("dbdash.template.parser")
local compiler = require("dbdash.template.compiler")
local errors = require("dbdash.template.errors")
local R = require("dbdash.template.runtime")

local M = {}

---@class dbdash.template.Template
---@field fn function compiled render function
---@field source string Lua source (for debugging)
local Template = {}
Template.__index = Template

local cache = setmetatable({}, { __mode = "v" })

---Compile template source (cached by source text).
---@param src string
---@return dbdash.template.Template
function M.compile(src)
  local t = cache[src]
  if t then
    return t
  end
  local body = parser.parse(lexer.tokenize(src))
  local lua = compiler.compile(body)
  local chunk, err = load(lua, "=template", "t")
  if not chunk then
    error(errors.new("internal", "template codegen failed: " .. err), 0)
  end
  t = setmetatable({ fn = chunk(R), source = lua }, Template)
  cache[src] = t
  return t
end

---Render with variables. Raises dbdash.template.Error on failure.
---@param vars table<string, any>
---@param env dbdash.template.Env?
---@return string
function Template:render(vars, env)
  local L = { l = nil }
  local ok, res = pcall(self.fn, vars or {}, env or {}, L)
  if ok then
    return res
  end
  if errors.is(res) then
    res.line = res.line or L.l
    error(res, 0)
  end
  error(errors.new("internal", tostring(res), L.l), 0)
end

return M
