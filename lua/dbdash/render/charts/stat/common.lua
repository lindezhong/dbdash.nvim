-- Shared parts of the stat (single value, "KPI") chart: which value, its text, the change
-- since the previous refresh and a sparkline of recent values.
local M = {}

M.HISTORY = 20 -- values kept per panel for the sparkline

local NULL = vim.NIL

local function is_numeric(t)
  return t == "integer" or t == "number" or t == "decimal"
end

---The column index of the value: show.value_column, else the first numeric column, else
---the first column.
---@return integer? index, string? err
function M.column(rs, show)
  local name = show.value_column ~= NULL and show.value_column or nil
  if name then
    for i, c in ipairs(rs.columns) do
      if c.name == name then
        return i
      end
    end
    return nil, ("column '%s' not found"):format(name)
  end
  for i, c in ipairs(rs.columns) do
    if is_numeric(c.type) then
      return i
    end
  end
  if #rs.columns > 0 then
    return 1
  end
  return nil, "the query returned no columns"
end

---The value shown: first row of the value column, as a number when it is numeric.
---@return any value, string? err
function M.value(rs, show)
  local idx, err = M.column(rs, show)
  if not idx then
    return nil, err
  end
  local row = rs.rows[1]
  if not row then
    return nil, "the query returned no rows"
  end
  local v = row[idx]
  if type(v) == "cdata" then
    v = tonumber(v)
  elseif type(v) == "string" and tonumber(v) and is_numeric(rs.columns[idx].type) then
    v = tonumber(v) -- decimals arrive as text
  end
  return v
end

---Numeric value of a result for the panel history; nil when not numeric.
function M.track(rs, show)
  local v = M.value(rs, show)
  return type(v) == "number" and v or nil
end

---Text of the value: show.format (Python format), else a compact number; show.unit
---is appended.
function M.text(v, show)
  local fmt = require("dbdash.render.format")
  local s
  if v == nil or v == NULL then
    s = "–"
  elseif type(v) == "number" then
    local f = show.format ~= NULL and show.format or nil
    s = f and fmt.python(v, f) or fmt.number(v)
  else
    s = tostring(v)
  end
  local unit = show.unit ~= NULL and show.unit or nil
  return s, unit and tostring(unit) or nil
end

---Change against the previous value of `history` (oldest first, current last).
---@return { text: string, dir: "up"|"down"|"same" }?
function M.delta(history)
  local n = #history
  if n < 2 then
    return nil
  end
  local cur, prev = history[n], history[n - 1]
  local d = cur - prev
  local dir = d > 0 and "up" or d < 0 and "down" or "same"
  local arrow = ({ up = "↑", down = "↓", same = "=" })[dir]
  local amount
  if prev ~= 0 then
    amount = ("%.1f%%"):format(math.abs(d) / math.abs(prev) * 100)
  else
    amount = require("dbdash.render.format").number(math.abs(d))
  end
  return { text = arrow .. " " .. amount, dir = dir }
end

local BARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

---Sparkline of the last `max` values; nil with fewer than two values.
function M.sparkline(history, max)
  if #history < 2 or max < 2 then
    return nil
  end
  local from = math.max(1, #history - max + 1)
  local lo, hi = math.huge, -math.huge
  for i = from, #history do
    lo, hi = math.min(lo, history[i]), math.max(hi, history[i])
  end
  local out = {}
  for i = from, #history do
    local k = hi > lo and math.floor((history[i] - lo) / (hi - lo) * 7 + 0.5) + 1 or 4
    out[#out + 1] = BARS[k]
  end
  return table.concat(out)
end

return M
