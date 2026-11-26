-- Jinja2 template engine (design §6): lexer -> parser -> Lua codegen -> load().
local lexer = require("dbdash.template.lexer")
local parser = require("dbdash.template.parser")
local compiler = require("dbdash.template.compiler")
local errors = require("dbdash.template.errors")
local R = require("dbdash.template.runtime")

require("dbdash.template.filters").install()
require("dbdash.template.globals").install()
require("dbdash.template.sql").install()

local M = {}

M.Error = errors.Error
M.env = require("dbdash.template.sql").env
M.runtime = R

---@class dbdash.template.Env
---@field autoescape boolean?
---@field escape fun(v: any): string? dialect literal formatter used when autoescape is on
---@field dialect table?

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

---Compile and render, returning an error object instead of raising.
---@param src string
---@param vars table<string, any>
---@param opts { env: dbdash.template.Env?, source: string?, line_offset: integer? }?
---@return string? out, dbdash.template.Error? err
function M.render(src, vars, opts)
  opts = opts or {}
  local env = opts.env or {}
  env.source = env.source or opts.source -- the chunk name of {% lua %} code
  local ok, res = pcall(function()
    return M.compile(src):render(vars, env)
  end)
  if ok then
    return res
  end
  if not errors.is(res) then
    res = errors.new("internal", tostring(res))
  end
  if res.source then
    return nil, res -- raised in an imported file: its own name and line
  end
  res.source = opts.source
  if res.line and opts.line_offset then
    res.line = res.line + opts.line_offset
  end
  return nil, res
end

return M
