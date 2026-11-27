-- A panel's history (:DbDashHistory): the last refreshes, newest first, recorded from the
-- panel's events (setup defaults.history entries at most).
local M = {}

---@class dbdash.HistoryEntry
---@field at integer os.time()
---@field elapsed_ms number?
---@field rows integer?
---@field error string?
---@field skipped boolean?
---@field cancelled string? why the refresh was cancelled

---@param p dbdash.Panel
---@param entry dbdash.HistoryEntry
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
  ev:on("panel:result", function(p, rs, o)
    push(p, { elapsed_ms = o.elapsed_ms, rows = rs.row_count })
  end)
  ev:on("panel:error", function(p, err, o)
    if not o.internal then
      push(p, { error = require("dbdash.util.error").format(err) })
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
