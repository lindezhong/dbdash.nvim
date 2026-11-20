-- "Pie" as one proportional bar plus a legend with values and percentages.
--   ███████████████▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░
--   ■ IT        42   35.0%
local C = require("dbdash.render.charts.common")
local W = require("dbdash.util.width")
local fmt = require("dbdash.render.format")

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
  local style = C.nn(show.style) or {}
  local li = C.col(rs, C.nn(show.label_column), "label_column")
  local vi = C.col(rs, C.nn(show.value_column), "value_column")
  local items, sum = {}, 0
  for _, row in ipairs(rs.rows) do
    local v = C.num(row[vi])
    if v and v > 0 then
      items[#items + 1] = { label = C.text(row[li]), value = v }
      sum = sum + v
    end
  end
  local lines, hl = {}, {}
  local function add(s, spans)
    lines[#lines + 1] = s
    for _, sp in ipairs(spans or {}) do
      hl[#hl + 1] = { row = #lines - 1, col_s = sp[1], col_e = sp[2], group = sp[3] }
    end
  end
  local title = C.nn(show.title)
  local width = math.max(10, ctx.width - 2)
  if title and title ~= "" then
    local t = W.truncate(title, width)
    local pad = math.max(0, math.floor((width - W.width(t)) / 2)) + 1
    add(string.rep(" ", pad) .. t, { { pad, pad + #t, "DbDashTitle" } })
  end
  if #items == 0 then
    add("(no positive values to plot)", { { 0, 28, "DbDashMuted" } })
    return { lines = lines, hl = hl }
  end
  for i, it in ipairs(items) do
    it.group = C.color(ctx, show, i, nil, it.label)
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
  add("")

  local show_labels = C.nn(style.show_labels) ~= false
  local show_values = C.nn(style.show_values) ~= false
  local show_pct = C.nn(style.show_percentages) ~= false
  local lw, vw = 0, 0
  for _, it in ipairs(items) do
    lw = math.max(lw, W.width(it.label))
    vw = math.max(vw, #fmt.number(it.value))
  end
  lw = math.min(lw, 30)
  for _, it in ipairs(items) do
    local b = { " " }
    local p = 1
    local sp = {}
    local function put(s, g)
      if g then
        sp[#sp + 1] = { p, p + #s, g }
      end
      b[#b + 1] = s
      p = p + #s
    end
    put("■", it.group)
    if show_labels then
      put(" " .. W.pad(it.label, lw), "DbDashLabel")
    end
    if show_values then
      put("  " .. W.pad(fmt.number(it.value), vw, "right"), "DbDashNumber")
    end
    if show_pct then
      put(("  %5.1f%%"):format(it.value / sum * 100), "DbDashMuted")
    end
    add(table.concat(b), sp)
  end
  return { lines = lines, hl = hl }
end

return M
