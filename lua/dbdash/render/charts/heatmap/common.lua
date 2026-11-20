-- Heat map helpers: grid extraction and a sequential color scale.
local C = require("dbdash.render.charts.common")
local fmt = require("dbdash.render.format")

local M = {}

-- Sequential scale (viridis-like), low to high.
M.STOPS = { { 0x44, 0x01, 0x54 }, { 0x3b, 0x52, 0x8b }, { 0x21, 0x91, 0x8c }, { 0x5e, 0xc9, 0x62 }, { 0xfd, 0xe7, 0x25 } }
M.LEVELS = 9

---Hex color for t in [0, 1].
function M.hex(t)
  t = math.max(0, math.min(1, t))
  local seg = t * (#M.STOPS - 1)
  local i = math.min(math.floor(seg) + 1, #M.STOPS - 1)
  local f = seg - (i - 1)
  local a, b = M.STOPS[i], M.STOPS[i + 1]
  local rgb = {}
  for k = 1, 3 do
    rgb[k] = math.floor(a[k] + (b[k] - a[k]) * f + 0.5)
  end
  return ("#%02x%02x%02x"):format(rgb[1], rgb[2], rgb[3])
end

---Quantized color level (1..LEVELS) for a value.
function M.level(v, lo, hi)
  if hi == lo then
    return math.ceil(M.LEVELS / 2)
  end
  return math.min(M.LEVELS, math.floor((v - lo) / (hi - lo) * (M.LEVELS - 1) + 0.5) + 1)
end

function M.level_hex(l)
  return M.hex((l - 1) / (M.LEVELS - 1))
end

---Ordered unique keys of a column: numeric columns sort ascending, others keep row order.
local function keys(rs, i)
  local seen, out, numeric = {}, {}, true
  for _, row in ipairs(rs.rows) do
    local v = row[i]
    local k = C.text(v)
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = { key = k, num = C.num(v) }
      numeric = numeric and type(v) == "number"
    end
  end
  if numeric then
    table.sort(out, function(a, b)
      return a.num < b.num
    end)
  end
  local labels = {}
  for j, e in ipairs(out) do
    labels[j] = e.key
  end
  return labels
end

---@return { xs: string[], ys: string[], values: table<string, number>, lo: number, hi: number }
function M.grid(rs, show)
  local xi = C.col(rs, C.nn(show.x_column), "x_column")
  local yi = C.col(rs, C.nn(show.y_column), "y_column")
  local vi = C.col(rs, C.nn(show.value_column), "value_column")
  local values, lo, hi = {}, nil, nil
  for _, row in ipairs(rs.rows) do
    local v = C.num(row[vi])
    if v then
      values[C.text(row[xi]) .. "\0" .. C.text(row[yi])] = v
      lo = math.min(lo or v, v)
      hi = math.max(hi or v, v)
    end
  end
  return { xs = keys(rs, xi), ys = keys(rs, yi), values = values, lo = lo or 0, hi = hi or 0 }
end

function M.get(g, x, y)
  return g.values[x .. "\0" .. y]
end

---Scale legend line appended below the chart.
function M.legend(ctx, out, g, indent)
  local parts, hl = { string.rep(" ", indent) }, {}
  local pos = indent
  local function put(s, group)
    parts[#parts + 1] = s
    if group then
      hl[#hl + 1] = { col_s = pos, col_e = pos + #s, group = group }
    end
    pos = pos + #s
  end
  put(fmt.number(g.lo) .. " ", "DbDashAxis")
  for l = 1, M.LEVELS do
    put("█", ctx.color(M.level_hex(l)))
  end
  put(" " .. fmt.number(g.hi), "DbDashAxis")
  out.lines[#out.lines + 1] = table.concat(parts)
  for _, h in ipairs(hl) do
    h.row = #out.lines - 1
    out.hl[#out.hl + 1] = h
  end
  return out
end

return M
