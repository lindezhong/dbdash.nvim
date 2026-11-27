-- What dashboards tell the user (vim.notify): errors by setup errors.notify ("once" when
-- an error appears or changes, "always", "never"), threshold steps that notify, configs
-- that could not start.
local events = require("dbdash.dashboard.events")
local format_error = require("dbdash.util.error").format

local M = {}

function M.error(err)
  vim.notify("dbdash: " .. format_error(err), vim.log.levels.ERROR)
end

local function on_error(_, err, o)
  local mode = require("dbdash.options").current.errors.notify
  if o.always or mode == "always" or (mode == "once" and o.changed) then
    M.error(err)
  end
end

local function on_threshold(p, cur)
  local d = p.d
  local t = p.cfg.show.title
  local title = (t and t ~= "") and t
    or d.cfg.title
    or (d.cfg.grid and p:title() or vim.fn.fnamemodify(d.path, ":t"))
  local what = cur.column and (cur.column .. " = ") or ""
  local value = require("dbdash.render.format").value_text(cur.value, nil, "NULL")
  vim.notify(
    ("dbdash: %s: %s%s %s %s"):format(
      title,
      what,
      value,
      cur.below and "≤" or "≥",
      require("dbdash.util.number").numstr(cur.step.value)
    ),
    vim.log.levels.WARN
  )
end

events:on("dashboard:started", function(d)
  d.events:on("panel:error", on_error)
  d.events:on("panel:threshold", on_threshold)
end)

events:on("dashboard:error", function(_, err)
  M.error(err)
end)

return M
