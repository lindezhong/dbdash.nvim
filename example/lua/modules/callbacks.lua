-- Callbacks from an imported module, for example/lua/callback.yaml:
-- {% import 'modules/callbacks.lua' as cb %}. A module's functions see the panel's args, meta,
-- store and dbdash.* like any Lua in the dashboard, so they can call dbdash.run() too.
local M = {}

---The panel's own query over `days` days (a dbdash.run() callback): its `orders` column.
function M.orders(days)
  return dbdash.run({ days = days }).rows[1][2]
end

return M
