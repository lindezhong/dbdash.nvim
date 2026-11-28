-- The text chart type (ARCHITECTURE.md#extending):
-- one line per row (logs, messages).
local M = {
  renderers = { "plain" },
  -- lines > line, line-number (charts/text/content.lua)
  parts = require("dbdash.render.charts.text.content"),
  style = {
    ["line"] = { color = "DbDashText", ["text-overflow"] = "clip" },
    ["line-number"] = { color = "DbDashMuted", display = "none" },
    ["chart.text cell.null"] = { content = "" },
  },
}

return M
