-- Template error objects shared by the lexer, parser, compiler and runtime.
local M = {}

-- A template error is a dbdash.Error of phase "template" (with kind, line, col, source).
---@alias dbdash.template.Error dbdash.Error

local errors = require("dbdash.util.error")
M.Error = errors.Error

---@return dbdash.template.Error
function M.new(kind, message, line, col)
  return errors.new({ phase = "template", kind = kind, message = message, line = line, col = col })
end

function M.is(e)
  return errors.is(e) and e.phase == "template"
end

---Raise a syntax error at a position.
function M.syntax(line, col, msg, ...)
  error(M.new("syntax", select("#", ...) > 0 and msg:format(...) or msg, line, col), 0)
end

---Raise a runtime error; the line is filled in by the renderer.
---@return any (it never returns)
function M.raise(kind, msg, ...)
  error(M.new(kind, select("#", ...) > 0 and msg:format(...) or msg), 0)
end

return M
