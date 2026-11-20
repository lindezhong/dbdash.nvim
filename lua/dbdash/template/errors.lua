-- Template error objects shared by the lexer, parser, compiler and runtime.
local M = {}

---@class dbdash.template.Error
---@field phase "template"
---@field kind "syntax"|"undefined"|"type"|"value"|"internal"
---@field message string
---@field line integer? 1-based template line
---@field col integer?
---@field source string? template name used in messages

local Error = {}
Error.__index = Error
Error.__tostring = function(e)
  local where = e.line and ((e.source or "template") .. ":" .. e.line .. ": ") or ""
  return where .. e.message
end
M.Error = Error

---@return dbdash.template.Error
function M.new(kind, message, line, col)
  return setmetatable({ phase = "template", kind = kind, message = message, line = line, col = col }, Error)
end

function M.is(e)
  return getmetatable(e) == Error
end

---Raise a syntax error at a position.
function M.syntax(line, col, msg, ...)
  error(M.new("syntax", select("#", ...) > 0 and msg:format(...) or msg, line, col), 0)
end

---Raise a runtime error; the line is filled in by the renderer.
function M.raise(kind, msg, ...)
  error(M.new(kind, select("#", ...) > 0 and msg:format(...) or msg), 0)
end

return M
