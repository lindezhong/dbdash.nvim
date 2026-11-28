-- The table chart type (ARCHITECTURE.md#extending):
-- the rows as they are, sorted, formatted, colored by thresholds.
local M = {
  renderers = { "box" },
  -- table > header[column], row > cell[column] (charts/table/content.lua)
  parts = require("dbdash.render.charts.table.content"),
  style = {
    ["table"] = { ["border-color"] = "DbDashBorder", border = "rich" },
    ["header"] = { color = "DbDashHeader" },
    ["rule"] = { display = "none" }, -- lines between table rows
  },
}

return M
