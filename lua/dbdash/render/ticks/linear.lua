-- Evenly spaced ticks between the limits.
local fmt = require("dbdash.render.format")

local M = { name = "linear" }

function M.limits(lo, hi)
  if lo == hi then
    local pad = lo == 0 and 1 or math.abs(lo) * 0.1
    return lo - pad, hi + pad, (hi - lo) / 4
  end
  return lo, hi, (hi - lo) / 4
end

function M.ticks(lo, hi, count)
  count = math.max(count, 2)
  local values, labels = {}, {}
  for i = 0, count - 1 do
    local v = lo + (hi - lo) * i / (count - 1)
    values[#values + 1] = v
    labels[#labels + 1] = fmt.number(v)
  end
  return values, labels
end

return M
