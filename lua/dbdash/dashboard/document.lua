-- The document of a dashboard (the HTML parser's place in Servo; dashboard/commit.lua
-- writes the dashboard's state into it): a dashboard is
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
---@param d table the dashboard
function M.dashboard(d)
  -- the chart types (their parts' styles go into the UA sheet the document gets)
  require("dbdash.render.registry").types()
  local doc = css.document("dashboard")
  d.doc = doc
  d.header_node = doc.root:append(dom.new("header"))
  -- the config's sheets: the dashboard's (author origin), each panel's (inline, scoped)
  if d.cfg.style_rules then
    doc:set_sheet("author", d.cfg.style_rules)
  end
  for _, p in ipairs(d.panels) do
    local t = p.cfg.show.type
    p.node = doc.root:append(dom.new("panel", { id = p.cfg.id, classes = { t } }))
    p.chart_node = p.node:append(dom.new("chart", { classes = { t }, attrs = { type = t } }))
    if p.cfg.style_rules then
      doc:set_sheet("inline", p.cfg.style_rules, p.node)
    end
  end
  return doc
end

---The header shows ⓘ for the dashboard's description (a panel's is on its own title line).
function M.header_icon(d)
  return d.cfg.description ~= nil
end

---The document of a config without running it (config checks, tests, tools): a stand-in
---dashboard { cfg, doc, header_node, panels = { { cfg, node, chart_node } } }.
function M.from_config(cfg)
  local d = { cfg = cfg, panels = {} }
  for i, pc in ipairs(cfg.panels) do
    d.panels[i] = { cfg = pc }
  end
  M.dashboard(d)
  return d
end

return M
