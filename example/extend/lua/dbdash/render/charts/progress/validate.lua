-- [chart progress]: a progress chart's show names its columns; max is a positive number.
local nn = require("dbdash.util.null").nn

local M = {
  name = "chart progress",
  checks = "progress charts: label_column and value_column, max > 0",
  after = { "chart" },
  validate = function(cfg, ctx)
    for _, p in ipairs(cfg.panels) do
      if p.show.type == "progress" then
        local path = p.prefix .. "show"
        ctx:expect(path .. ".label_column", p.show.label_column, "string")
        ctx:expect(path .. ".value_column", p.show.value_column, "string")
        local max = nn(p.show.max)
        if max ~= nil and (type(max) ~= "number" or max <= 0) then
          ctx:fail(path .. ".max", "max must be a positive number")
        end
      end
    end
  end,
}

return M
