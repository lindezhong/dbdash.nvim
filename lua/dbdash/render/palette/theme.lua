-- Default series colors: DbDashSeries1..8, linked to colorscheme groups.
local M = { name = "theme", size = 8 }

---Highlight group for series `i` (1-based, wraps around).
function M.color(i)
  return "DbDashSeries" .. ((i - 1) % M.size + 1)
end

return M
