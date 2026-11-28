-- Commit (ARCHITECTURE.md#drawing): the model writes what is shown into its document, as a
-- script writes the DOM; only changes mark nodes dirty, and a document that gets something
-- to update asks its view for a frame (Document.on_update).
--
-- A panel's results are committed at most once per period (its ticks): the first result
-- of a period at once (a database's query of the tick), later ones at the next tick (a
-- source that sends data faster than its interval). A hidden dashboard (dashboard:hidden)
-- commits nothing: its results wait, and are committed at once when it is shown again.
-- Committing is idempotent: a tick with nothing pending writes nothing new. The status
-- (running, listening..., the next tick) is element data (Node:set_data), written when it
-- changes.
local dom = require("dbdash.dom.node")
local format_error = require("dbdash.util.error").format

local M = {}

local child = dom.child

---ⓘ: the icon element's content (description-icon { content }), unless it is hidden.
local function icon(parent, shown)
  local n = child(parent, "description-icon")
  local c = require("dbdash.css.style").get(n)
  n:set_text(shown and c.display ~= "none" and c.content or nil)
end

---The header: title, ⓘ, and the top-level interval's countdown (data: next_at, and
---refreshing while the queries of its tick run).
---@param d dbdash.Dashboard
function M.header(d)
  child(d.header_node, "header-title"):set_text(d.cfg.title or "")
  icon(d.header_node, require("dbdash.dashboard.document").header_icon(d))
  M.header_status(d)
end

---@param d dbdash.Dashboard
function M.header_status(d)
  if d.refreshing_all then
    local running = false
    for _, p in ipairs(d.panels) do
      running = running or p.running
    end
    d.refreshing_all = running or nil
  end
  d.header_node:set_data("next_at", d.cfg.refresh_all and d.gnext_at or nil)
  d.header_node:set_data("refreshing", d.refreshing_all == true)
end

---The argument lines: arg-name (.local for a panel's own) = arg-value, per shown argument.
---@param d dbdash.Dashboard
function M.args(d)
  local args = require("dbdash.args")
  for _, p in ipairs(d.panels) do
    local node = child(p.node, "args")
    local items = {}
    for _, spec in ipairs(p.cfg.shown_args) do
      local value = args.format_value(args.value(spec, d.state))
      items[#items + 1] = { name = spec.name, value = value, ["local"] = spec.panel ~= nil }
    end
    if not vim.deep_equal(items, node.items) then
      node.items = items
      local kids = {}
      for _, it in ipairs(items) do
        kids[#kids + 1] =
          dom.new("arg-name", { classes = it["local"] and { "local" } or {}, text = it.name })
        kids[#kids + 1] = dom.new("arg-value", { text = it.value })
      end
      node:set_children(kids)
    end
  end
end

---A panel's elements: its type, title, ⓘ, error, subtitle and the chart's content.
---@param p dbdash.Panel
function M.panel(p)
  local style = require("dbdash.css.style")
  local show = p:show_config()
  -- the chart type (:DbDashStyle can switch it) is the elements' class and attribute
  p.node:set_classes({ show.type })
  p.chart_node:set_classes({ show.type })
  p.chart_node:set_attr("type", show.type)
  -- the chart's content (render/content): built from the result here, before styles are
  -- computed, as a script builds elements before the browser styles them; a result the
  -- data cannot show (a missing column) is reported by the renderer instead
  if p.rs and not p.error then
    pcall(require("dbdash.render.content").build, p.chart_node, p.rs, show)
  end
  local title = child(p.node, "panel-title")
  title:set_text(style.get(title).display ~= "none" and p:shown_title() or nil)
  icon(p.node, p.cfg.show.description ~= nil)
  local sub = show.subtitle
  child(p.node, "subtitle"):set_text(sub ~= nil and sub ~= vim.NIL and sub or nil)
end

---A panel's status: its error, and data of its element: running, its source's state
---(push panels), the next tick (none once it ended).
---@param p dbdash.Panel
function M.status(p)
  child(p.node, "error"):set_text(p.error and format_error(p.error) or nil)
  p.node:set_data("running", p.running == true)
  p.node:set_data("state", p:push_state())
  p.node:set_data("next_at", p.next_at)
  M.header_status(p.d)
end

---A result settled (or failed): committed now when the period has none yet, else at the
---next tick. The chart is laid out again (its values may change with the same result).
---@param p dbdash.Panel
function M.result(p)
  if p.committed or p.d.paused then
    p.pending = true
    return
  end
  p.committed, p.pending = true, false
  M.panel(p)
  M.status(p)
  M.args(p.d) -- (Lua code may have assigned arguments)
  p.chart_node:dirty("content")
end

---Everything (a new document, a changed style).
---@param d dbdash.Dashboard
function M.all(d)
  M.header(d)
  for _, p in ipairs(d.panels) do
    M.panel(p)
    M.status(p)
  end
  M.args(d)
end

---Commit what dashboard `d`'s panels tell.
---@param d dbdash.Dashboard
function M.attach(d)
  local ev = d.events
  ev:on("panel:tick", function(p)
    p.committed = false -- a new period
    if p.pending then
      M.result(p)
    end
    M.status(p)
  end)
  ev:on("panel:result", M.result)
  ev:on("panel:error", function(p, _, o)
    if not o.internal then
      M.result(p)
    end
  end)
  ev:on("panel:state", function(p)
    if p.ended and p.pending then
      p.committed = false -- the last result, now
      M.result(p)
    end
    M.status(p)
  end)
  ev:on("dashboard:args", function()
    M.args(d)
  end)
  -- shown again: what came while hidden, at once (after the clock's ticks that came due)
  ev:on("dashboard:shown", function()
    for _, p in ipairs(d.panels) do
      if p.pending then
        p.committed = false
        M.result(p)
      end
    end
  end)
end

return M
