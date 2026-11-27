-- State shared by the scheduler's modules: the Panel and Dashboard classes and small
-- helpers. See lua/dbdash/scheduler.lua.
local M = {}

---@class dbdash.HistoryEntry
---@field at integer os.time()
---@field elapsed_ms number?
---@field rows integer?
---@field error string?
---@field skipped boolean?
---@field cancelled string? why the refresh was cancelled

---@class dbdash.Panel
---@field d dbdash.Dashboard
---@field index integer
---@field cfg dbdash.PanelConfig
---@field timer uv.uv_timer_t?
---@field running boolean
---@field current dbdash.Run? the refresh running now (its result is dropped once it is not)
---@field next_at integer loop time (ms) of the next refresh
---@field rs dbdash.db.ResultSet? last successful result
---@field sql string? last rendered query
---@field error table? last error (cleared on success)
---@field history dbdash.HistoryEntry[]
---@field style table overrides from :DbDashStyle
local Panel = {}
Panel.__index = Panel

---@class dbdash.Dashboard
---@field path string
---@field cfg dbdash.Config
---@field state dbdash.ArgState
---@field buf integer
---@field panels dbdash.Panel[]
---@field gtimer uv.uv_timer_t? global refresh timer (top-level interval: cfg.refresh_all)
---@field ctimer uv.uv_timer_t? countdown display timer
---@field regions table[]? buffer regions of the panels (multi-panel)
---@field last_size integer[]?
---@field writes_trusted boolean? the config was trusted with what it writes (curl -c files)
local Dashboard = {}
Dashboard.__index = Dashboard

M.Panel, M.Dashboard = Panel, Dashboard

function M.opts()
  return require("dbdash").options
end

---Report an error (§3.8: only errors produce messages).
function M.notify(err)
  vim.notify("dbdash: " .. require("dbdash.scheduler").format_error(err), vim.log.levels.ERROR)
end

function M.now()
  vim.uv.update_time()
  return vim.uv.now()
end

function M.close_timer(t)
  if t then
    t:stop()
    if not t:is_closing() then
      t:close()
    end
  end
end

---Template errors keep their own shape (file and line); others become database errors.
function M.as_error(err)
  if type(err) == "table" and err.phase == "template" then
    return err
  end
  return require("dbdash.util.error").wrap(err)
end

return M
