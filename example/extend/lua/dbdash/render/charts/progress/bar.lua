-- The bar renderer of the progress chart type: "label  ██████░░░░  60%" per row.
local C = require("dbdash.render.charts.lib.common")
local nn = require("dbdash.util.null").nn
local W = require("dbdash.util.width")

local M = {}

---@param rs dbdash.db.ResultSet
---@param show table
---@param ctx dbdash.render.Ctx
---@return dbdash.render.Output
function M.render(rs, show, ctx)
  local li = C.col(rs, nn(show.label_column), "label_column")
  local vi = C.col(rs, nn(show.value_column), "value_column")
  local max = tonumber(nn(show.max)) or 100
  local label_w = 0
  for _, row in ipairs(rs.rows) do
    label_w = math.max(label_w, W.width(C.text(row[li])))
  end
  local bar_w = math.max(ctx.width - label_w - 8, 4)
  local bars = require("dbdash.render.content").list(ctx.css.node, "bar")
  local style = require("dbdash.css.style")
  local hl = require("dbdash.css.hl")
  local lines, groups = {}, {}
  for i, row in ipairs(rs.rows) do
    local v = math.max(0, math.min(C.num(row[vi]) or 0, max))
    local full = math.floor(v / max * bar_w + 0.5)
    local label = W.pad(C.text(row[li]), label_w)
    local bar = string.rep("█", full) .. string.rep("░", bar_w - full)
    local pct = ("%3d%%"):format(math.floor(v / max * 100 + 0.5))
    lines[i] = label .. "  " .. bar .. "  " .. pct
    local node = bars[i]
    local s = #label + 2
    groups[#groups + 1] = {
      row = i - 1,
      col_s = s,
      col_e = s + #bar,
      group = node and hl.group(style.get(node)) or "DbDashSeries1",
    }
  end
  return { lines = lines, hl = groups }
end

return M
