-- Tableau 10 palette (fixed colors, independent of the colorscheme).
local highlight = require("dbdash.render.highlight")

local M = { name = "tableau" }

M.colors = {
  "#4e79a7", "#f28e2b", "#e15759", "#76b7b2", "#59a14f",
  "#edc948", "#b07aa1", "#ff9da7", "#9c755f", "#bab0ac",
}
M.size = #M.colors

function M.color(i)
  return highlight.color(M.colors[(i - 1) % M.size + 1])
end

return M
