-- "Pie" as one proportional bar plus a legend with values and percentages.
--   ███████████████▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░
--   ■ IT        42   35.0%

local M = { name = "bar" }

---Split `total` cells proportionally (largest remainder), at least 1 per non-zero part.
local function apportion(values, total)
  local sum = 0
  for _, v in ipairs(values) do
    sum = sum + v
  end
  local out, rems, used = {}, {}, 0
  for i, v in ipairs(values) do
    local exact = sum > 0 and v / sum * total or 0
    out[i] = math.floor(exact)
    rems[i] = { i = i, r = exact - out[i] }
    used = used + out[i]
  end
  table.sort(rems, function(a, b)
    return a.r > b.r
  end)
  for k = 1, total - used do
    local e = rems[(k - 1) % #rems + 1]
    out[e.i] = out[e.i] + 1
  end
  return out
end
M.apportion = apportion

function M.render(rs, show, ctx)
  local P = require("dbdash.render.charts.pie.common")
  local items, sum = P.items(rs, show, ctx)
  local lines, hl = {}, {}
  local function add(s, spans, shift)
    lines[#lines + 1] = s
    for _, sp in ipairs(spans or {}) do
      hl[#hl + 1] = { row = #lines - 1, col_s = sp[1] + (shift or 0), col_e = sp[2] + (shift or 0), group = sp[3] }
    end
  end
  local width = math.max(10, ctx.width - 2)
  local title = P.title(show, width)
  if title then
    add(" " .. title.text, title.spans, 1)
  end
  if #items == 0 then
    add("(no positive values to plot)", { { 0, 28, "DbDashMuted" } })
    return { lines = lines, hl = hl }
  end
  local sizes = apportion(vim.tbl_map(function(it)
    return it.value
  end, items), width)
  local parts, spans, pos = { " " }, {}, 1
  for i, it in ipairs(items) do
    local s = string.rep("█", sizes[i])
    spans[#spans + 1] = { pos, pos + #s, it.group }
    parts[#parts + 1] = s
    pos = pos + #s
  end
  add(table.concat(parts), spans)
  add(table.concat(parts), spans)
  if P.legend_position(show) ~= "none" then
    add("")
    for _, l in ipairs(P.legend(items, sum, show)) do
      add(" " .. l.text, l.spans, 1)
    end
  end
  return { lines = lines, hl = hl }
end

return M
