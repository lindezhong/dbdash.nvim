-- The boxplot chart type (ARCHITECTURE.md#extending):
-- the spread of values per category.
local content = require("dbdash.render.content.chart")
local C = require("dbdash.render.charts.lib.common")
local nn = require("dbdash.util.null").nn

local M = {
  renderers = { "boxdraw", "vertical" },
  -- series (a box) > value, outlier, mean
  parts = content.parts(function(rs, show)
    local vi = C.col(rs, nn(show.value_column), "value_column")
    local ci = nn(show.category_column) and C.col(rs, show.category_column, "category_column")
    local seen, order = {}, {}
    for _, row in ipairs(rs.rows) do
      if C.num(row[vi]) then
        local cat = ci and C.text(row[ci]) or tostring(nn(show.value_column))
        if not seen[cat] then
          seen[cat] = true
          order[#order + 1] = cat
        end
      end
    end
    return { series = order, legend = {}, boxes = true }
  end),
  style = {
    ["chart.boxplot value"] = { display = "none" }, -- numbers in boxes
    ["mean"] = { display = "none" }, -- box plot means
  },
}

return M
