-- The UA (user agent) style sheet: how everything looks before any user, dashboard or
-- panel rule; each chart type adds the style of its own parts (its `style`,
-- render/charts/<type>/init.lua; render/registry adds it with css.add_ua). Colors are the
-- DbDash* highlight groups, which link to standard groups and so follow the colorscheme
-- (:help dbdash-highlights).
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
  -- the parts charts share
  ["subtitle"] = { color = "DbDashMuted" },
  ["plot"] = { ["border-color"] = "DbDashBorder", border = "single" },
  ["axis"] = { color = "DbDashAxis" },
  ["axis-title"] = { color = "DbDashLabel" },
  ["label"] = { color = "DbDashLabel" },
  ["legend"] = { color = "DbDashLegend" },
  ["grid"] = { color = "DbDashGrid" },
  ["grid.x, grid.y"] = { display = "none" }, -- grid lines of xy charts
  ["mark"] = { color = "DbDashMark" },
  ["value"] = { color = "DbDashNumber" },
  ["cell"] = { padding = { 0, 1 } },
  ["cell.null"] = { color = "DbDashNull", content = "NULL" },
  -- threshold classes (Bootstrap's contextual colors)
  ["value.success, cell.success, row.success, line.success"] = { color = "DiagnosticOk" },
  ["value.info, cell.info, row.info, line.info"] = { color = "DiagnosticInfo" },
  ["value.warning, cell.warning, row.warning, line.warning"] = { color = "DiagnosticWarn" },
  ["value.danger, cell.danger, row.danger, line.danger"] = { color = "DiagnosticError" },
  -- the sidebar
  ["sidebar-dir"] = { color = "DbDashSidebarDir" },
  -- a config file's mark (content) and its color: what its dashboard fetches
  ["sidebar-item.active"] = { color = "DbDashSidebarActive", content = "●" },
  ["sidebar-item.partly"] = { color = "DbDashSidebarPartly", content = "◐" },
  ["sidebar-item.idle"] = { color = "DbDashSidebarIdle", content = "○" },
  ["sidebar-item.stopped"] = { color = "DbDashSidebarStopped", content = "◌" },
  ["sidebar-item.cursor"] = { color = "DbDashSidebarCursor" },
}

return M
