-- [grid] (config/types.lua): the panels can be placed. They are placed once with the
-- config's own sheets (computed as a dashboard would), so conflicts (overlaps, unknown
-- areas, areas that are not rectangles) are reported with the line of the declaration at
-- fault; :DbDashStyle rules are placed again at layout.
local M = {
  name = "grid",
  checks = "the panels can be placed in the grid (grid-template-*, grid-area, grid-row, ...)",
  after = { "css", "chart", "dashboard" },
  validate = function(cfg, ctx)
    local doc = ctx:document(cfg)
    local style = require("dbdash.css.style")
    local items = {}
    for i, p in ipairs(doc.panels) do
      items[i] = style.get(p.node)
    end
    local _, err = require("dbdash.layout.grid").from_styles(style.get(doc.doc.root), items)
    if err then
      -- the declaration at fault: <sheet>.<selector>.<property>, else the sheet
      local own = err.index and cfg.panels[err.index].style_rules
      local sheet = own and ("panels[%d].style"):format(err.index) or "style"
      local rules = own or cfg.style_rules or {}
      local where = sheet
      for _, r in ipairs(rules) do
        if r.decls[err.field] ~= nil then
          where = ("%s.%s.%s"):format(sheet, r.key or r.selector.text, err.field)
        end
      end
      ctx:fail(where, "%s: %s", err.field, err.message)
    end
  end,
}

return M
