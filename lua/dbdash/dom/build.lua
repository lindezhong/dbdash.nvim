-- Building documents from configs (the HTML parser's place in Servo): a dashboard is
--   dashboard
--     header            title, ⓘ, the global countdown
--     panel#<id>.<type> one per panel (id: the panel's id), with its title, args line,
--       chart.<type>    error and the chart; the chart's parts hang below it
-- Parts of the view and of charts are created when they are first styled (css.scope).
local css = require("dbdash.css")
local dom = require("dbdash.dom.node")

local M = {}

---Build (or rebuild) the document of a dashboard: d.doc, d.header_node, and for every
---panel p.node and p.chart_node.
---@param d table the dashboard (scheduler)
function M.dashboard(d)
  local doc = css.document("dashboard")
  d.doc = doc
  d.header_node = doc.root:append(dom.new("header"))
  for _, p in ipairs(d.panels) do
    local t = p.cfg.show.type
    p.node = doc.root:append(dom.new("panel", { id = p.cfg.id, classes = { t } }))
    p.chart_node = p.node:append(dom.new("chart", { classes = { t }, attrs = { type = t } }))
  end
  return doc
end

---A document for one view of its own (the sidebar, a popup): root `tag`.
function M.view(tag)
  return css.document(tag)
end

return M
