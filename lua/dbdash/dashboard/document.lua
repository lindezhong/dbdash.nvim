-- The document of a dashboard (the HTML parser's place in Servo), and its updates from the
-- dashboard's state (commit): a dashboard is
--   dashboard
--     header            title, ⓘ, the global countdown
--     panel#<id>.<type> one per panel (id: the panel's id), with its title, args line,
--       chart.<type>    error and the chart; the chart's parts hang below it
-- Parts of the view and of charts are created when they are first styled (css.scope).
local css = require("dbdash.css")
local dom = require("dbdash.dom.node")
local format_error = require("dbdash.util.error").format

local M = {}

---Build (or rebuild) the document of a dashboard: d.doc, d.header_node, and for every
---panel p.node and p.chart_node.
---@param d table the dashboard (scheduler)
function M.dashboard(d)
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

local child = dom.child

---The header shows ⓘ for the dashboard's description, and in a one-chart dashboard for the
---chart's too (the chart has no title line of its own).
function M.header_icon(d)
  local cfg = d.cfg
  return cfg.description ~= nil or (not cfg.grid and d.panels[1].cfg.show.description ~= nil)
end

---Commit: bring the nodes up to date with the dashboard's state (titles, ⓘ, errors,
---argument values, each panel's content). Only changes mark nodes dirty, as DOM mutations
---do in a browser; the document then asks its view for a frame (Document.on_update).
---@param d table the dashboard
function M.sync(d)
  if not d.doc then
    M.dashboard(d)
  end
  local style = require("dbdash.css.style")
  ---ⓘ: the icon element's content (description-icon { content }), unless it is hidden
  local function icon(parent, shown)
    local n = child(parent, "description-icon")
    local c = style.get(n)
    n:set_text(shown and c.display ~= "none" and c.content or nil)
  end
  child(d.header_node, "header-title"):set_text(d.cfg.title or "")
  icon(d.header_node, M.header_icon(d))
  for _, p in ipairs(d.panels) do
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
    title:set_text(style.get(title).display == "none" and "" or p:title())
    icon(p.node, p.cfg.show.description ~= nil)
    child(p.node, "error"):set_text(p.error and format_error(p.error) or nil)
    local sub = show.subtitle
    child(p.node, "subtitle"):set_text(sub ~= nil and sub ~= vim.NIL and sub or nil)
    -- the argument line: arg-name (.local for a panel's own) = arg-value, per shown arg
    local args = child(p.node, "args")
    local items = {}
    for _, spec in ipairs(p.cfg.shown_args) do
      local value = require("dbdash.args").format_value(require("dbdash.args").value(spec, d.state))
      items[#items + 1] = { name = spec.name, value = value, ["local"] = spec.panel ~= nil }
    end
    if not vim.deep_equal(items, args.items) then
      args.items = items
      local kids = {}
      for _, it in ipairs(items) do
        kids[#kids + 1] =
          dom.new("arg-name", { classes = it["local"] and { "local" } or {}, text = it.name })
        kids[#kids + 1] = dom.new("arg-value", { text = it.value })
      end
      args:set_children(kids)
    end
  end
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
