-- Heat map helpers: grid extraction and a sequential color scale.
local C = require("dbdash.render.charts.lib.common")
local nn = require("dbdash.util.null").nn
local fmt = require("dbdash.render.format")

local M = {}

-- Sequential scale (viridis-like), low to high.
M.STOPS = {
  { 0x44, 0x01, 0x54 },
  { 0x3b, 0x52, 0x8b },
  { 0x21, 0x91, 0x8c },
  { 0x5e, 0xc9, 0x62 },
  { 0xfd, 0xe7, 0x25 },
}
M.LEVELS = 9

---"#rrggbb" -> { r, g, b }, or nil.
local function rgb_of(hex)
  local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
  return r and { tonumber(r, 16), tonumber(g, 16), tonumber(b, 16) } or nil
end

---Hex color for t in [0, 1] along `stops` (default the viridis-like scale).
function M.hex(t, stops)
  stops = stops or M.STOPS
  t = math.max(0, math.min(1, t))
  if #stops == 1 then
    return ("#%02x%02x%02x"):format(stops[1][1], stops[1][2], stops[1][3])
  end
  local seg = t * (#stops - 1)
  local i = math.min(math.floor(seg) + 1, #stops - 1)
  local f = seg - (i - 1)
  local a, b = stops[i], stops[i + 1]
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

function M.level_hex(l, stops)
  return M.hex((l - 1) / (M.LEVELS - 1), stops)
end

---The colors of a heat map (ECharts visualMap): chart { color-scale } (a list of
---"#rrggbb" stops, continuous) or chart { color-steps } (piecewise: [{value, color}], a
---value takes the color of the highest step it reaches); show.scale_min / scale_max (the
---range of the data mapped onto them).
---@return { color: fun(v: number): string?, lo: number, hi: number, stops: table?, steps: table? }
function M.colors(show, g, ctx)
  local chart = ctx.css:get()
  local lo = tonumber(nn(show.scale_min)) or g.lo
  local hi = tonumber(nn(show.scale_max)) or g.hi
  local stops
  local scale = chart["color-scale"]
  if type(scale) == "table" and #scale > 0 then
    stops = {}
    for _, c in ipairs(scale) do
      local rgb = rgb_of(c)
      if not rgb then
        require("dbdash.util.error").raise(
          "render",
          ("color-scale: %q is not a #rrggbb color"):format(tostring(c))
        )
      end
      stops[#stops + 1] = rgb
    end
  end
  local steps = chart["color-steps"]
  if type(steps) == "table" and #steps > 0 then
    local list = {}
    for _, st in ipairs(steps) do
      list[#list + 1] = { value = tonumber(nn(st.value)) or 0, color = nn(st.color) }
    end
    table.sort(list, function(a, b)
      return a.value < b.value
    end)
    return {
      lo = lo,
      hi = hi,
      steps = list,
      color = function(v)
        local c = M.level_hex(1, stops)
        for _, st in ipairs(list) do
          if v >= st.value then
            c = st.color
          end
        end
        return c
      end,
    }
  end
  return {
    lo = lo,
    hi = hi,
    stops = stops,
    color = function(v)
      v = math.max(lo, math.min(hi, v))
      return M.level_hex(M.level(v, lo, hi), stops)
    end,
  }
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

-- grids by result: the DOM build (render/content/chart.lua) and the renderer share one
local grids = setmetatable({}, { __mode = "k" })

---@return { xs: string[], ys: string[], values: table<string, number>, lo: number, hi: number }
function M.grid(rs, show)
  local key = tostring(show.x_column)
    .. "\0"
    .. tostring(show.y_column)
    .. "\0"
    .. tostring(show.value_column)
  local hit = grids[rs]
  if hit and hit.key == key then
    return hit.grid
  end
  local g = M.compute_grid(rs, show)
  grids[rs] = { key = key, grid = g }
  return g
end

function M.compute_grid(rs, show)
  local xi = C.col(rs, nn(show.x_column), "x_column")
  local yi = C.col(rs, nn(show.y_column), "y_column")
  local vi = C.col(rs, nn(show.value_column), "value_column")
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

---Scale legend line appended below the chart (legend { display: none } hides it).
function M.legend(ctx, out, g, indent, scale, show)
  if show and C.legend_position(ctx, 2) == "none" then
    return out
  end
  scale = scale or { lo = g.lo, hi = g.hi }
  local f = show and C.axes(show).yformat or nil
  local parts, hl = { string.rep(" ", indent) }, {}
  local pos = indent
  local function put(s, group)
    parts[#parts + 1] = s
    if group then
      hl[#hl + 1] = { col_s = pos, col_e = pos + #s, group = group }
    end
    pos = pos + #s
  end
  if scale.steps then
    for i, st in ipairs(scale.steps) do
      put((i > 1 and "  " or "") .. "█", ctx.color(st.color))
      put(" ≥" .. fmt.value(st.value, f), ctx.css:hl("legend"))
    end
  else
    put(fmt.value(scale.lo, f) .. " ", ctx.css:hl("axis"))
    for l = 1, M.LEVELS do
      put("█", ctx.color(M.level_hex(l, scale.stops)))
    end
    put(" " .. fmt.value(scale.hi, f), ctx.css:hl("axis"))
  end
  out.lines[#out.lines + 1] = table.concat(parts)
  for _, h in ipairs(hl) do
    h.row = #out.lines - 1
    out.hl[#out.hl + 1] = h
  end
  return out
end

return M
