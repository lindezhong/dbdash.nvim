-- Helpers for example/template_lua.yaml, imported with {% import 'lua/helpers.lua' as h %}.
-- A module returns a table; its functions are callable from template expressions and from
-- {% lua %} blocks (vars.h). It runs once per render and sees args and meta like any Lua
-- in a dashboard.
local M = {}

---The date `days` days ago as a SQL literal.
function M.since(days)
  return os.date("'%Y-%m-%d'", os.time() - days * 86400)
end

---Sample rows: one per day, as a VALUES list for SQLite.
function M.sample_values(days)
  local rows = {}
  for i = days - 1, 0, -1 do
    local day = os.date("%Y-%m-%d", os.time() - i * 86400)
    rows[#rows + 1] = ("('%s', %d)"):format(day, 100 + (i * 37) % 90)
  end
  return table.concat(rows, ", ")
end

---A condition on `column` (passed in) for the last args.days days (an argument of the
---dashboard), with a comment naming the database type (metadata).
function M.recent(column)
  return ("%s >= %s /* last %d days, %s */"):format(column, M.since(args.days), args.days, meta.db_type)
end

---A label: `prefix` (passed in), the number of days (args) and the config and OS (meta).
function M.label(prefix)
  return ("%s: %d days, %s on %s"):format(prefix, args.days, meta.config_name, meta.os)
end

return M
