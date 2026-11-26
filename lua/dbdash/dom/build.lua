-- Building documents from configs (the HTML parser's place in Servo): a dashboard is
--   dashboard
--     header            title, ⓘ, the global countdown
--     panel#<id>.<type> one per panel (id: the panel's id), with its title, args line,
--       chart.<type>    error and the chart; the chart's parts hang below it
-- Parts of the view and of charts are created when they are first styled (css.scope).
local css = require("dbdash.css")
local dom = require("dbdash.dom.node")

local M = {}

-- dashboard.keys actions (events) -> the command that is their default action
M.ACTIONS = {
  modify = "modify_variable",
  show_args = "show_variables",
  refresh = "restart",
  reset = "reset_variables",
  show_sql = "show_sql",
  export = "export",
  describe = "describe",
}

---Build (or rebuild) the document of a dashboard: d.doc, d.header_node, and for every
---panel p.node and p.chart_node.
---@param d table the dashboard (scheduler)
function M.dashboard(d)
  local doc = css.document("dashboard")
  d.doc = doc
  d.header_node = doc.root:append(dom.new("header"))
  -- the dashboard keys are events at the cursor; their default actions listen on the root
  for action, fn in pairs(M.ACTIONS) do
    doc.root:on(action, function(ev)
      local commands = require("dbdash.commands")
      if action == "export" then
        commands.export({}, false, ev.detail and ev.detail.register) -- "xe: register x
      else
        commands[fn]()
      end
    end)
  end
  for _, p in ipairs(d.panels) do
    local t = p.cfg.show.type
    p.node = doc.root:append(dom.new("panel", { id = p.cfg.id, classes = { t } }))
    p.chart_node = p.node:append(dom.new("chart", { classes = { t }, attrs = { type = t } }))
  end
  return doc
end

---The direct child of `parent` with `tag` (created at the end when missing).
local function child(parent, tag)
  for _, c in ipairs(parent.children) do
    if c.tag == tag then
      return c
    end
  end
  return parent:append(dom.new(tag))
end
M.child = child

---Bring the view's nodes up to date with the dashboard's state (titles, ⓘ, errors,
---argument values). Only changes mark nodes dirty, as DOM mutations do in a browser.
---@param d table the dashboard
---@param o { icon: string, format_error: fun(err: any): string, header_icon: boolean }
function M.sync(d, o)
  if not d.doc then
    M.dashboard(d)
  end
  child(d.header_node, "header-title"):set_text(d.cfg.title or "")
  child(d.header_node, "description-icon"):set_text(o.header_icon and o.icon or nil)
  for _, p in ipairs(d.panels) do
    local show = p:show_config()
    local style = show.style ~= vim.NIL and show.style or {}
    child(p.node, "panel-title"):set_text(style.show_title == false and "" or p:title())
    child(p.node, "description-icon"):set_text(p.cfg.show.description and o.icon or nil)
    child(p.node, "error"):set_text(p.error and o.format_error(p.error) or nil)
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
        kids[#kids + 1] = dom.new("arg-name", { classes = it["local"] and { "local" } or {}, text = it.name })
        kids[#kids + 1] = dom.new("arg-value", { text = it.value })
      end
      args:set_children(kids)
    end
  end
end

---A document for one view of its own (the sidebar, a popup): root `tag`.
function M.view(tag)
  return css.document(tag)
end

return M
