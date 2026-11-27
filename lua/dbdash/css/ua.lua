-- The UA (user agent) style sheet: how everything looks before any user, dashboard or
-- panel rule. Colors are the DbDash* highlight groups, which link to standard groups and
-- so follow the colorscheme (:help dbdash-highlights).
local M = {
  -- the dashboard view
  ["header-title"] = { color = "DbDashTitle" },
  ["description-icon"] = { color = "DbDashDescIcon", content = "ⓘ" },
  -- countdowns are hidden unless a rule shows them (header countdown: the global refresh)
  ["countdown"] = { color = "DbDashCountdown", display = "none", content = "Next update: {time}s" },
  ["panel"] = { ["border-color"] = "DbDashBorder" },
  ["panel-title"] = { color = "DbDashTitle" },
  ["arg-name"] = { color = "DbDashArgName" },
  ["arg-value"] = { color = "DbDashArgValue" },
  ["arg-name.local"] = { color = "DbDashArgLocal" },
  ["error"] = { color = "DbDashError" },
  ["warning"] = { color = "DbDashWarn" },
  ["note"] = { color = "DbDashMuted" },
  -- charts
  ["title"] = { color = "DbDashTitle" },
  ["subtitle"] = { color = "DbDashMuted" },
  ["plot"] = { ["border-color"] = "DbDashBorder", border = "single" },
  ["axis"] = { color = "DbDashAxis" },
  ["axis-title"] = { color = "DbDashLabel" },
  ["label"] = { color = "DbDashLabel" },
  ["legend"] = { color = "DbDashLegend" },
  ["legend-item label"] = { color = "DbDashLegend" }, -- a pie legend's labels
  ["grid"] = { color = "DbDashGrid" },
  ["grid.x, grid.y"] = { display = "none" }, -- grid lines of xy charts
  ["chart.line point, chart.area point"] = { display = "none" }, -- markers on lines
  ["chart.heatmap value, chart.boxplot value"] = { display = "none" }, -- numbers in cells / boxes
  ["mean"] = { display = "none" }, -- box plot means
  ["mark"] = { color = "DbDashMark" },
  ["value"] = { color = "DbDashNumber" },
  ["percent"] = { color = "DbDashMuted" },
  ["unit"] = { color = "DbDashMuted" },
  ["series.other"] = { color = "DbDashMuted" },
  ["chart.stat value"] = { color = "DbDashStatValue", ["font-size"] = "big" },
  ["chart.stat label"] = { color = "DbDashMuted" },
  ["delta.up"] = { color = "DbDashUp" },
  ["delta.down"] = { color = "DbDashDown" },
  ["delta.same"] = { color = "DbDashMuted" },
  ["sparkline"] = { color = "DbDashSeries1" },
  ["table"] = { ["border-color"] = "DbDashBorder", border = "rich" },
  ["header"] = { color = "DbDashHeader" },
  ["cell"] = { padding = { 0, 1 } },
  ["cell.null"] = { color = "DbDashNull", content = "NULL" },
  ["rule"] = { display = "none" }, -- lines between table rows
  ["line"] = { color = "DbDashText", ["text-overflow"] = "clip" },
  ["line-number"] = { color = "DbDashMuted", display = "none" },
  ["chart.text cell.null"] = { content = "" },
  -- threshold classes (Bootstrap's contextual colors)
  ["value.success, cell.success, row.success, line.success"] = { color = "DiagnosticOk" },
  ["value.info, cell.info, row.info, line.info"] = { color = "DiagnosticInfo" },
  ["value.warning, cell.warning, row.warning, line.warning"] = { color = "DiagnosticWarn" },
  ["value.danger, cell.danger, row.danger, line.danger"] = { color = "DiagnosticError" },
  ["chart.stat value.success"] = { color = "DiagnosticOk" },
  ["chart.stat value.info"] = { color = "DiagnosticInfo" },
  ["chart.stat value.warning"] = { color = "DiagnosticWarn" },
  ["chart.stat value.danger"] = { color = "DiagnosticError" },
  -- the sidebar
  ["sidebar-dir"] = { color = "DbDashSidebarDir" },
  ["sidebar-item.running"] = { color = "DbDashSidebarRunning" },
  ["sidebar-item.paused"] = { color = "DbDashSidebarPaused" },
  ["sidebar-item.idle"] = { color = "DbDashSidebarIdle" },
  ["sidebar-item.cursor"] = { color = "DbDashSidebarCursor" },
}

return M
