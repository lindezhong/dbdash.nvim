-- The values of stat panels (the change since the previous refresh, the sparkline), kept
-- from their results (each new one their state tells: panel:state).
local M = {}

---@param p dbdash.Panel
---@param rs dbdash.db.ResultSet
local function track(p, rs)
  local show = p.cfg.show
  if show.type ~= "stat" then
    return
  end
  local C = require("dbdash.render.charts.stat.common")
  local v = C.track(rs, show)
  if v then
    p.values = p.values or {}
    table.insert(p.values, v)
    local length = show.sparkline_length ~= vim.NIL and show.sparkline_length or nil
    local keep = math.max(C.HISTORY, tonumber(length) or 0)
    while #p.values > keep do
      table.remove(p.values, 1)
    end
  end
end

---Keep the values of the stat panels of dashboard `d`.
---@param d dbdash.Dashboard
function M.attach(d)
  d.events:on("panel:state", function(p, st, changed)
    if changed.result then
      track(p, st.result)
    end
  end)
end

return M
