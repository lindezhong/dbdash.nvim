-- [chart] (config/types.lua): what every chart has: show.type is a chart type (table when
-- unset; render/charts/<type>/), the renderer, canvas and palette names in style sheets
-- exist, thresholds are valid (show.thresholds and those of show.column_list entries). What
-- only one chart type knows is its own validator's ([chart <type>],
-- render/charts/<type>/validate.lua).
local nn = require("dbdash.util.null").nn

---The renderer, canvas and palette a sheet names exist.
local function names(ctx, rules, path)
  local registry = require("dbdash.render.registry")
  for _, rule in ipairs(rules or {}) do
    for _, kind in ipairs({ "renderer", "canvas", "palette" }) do
      local name = rule.decls[kind]
      local known = registry.known(kind)
      if type(name) == "string" and not vim.tbl_contains(known, name) then
        table.sort(known)
        ctx:fail(
          ("%s.%s.%s"):format(path, rule.key, kind),
          "unknown %s '%s' (known: %s)",
          kind,
          name,
          table.concat(vim.fn.uniq(known) --[[@as string[] ]], ", ")
        )
      end
    end
  end
end

---show.thresholds and those of show.column_list entries.
local function thresholds(ctx, show, path)
  local check = require("dbdash.render.thresholds").check
  if nn(show.thresholds) ~= nil then
    local err = check(show.thresholds)
    if err then
      ctx:fail(path .. ".thresholds", "%s", err)
    end
  end
  for i, spec in ipairs(nn(show.column_list) or {}) do
    if type(spec) == "table" and nn(spec.thresholds) ~= nil then
      local err = check(spec.thresholds)
      if err then
        ctx:fail(("%s.column_list[%d].thresholds"):format(path, i - 1), "%s", err)
      end
    end
  end
end

local M = {
  name = "chart",
  checks = "show.type, renderer / canvas / palette names in style sheets, thresholds",
  after = { "css", "dashboard" },
  validate = function(cfg, ctx)
    names(ctx, cfg.style_rules, "style")
    for _, p in ipairs(cfg.panels) do
      local path = p.prefix .. "show"
      p.show.type = ctx:expect(path .. ".type", p.show.type, "string", true) or "table"
      if not require("dbdash.render.registry").type(p.show.type) then
        ctx:fail(path .. ".type", "unknown chart type '%s'", p.show.type)
      end
      thresholds(ctx, p.show, path)
      names(ctx, p.style_rules, p.prefix .. "style")
    end
  end,
}

return M
