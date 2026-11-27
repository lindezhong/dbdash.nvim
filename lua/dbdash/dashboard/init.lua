-- Running dashboards and their refresh cycle (design §12).
--
-- A dashboard has one or more panels. Each panel refreshes on its own interval: render
-- template -> db.query -> render chart -> redraw. A refresh that comes due while the
-- panel's query is still running is skipped (and recorded); one the user asks for cancels
-- it (Panel:cancel). On error the panel keeps its last good content and shows the error.
--
-- Multi-panel configs with a top-level `interval` also have a global timer that refreshes
-- every panel and restarts the panels' own timers.
--
-- This module is the scheduler's interface; the work is split over lua/dbdash/dashboard/:
-- shared (classes, helpers), run (runs, records, templates), panel (refresh pipeline,
-- timers), stream (push sources), view (drawing), dashboard (global timer, pause/resume),
-- lifecycle (start/stop).
local registry = require("dbdash.dashboard.registry")
local lifecycle = require("dbdash.dashboard.lifecycle")
local S = require("dbdash.dashboard.shared")
-- the methods of the classes (shared.lua), by topic
require("dbdash.dashboard.run")
require("dbdash.dashboard.panel")
require("dbdash.dashboard.dashboard")

local M = {}

M.dashboards = registry.dashboards
M.get, M.for_buf, M.list, M.normalize =
  registry.get, registry.for_buf, registry.list, registry.normalize
M.prepare, M.create, M.stop, M.stop_all =
  lifecycle.prepare, lifecycle.create, lifecycle.stop, lifecycle.stop_all
M.freeze_all, M.trusted, M.apply_args =
  lifecycle.freeze_all, lifecycle.trusted, lifecycle.apply_args

---Human-readable error with its phase.
M.format_error = require("dbdash.util.error").format

M.Dashboard = S.Dashboard
M.Panel = S.Panel

return M
