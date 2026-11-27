-- Safe strings (as Python's markupsafe.Markup): text that templates write as it is, even
-- with autoescape (SQL a template built on purpose, dbdash.safe()).
local M = {}

local Safe = {}
Safe.__index = Safe
M.Safe = Safe

---A safe string: written as it is, even with autoescape.
function M.safe(s)
  return setmetatable({ s = s }, Safe)
end
---@return boolean
function M.is_safe(v)
  return getmetatable(v) == Safe
end

return M
