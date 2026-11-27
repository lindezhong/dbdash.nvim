-- Jinja2 template engine (design §6): lexer -> parser -> Lua codegen -> load().
local errors = require("dbdash.template.errors")
local R = require("dbdash.template.runtime")

require("dbdash.template.filters").install()
require("dbdash.template.globals").install()
require("dbdash.template.sql").install()

local M = {}

M.Error = errors.Error
M.env = require("dbdash.template.sql").env
M.runtime = R
M.compile = require("dbdash.template.compile").compile

---@class dbdash.template.Env
---@field autoescape boolean?
---@field escape fun(v: any): string? dialect literal formatter used when autoescape is on
---@field dialect table?

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
