-- [css] (config/types.lua): the style sheets of a config parse: the dashboard's (style) and
-- each panel's (panels[].style); their rules go into cfg.style_rules and each panel's.
local map = require("dbdash.util.map")

---The rules of the sheet at `path` (selector -> properties), in the order written.
---@return dbdash.css.Rule[]?
local function sheet(ctx, raw, path)
  local m = ctx:expect(path, raw, "map", true)
  if not m then
    return nil
  end
  local rules, err = require("dbdash.css.parser").sheet(m, map.keys(m))
  if not rules then
    ---@cast err -nil
    local where = path .. "." .. err.key
    if err.property then
      where = where .. "." .. err.property
    end
    ctx:fail(where, "%s", err.message)
  end
  return rules
end

local M = {
  name = "css",
  checks = "style sheets parse: the dashboard's (style) and each panel's (panels[].style)",
  validate = function(cfg, ctx)
    cfg.style_rules = sheet(ctx, cfg.raw.style, "style")
    for _, p in ipairs(cfg.panels) do
      p.style_rules = sheet(ctx, p.raw.style, p.prefix .. "style")
    end
  end,
}

return M
