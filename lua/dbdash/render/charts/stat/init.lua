-- The stat chart type (ARCHITECTURE.md#extending):
-- big values, their change and a sparkline (a Grafana stat).
local content = require("dbdash.render.content.chart")
local nn = require("dbdash.util.null").nn

local M = {
  renderers = { "big" },
  -- stat (one per value) > value (.<threshold class>), unit, label, delta, sparkline
  parts = content.parts(function(rs, show)
    local big = require("dbdash.render.charts.stat.big")
    local common = require("dbdash.render.charts.stat.common")
    local stats = {}
    for i, sub in ipairs(big.values(show)) do
      local v = common.value(rs, sub)
      stats[i] = {
        name = tostring(nn(sub.value_column) or ""),
        classes = v ~= nil and big.classes(v, sub) or {},
      }
    end
    return { series = {}, legend = {}, stats = stats }
  end),
  style = {
    ["chart.stat value"] = { color = "DbDashStatValue", ["font-size"] = "big" },
    ["chart.stat label"] = { color = "DbDashMuted" },
    ["chart.stat value.success"] = { color = "DiagnosticOk" },
    ["chart.stat value.info"] = { color = "DiagnosticInfo" },
    ["chart.stat value.warning"] = { color = "DiagnosticWarn" },
    ["chart.stat value.danger"] = { color = "DiagnosticError" },
    ["unit"] = { color = "DbDashMuted" },
    ["delta.up"] = { color = "DbDashUp" },
    ["delta.down"] = { color = "DbDashDown" },
    ["delta.same"] = { color = "DbDashMuted" },
    ["sparkline"] = { color = "DbDashSeries1" },
  },
}

return M
