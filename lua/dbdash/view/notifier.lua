-- What the plugin tells the user: the one way to vim.notify, "dbdash: " before every
-- message (M.error / M.warn / M.info). It also tells what dashboards report: errors by
-- setup errors.notify ("once" when an error appears or changes, "always", "never"),
-- threshold steps that notify, configs that could not start.
local events = require("dbdash.dashboard.events")
local format_error = require("dbdash.util.error").format

local M = {}

---@param msg string
---@param level integer? vim.log.levels (default INFO)
function M.notify(msg, level)
  vim.notify("dbdash: " .. msg, level or vim.log.levels.INFO)
end

---An error (a dbdash error or a message).
function M.error(err)
  M.notify(format_error(err), vim.log.levels.ERROR)
end

---@param msg string
function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.info(msg)
  M.notify(msg, vim.log.levels.INFO)
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
    or p:shown_title()
    or vim.fn.fnamemodify(d.path, ":t")
  local what = cur.column and (cur.column .. " = ") or ""
  local value = require("dbdash.render.format").value_text(cur.value, nil, "NULL")
  M.warn(
    ("%s: %s%s %s %s"):format(
      title,
      what,
      value,
      cur.below and "≤" or "≥",
      require("dbdash.util.number").numstr(cur.step.value)
    )
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
