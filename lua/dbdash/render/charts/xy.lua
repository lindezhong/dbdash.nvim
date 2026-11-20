-- XY plots on a pixel canvas: line, area, scatter and bubble (design §11.1).
local C = require("dbdash.render.charts.common")
local W = require("dbdash.util.width")

local M = {}

local nn = C.nn

---Category axis labels: evenly spaced so they do not collide.
local function category_ticks(labels, cols, n)
  local maxw = 1
  for _, l in ipairs(labels) do
    maxw = math.max(maxw, W.width(l))
  end
  local fit = math.max(1, math.floor(cols / (maxw + 2)))
  local step = math.max(1, math.ceil(n / fit))
  local ticks = {}
  for i = 1, n, step do
    local col = n == 1 and math.floor(cols / 2) or math.floor((i - 1) / (n - 1) * (cols - 1) + 0.5)
    ticks[#ticks + 1] = { col = col, label = labels[i] }
  end
  return ticks
end

local function numeric_ticks(ctx, lo, hi, cols, xformat)
  local fmt = require("dbdash.render.format")
  local values, labels = ctx.ticks(lo, hi, math.max(2, math.min(8, math.floor(cols / 10))))
  local ticks = {}
  for i, v in ipairs(values) do
    local col = math.floor((v - lo) / (hi - lo) * (cols - 1) + 0.5)
    ticks[#ticks + 1] = { col = col, label = xformat and fmt.python(v, xformat) or labels[i] }
  end
  return ticks
end

---Collect the series to plot.
---@return { label: string, group: string, points: { x: number, y: number, size: number?, text: string? }[] }[], dbdash.render.XAxis
local function collect(rs, show, ctx, kind)
  local series = {}
  if kind == "scatter" or kind == "bubble" then
    local xi = C.col(rs, nn(show.x_column), "x_column")
    local yi = C.col(rs, nn(show.y_column), "y_column")
    local si = nn(show.size_column) and C.col(rs, show.size_column, "size_column")
    local ci = nn(show.color_column) and C.col(rs, show.color_column, "color_column")
    local li = nn(show.label_column) and C.col(rs, show.label_column, "label_column")
    local by_cat, order = {}, {}
    for _, row in ipairs(rs.rows) do
      local x, y = C.num(row[xi]), C.num(row[yi])
      if x and y then
        local cat = ci and C.text(row[ci]) or (nn(show.title) and "" or "")
        if not by_cat[cat] then
          by_cat[cat] = {}
          order[#order + 1] = cat
        end
        table.insert(by_cat[cat], {
          x = x,
          y = y,
          size = si and C.num(row[si]) or nil,
          text = li and C.text(row[li]) or nil,
        })
      end
    end
    for i, cat in ipairs(order) do
      series[i] = {
        label = cat ~= "" and cat or nn(show.y_column),
        group = C.color(ctx, show, i, nil, cat),
        points = by_cat[cat],
      }
    end
    return series, { numeric = true }
  end

  local xaxis = C.x_axis(rs, nn(show.x_column))
  for i, s in ipairs(C.series(rs, show)) do
    local pts = {}
    for r, row in ipairs(rs.rows) do
      local x, y = xaxis.values[r], C.num(row[s.index])
      if x and y then
        pts[#pts + 1] = { x = x, y = y }
      end
    end
    if xaxis.numeric then
      table.sort(pts, function(a, b)
        return a.x < b.x
      end)
    end
    series[i] = { label = s.label, group = C.color(ctx, show, i, s.color, s.label), points = pts }
  end
  return series, xaxis
end

---Interpolated y of a polyline at x (points sorted by x), or nil outside.
local function interp(points, x)
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    if x >= a.x and x <= b.x then
      if b.x == a.x then
        return b.y
      end
      return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
    end
  end
  if #points == 1 and points[1].x == x then
    return points[1].y
  end
end

---@param kind "line"|"area"|"scatter"|"bubble"
function M.render(rs, show, ctx, kind)
  local axes = C.axes(show)
  local style = nn(show.style) or {}
  local line_style = nn(show.line_style) or {}
  local stacked = kind == "area" and nn(style.stacked) == true
  local series, xaxis = collect(rs, show, ctx, kind)

  if stacked then -- cumulative values; each layer keeps its base
    for i = 2, #series do
      local below = series[i - 1].points
      for _, p in ipairs(series[i].points) do
        local b = interp(below, p.x) or 0
        p.base = b
        p.y = p.y + b
      end
    end
  end

  -- Data ranges.
  local xlo, xhi, ylo, yhi
  for _, s in ipairs(series) do
    for _, p in ipairs(s.points) do
      xlo = math.min(xlo or p.x, p.x)
      xhi = math.max(xhi or p.x, p.x)
      ylo = math.min(ylo or p.y, p.y)
      yhi = math.max(yhi or p.y, p.y)
    end
  end
  if not xlo then
    return { lines = { "(no data to plot)" }, hl = { { row = 0, col_s = 0, col_e = 17, group = "DbDashMuted" } } }
  end
  if kind == "area" then
    ylo, yhi = math.min(ylo, 0), math.max(yhi, 0)
  end
  ylo, yhi = C.limits(ctx, ylo, yhi, axes.ymin, axes.ymax)
  if xaxis.numeric then
    if xlo == xhi then
      xlo, xhi = xlo - 1, xhi + 1
    end
    xlo, xhi = axes.xmin or xlo, axes.xmax or xhi
  elseif xlo == xhi then
    xlo, xhi = xlo - 0.5, xhi + 0.5
  end

  local legend_pos = C.legend_position(show, #series)
  local legend = {}
  for i, s in ipairs(series) do
    legend[i] = { label = s.label, group = s.group }
  end
  local spec = {
    title = nn(show.title),
    xlabel = axes.xlabel,
    ylabel = axes.ylabel,
    legend = legend,
    legend_position = legend_pos,
    height = ctx.plot_height,
  }
  -- Size the margin with a first set of tick labels, then compute the real ticks.
  local _, labels = C.y_ticks(ctx, ylo, yhi, 15, axes.yformat)
  spec.ylabels = labels
  local cols, rows = ctx.frame.plot_size(ctx, spec)
  spec.yticks, spec.ylabels = C.y_ticks(ctx, ylo, yhi, rows, axes.yformat)
  cols, rows = ctx.frame.plot_size(ctx, spec)

  local canvas = ctx.canvas(cols, rows, { xlo, xhi }, { ylo, yhi })
  local show_points = nn(line_style.show_points)
  local fill = kind == "area" or nn(line_style.fill_area) == true

  for si = #series, 1, -1 do
    local s = series[si]
    local pts = s.points
    if kind == "scatter" then
      for _, p in ipairs(pts) do
        canvas:point(p.x, p.y, s.group)
      end
    elseif kind == "bubble" then
      local smax = 0
      for _, ss in ipairs(series) do
        for _, p in ipairs(ss.points) do
          smax = math.max(smax, math.abs(p.size or 0))
        end
      end
      local rmax = math.max(1, math.min(canvas.px_x * 3, canvas.px_y * 2))
      for _, p in ipairs(pts) do
        local r = smax > 0 and p.size and math.max(1, math.sqrt(math.abs(p.size) / smax) * rmax) or 1
        canvas:circle(p.x, p.y, r, s.group)
        canvas:point(p.x, p.y, s.group)
        if p.text then
          local col = math.floor(canvas:to_px(p.x) / canvas.px_x) + 1
          local row = canvas.rows - 1 - math.floor(canvas:to_py(p.y) / canvas.px_y)
          if col + W.width(p.text) <= canvas.cols then
            canvas:text(row, col, p.text, s.group)
          end
        end
      end
    else
      if fill and #pts > 0 then
        local px_lo = math.floor(canvas:to_px(pts[1].x) + 0.5)
        local px_hi = math.floor(canvas:to_px(pts[#pts].x) + 0.5)
        for px = px_lo, px_hi do
          local x = xlo + (xhi - xlo) * px / math.max(1, canvas:width_px() - 1)
          local y = interp(pts, x)
          if y then
            local base = 0
            if stacked and si > 1 then
              base = interp(series[si - 1].points, x) or 0
            end
            local top = math.floor(canvas:to_py(y) + 0.5)
            local bottom = math.floor(canvas:to_py(math.max(base, ylo)) + 0.5)
            for py = bottom, top do
              canvas:pixel(px, py, s.group)
            end
          end
        end
      end
      for i = 1, #pts - 1 do
        canvas:line(pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y, s.group)
      end
      if #pts == 1 or show_points then
        for _, p in ipairs(pts) do
          canvas:point(p.x, p.y, s.group)
        end
      end
    end
  end

  if xaxis.numeric then
    spec.xticks = numeric_ticks(ctx, xlo, xhi, cols, axes.xformat)
  else
    spec.xticks = category_ticks(xaxis.labels, cols, #xaxis.labels)
  end
  local lines, hl = canvas:render()
  return ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
end

M.interp = interp

return M
