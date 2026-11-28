-- A panel's history (:DbDashStatus): the last refreshes, newest first, recorded from the
-- panel's events and its state (setup defaults.history entries at most).
local M = {}

---@class dbdash.HistoryEntry
---@field at integer os.time()
---@field elapsed_ms number?
---@field rows integer?
---@field error string?
---@field skipped boolean?
---@field cancelled string? why the refresh was cancelled

---@param p dbdash.Panel
---@param entry table the entry without its time
local function push(p, entry)
  entry.at = os.time()
  table.insert(p.history, 1, entry)
  while #p.history > require("dbdash.options").current.defaults.history do
    table.remove(p.history)
  end
end

---Record the panels of dashboard `d`.
---@param d dbdash.Dashboard
function M.attach(d)
  local ev = d.events
  ev:on("panel:state", function(p, st, changed)
    if changed.run then -- a run settled: its result or its error
      if st.run.ok then
        push(p, { elapsed_ms = st.run.data_ms, rows = st.result.row_count })
      else
        push(p, { error = require("dbdash.util.error").format(st.error) })
      end
    elseif changed.error and st.error then -- the source itself failed
      push(p, { error = require("dbdash.util.error").format(st.error) })
    end
  end)
  ev:on("panel:skipped", function(p)
    push(p, { skipped = true })
  end)
  ev:on("panel:cancelled", function(p, reason)
    push(p, { cancelled = reason })
  end)
end

return M
