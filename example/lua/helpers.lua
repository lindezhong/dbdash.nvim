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

---A label for the panel, from the metadata.
function M.label()
  return ("%s on %s"):format(meta.config_name, meta.os)
end

return M
