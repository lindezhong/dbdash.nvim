-- Line chart drawn with box-drawing characters (after asciichart):
--   ╭─╮
--  ─╯ ╰──
local C = require("dbdash.render.charts.common")

local M = { name = "asciichart" }

function M.render(rs, show, ctx)
  local axes = C.axes(show)
  local xaxis = C.x_axis(rs, C.nn(show.x_column))
  local series = C.series(rs, show)
  local ylo, yhi
  local data = {}
  for i, s in ipairs(series) do
    local vals = {}
    for r, row in ipairs(rs.rows) do
      local v = C.num(row[s.index])
      vals[r] = v
      if v then
        ylo = math.min(ylo or v, v)
        yhi = math.max(yhi or v, v)
      end
    end
    data[i] = { values = vals, group = C.color(ctx, show, i, s.color, s.label), label = s.label }
  end
  if not ylo then
    return { lines = { "(no data to plot)" }, hl = {} }
  end
  ylo, yhi = C.limits(ctx, ylo, yhi, axes.ymin, axes.ymax)
  local legend = {}
  for i, d in ipairs(data) do
    legend[i] = { label = d.label, group = d.group, symbol = "─" }
  end
  local spec = {
    title = C.nn(show.title),
    xlabel = axes.xlabel,
    ylabel = axes.ylabel,
    legend = legend,
    legend_position = C.legend_position(show, #data),
    height = ctx.plot_height,
  }
  local _, labels = C.y_ticks(ctx, ylo, yhi, 15, axes.yformat)
  spec.ylabels = labels
  local cols, rows = ctx.frame.plot_size(ctx, spec)
  spec.yticks, spec.ylabels = C.y_ticks(ctx, ylo, yhi, rows, axes.yformat)
  cols, rows = ctx.frame.plot_size(ctx, spec)

  local grid, colors = {}, {}
  for r = 0, rows - 1 do
    grid[r], colors[r] = {}, {}
  end
  local function put(r, c, ch, g)
    if r >= 0 and r < rows and c >= 0 and c < cols then
      grid[r][c], colors[r][c] = ch, g
    end
  end
  local n = #rs.rows
  local function col_of(i)
    return n == 1 and 0 or math.floor((i - 1) * (cols - 1) / (n - 1) + 0.5)
  end
  local function row_of(v)
    return rows - 1 - math.floor((v - ylo) / (yhi - ylo) * (rows - 1) + 0.5)
  end
  for _, d in ipairs(data) do
    local g = d.group
    for i = 1, n - 1 do
      local a, b = d.values[i], d.values[i + 1]
      if a and b then
        local c0, c1 = col_of(i), col_of(i + 1)
        local r0, r1 = row_of(a), row_of(b)
        local mid = math.floor((c0 + c1) / 2)
        if r0 == r1 then
          for c = c0, c1 do
            put(r0, c, "─", g)
          end
        else
          for c = c0, mid - 1 do
            put(r0, c, "─", g)
          end
          local up = r1 < r0
          put(r0, mid, up and "╯" or "╮", g)
          for r = math.min(r0, r1) + 1, math.max(r0, r1) - 1 do
            put(r, mid, "│", g)
          end
          put(r1, mid, up and "╭" or "╰", g)
          for c = mid + 1, c1 do
            put(r1, c, "─", g)
          end
        end
      elseif a and n == 1 then
        put(row_of(a), 0, "─", g)
      end
    end
  end
  local lines, hl = {}, {}
  for r = 0, rows - 1 do
    local parts, pos = {}, 0
    for c = 0, cols - 1 do
      local ch = grid[r][c] or " "
      if colors[r][c] then
        hl[#hl + 1] = { row = r, col_s = pos, col_e = pos + #ch, group = colors[r][c] }
      end
      parts[#parts + 1] = ch
      pos = pos + #ch
    end
    lines[#lines + 1] = table.concat(parts)
  end
  local labels_x = {}
  local W = require("dbdash.util.width")
  local maxw = 1
  for _, l in ipairs(xaxis.labels) do
    maxw = math.max(maxw, W.width(l))
  end
  local step = math.max(1, math.ceil(n / math.max(1, math.floor(cols / (maxw + 2)))))
  for i = 1, n, step do
    labels_x[#labels_x + 1] = { col = col_of(i), label = xaxis.labels[i] }
  end
  spec.xticks = labels_x
  return ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
end

return M
