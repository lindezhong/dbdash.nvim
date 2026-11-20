-- "Nice" ticks (after uniplot): steps of 1, 2, 2.5 or 5 times a power of ten.
local fmt = require("dbdash.render.format")

local M = { name = "nice" }

local MULTS = { 1, 2, 2.5, 5, 10 }

---Step for a range split into at most `count` intervals.
function M.step(lo, hi, count)
  local raw = (hi - lo) / math.max(count, 1)
  if raw <= 0 then
    return 1
  end
  local mag = 10 ^ math.floor(math.log10(raw))
  for _, m in ipairs(MULTS) do
    if m * mag >= raw - 1e-12 * mag then
      return m * mag
    end
  end
  return 10 * mag
end

local function decimals(step)
  if step >= 1 and step == math.floor(step) then
    return 0
  end
  local d = 0
  local s = step
  while d < 10 and math.abs(s - math.floor(s + 0.5)) > 1e-9 do
    s = s * 10
    d = d + 1
  end
  return d
end

---Expand [lo, hi] to nice bounds.
---@return number lo, number hi, number step
function M.limits(lo, hi, count)
  if lo == hi then
    local pad = lo == 0 and 1 or math.abs(lo) * 0.1
    lo, hi = lo - pad, hi + pad
  end
  local step = M.step(lo, hi, count)
  return math.floor(lo / step + 1e-9) * step, math.ceil(hi / step - 1e-9) * step, step
end

---Tick values and labels within [lo, hi].
---@param lo number
---@param hi number
---@param count integer maximum number of ticks
---@return number[] values, string[] labels
function M.ticks(lo, hi, count)
  if lo == hi then
    return { lo }, { fmt.number(lo) }
  end
  local step = M.step(lo, hi, math.max(count - 1, 1))
  local d = decimals(step)
  local values, labels = {}, {}
  local v = math.ceil(lo / step - 1e-9) * step
  while v <= hi + step * 1e-9 do
    if math.abs(v) < step * 1e-9 then
      v = 0
    end
    values[#values + 1] = v
    labels[#labels + 1] = fmt.number(v, math.abs(v) >= 1e6 and nil or d)
    v = v + step
  end
  return values, labels
end

return M
