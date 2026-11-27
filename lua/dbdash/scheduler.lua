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
-- This module is the scheduler's interface; the work is split over lua/dbdash/scheduler/:
-- shared (classes, helpers), run (runs, records, templates), panel (refresh pipeline,
-- timers), stream (push sources), view (drawing), dashboard (global timer, pause/resume),
-- lifecycle (start/stop).
local M = {}
-- The modules below add their functions to this table (and require it while it loads).
package.loaded["dbdash.scheduler"] = M

---@type table<string, dbdash.Dashboard>
M.dashboards = {}

---Human-readable error with its phase.
function M.format_error(err)
  if type(err) ~= "table" then
    return tostring(err)
  end
  if err.phase == "cancelled" then
    return err.message -- "query cancelled: <reason>"
  end
  local phase = err.phase or "error"
  local msg = getmetatable(err) and getmetatable(err).__tostring and tostring(err) or err.message
  if err.phase == "template" and err.message then
    msg = (err.source and (err.source .. ":") or "")
      .. (err.line and (err.line .. ": ") or "")
      .. err.message
  end
  if msg:find("^" .. vim.pesc(phase)) or msg:find("^%w+ " .. vim.pesc(phase)) then
    return msg
  end
  return ("[%s] %s"):format(phase, msg)
end

function M.get(path)
  return M.dashboards[path]
end

---Dashboard shown in `buf`, if any.
function M.for_buf(buf)
  local path = vim.b[buf].dbdash_path
  if path then
    return M.dashboards[path]
  end
end

---Dashboards sorted by path.
function M.list()
  local out = vim.tbl_values(M.dashboards)
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

---Normalize a config path argument to an absolute path.
function M.normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
end

local S = require("dbdash.scheduler.shared")
require("dbdash.scheduler.run")
require("dbdash.scheduler.panel")
require("dbdash.scheduler.stream")
require("dbdash.scheduler.view")
require("dbdash.scheduler.dashboard")
require("dbdash.scheduler.lifecycle")

M.Dashboard = S.Dashboard
M.Panel = S.Panel

return M
