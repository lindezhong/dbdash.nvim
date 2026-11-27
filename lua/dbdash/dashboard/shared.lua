-- State shared by the scheduler's modules: the Panel and Dashboard classes and small
-- helpers.
local M = {}

---@class dbdash.HistoryEntry
---@field at integer os.time()
---@field elapsed_ms number?
---@field rows integer?
---@field error string?
---@field skipped boolean?
---@field cancelled string? why the refresh was cancelled

---@class dbdash.Feed a run of a panel's source and its queue of results
---@field queue table[] results waiting for the consumer
---@field received integer
---@field processed integer
---@field dropped integer
---@field state string "starting" | "running" | "listening ..." | "ended" | "failed"
---@field token dbdash.db.CancelToken stops the run
---@field handle table? db.run's handle
---@field sql string? the rendered query of a source that sends data
---@field busy boolean? the consumer is working
---@field stopped boolean?
---@field ended boolean? the source returned (or failed)
---@field end_error table?
---@field finished boolean?

---@class dbdash.Panel
---@field d dbdash.Dashboard
---@field index integer
---@field cfg dbdash.PanelConfig
---@field push boolean? a push source (shown so)
---@field sends boolean? its source sends data (a driver with produce)
---@field node dbdash.dom.Node the panel's element
---@field chart_node dbdash.dom.Node its chart element
---@field running boolean a query of a tick runs
---@field current dbdash.Run? the run of that query
---@field gen integer the run's number (results of an older run are dropped)
---@field feed dbdash.Feed? the current run
---@field stream dbdash.Feed? the same (read by :DbDashStatus)
---@field waits_ticks boolean? its source waits for ticks
---@field start_tick boolean? the first wait of the run returns at once
---@field waiter fun(go: boolean)? resumes the source waiting for a tick
---@field dirty boolean? a result waits for the next tick to be drawn
---@field ended boolean? its source ended
---@field next_at integer? loop time (ms) of the next tick
---@field retry_at integer? backing off: the next query not before
---@field backoff_mult integer? the interval's multiple while backing off
---@field failures integer? failures in a row
---@field rs dbdash.db.ResultSet? last successful result
---@field sql string? last rendered query
---@field transform_code string? last rendered query.transform
---@field error table? last error (cleared on success)
---@field history dbdash.HistoryEntry[]
---@field style table overrides from :DbDashStyle
---@field runtime_style table? :DbDashStyle rules of the panel
---@field store table `store` of its Lua code
---@field meta table? the metadata of the last run (meta)
---@field values number[]? the values of stat charts
---@field levels table<string, integer>? threshold levels reached
---@field refresh_count integer? meta.refresh_count
---@field prev table? the record of the last run (meta.prev)
---@field prev_runs table[]?
---@field prev_ok table? the record of the last successful run (meta.prev_ok)
---@field prev_ok_runs table[]?
---@field layout_cache table? (layout/view.lua)
---@field measured table? (layout/view.lua)
local Panel = {}
Panel.__index = Panel

---@class dbdash.Dashboard
---@field path string
---@field cfg dbdash.Config
---@field state dbdash.ArgState
---@field panels dbdash.Panel[]
---@field doc dbdash.dom.Document its document (dashboard/document.lua)
---@field header_node dbdash.dom.Node
---@field clock dbdash.Clock? the panels' ticks and the top-level interval's (dashboard/timer.lua)
---@field paused boolean? hidden
---@field gnext_at integer? loop time (ms) of the next top-level tick
---@field refreshing_all boolean? the top-level tick's queries run ("…")
---@field writes_trusted boolean? the config was trusted with what it writes (curl -c files)
---@field runtime_style table? :DbDashStyle rules of the dashboard
---The view's (view/dashboard.lua):
---@field buf integer
---@field ctimer uv.uv_timer_t? countdown display timer
---@field regions table[]? buffer regions of the panels (multi-panel)
---@field hits table[]? hit-test regions (events/)
---@field header_rows integer?
---@field last_size integer[]?
---@field last_render_at integer?
---@field last_restyle table?
---@field render_pending boolean?
---@field render_skipped boolean? a frame waits for the dashboard to be shown
local Dashboard = {}
Dashboard.__index = Dashboard

M.Panel, M.Dashboard = Panel, Dashboard

function M.opts()
  return require("dbdash.options").current
end

---Report an error (§3.8: only errors produce messages).
function M.notify(err)
  vim.notify("dbdash: " .. require("dbdash.util.error").format(err), vim.log.levels.ERROR)
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
