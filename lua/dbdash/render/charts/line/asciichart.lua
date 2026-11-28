-- Line chart drawn with box-drawing characters (after asciichart):
--   ╭─╮
--  ─╯ ╰──
local C = require("dbdash.render.charts.lib.common")
local nn = require("dbdash.util.null").nn

local M = { name = "asciichart" }

---The values of each series by row (nil: no number), with their range (nil: no data).
---@return table[] data, number? ylo, number? yhi
local function series_values(rs, show, ctx)
  local ylo, yhi
  local data = {}
  for i, s in ipairs(C.series(rs, show)) do
    local vals = {}
    for r, row in ipairs(rs.rows) do
      local v = C.num(row[s.index])
      vals[r] = v
      if v then
        ylo = math.min(ylo or v, v)
        yhi = math.max(yhi or v, v)
      end
    end
    data[i] = { values = vals, group = C.color(ctx, show, i, nil, s.label), label = s.label }
  end
  return data, ylo, yhi
end

---The step from (c0, r0) to (c1, r1): flat, or a corner up or down halfway.
local function step(g, c0, r0, c1, r1, group)
  if r0 == r1 then
    for c = c0, c1 do
      g:put(r0, c, "─", group)
    end
    return
  end
  local mid = math.floor((c0 + c1) / 2)
  for c = c0, mid - 1 do
    g:put(r0, c, "─", group)
  end
  local up = r1 < r0
  g:put(r0, mid, up and "╯" or "╮", group)
  for r = math.min(r0, r1) + 1, math.max(r0, r1) - 1 do
    g:put(r, mid, "│", group)
  end
  g:put(r1, mid, up and "╭" or "╰", group)
  for c = mid + 1, c1 do
    g:put(r1, c, "─", group)
  end
end

---x labels, as many as fit at their widest.
local function x_ticks(labels, n, cols, col_of)
  local W = require("dbdash.util.width")
  local maxw = 1
  for _, l in ipairs(labels) do
    maxw = math.max(maxw, W.width(l))
  end
  local every = math.max(1, math.ceil(n / math.max(1, math.floor(cols / (maxw + 2)))))
  local out = {}
  for i = 1, n, every do
    out[#out + 1] = { col = col_of(i), label = labels[i] }
  end
  return out
end

function M.render(rs, show, ctx)
  local axes = C.axes(show)
  local xaxis = C.x_axis(rs, nn(show.x_column))
  local data, ylo, yhi = series_values(rs, show, ctx)
  if not ylo then
    return { lines = { "(no data to plot)" }, hl = {} }
  end
  ylo, yhi = C.limits(ctx, ylo, yhi, axes.ymin, axes.ymax)
  local legend = {}
  for i, d in ipairs(data) do
    legend[i] = { label = d.label, group = d.group, symbol = "─" }
  end
  local spec = {
    xlabel = axes.xlabel,
    ylabel = axes.ylabel,
    legend = legend,
    legend_position = C.legend_position(ctx, #data),
    height = ctx.plot_height,
  }
  local _, labels = C.y_ticks(ctx, ylo, yhi, 15, axes.yformat)
  spec.ylabels = labels
  local _, rows = ctx.frame.plot_size(ctx, spec)
  spec.yticks, spec.ylabels = C.y_ticks(ctx, ylo, yhi, rows, axes.yformat)
  local cols
  cols, rows = ctx.frame.plot_size(ctx, spec)
  local g = require("dbdash.render.charts.lib.grid").new(rows, cols)
  local n = #rs.rows
  local function col_of(i)
    return n == 1 and 0 or math.floor((i - 1) * (cols - 1) / (n - 1) + 0.5)
  end
  local function row_of(v)
    return rows - 1 - math.floor((v - ylo) / (yhi - ylo) * (rows - 1) + 0.5)
  end
  for _, d in ipairs(data) do
    for i = 1, n - 1 do
      local a, b = d.values[i], d.values[i + 1]
      if a and b then
        step(g, col_of(i), row_of(a), col_of(i + 1), row_of(b), d.group)
      elseif a and n == 1 then
        g:put(row_of(a), 0, "─", d.group)
      end
    end
  end
  spec.xticks = x_ticks(xaxis.labels, n, cols, col_of)
  return ctx.frame.render(ctx, spec, g:output())
end

return M
