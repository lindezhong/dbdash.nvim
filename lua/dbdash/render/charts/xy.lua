-- XY plots on a pixel canvas: line, area, scatter and bubble (design §11.1).
--
-- Options after Chart.js / ECharts: show.span_gaps (false: NULLs break the line),
-- axes.*.scale (log), axes.*.ticks (how many), mark_lines (reference lines: value, mean,
-- min, max), mark_points (max, min), show.stacked (area: true or percent),
-- show.trend_line: linear, show.size_range (bubble radii).
-- Appearance (CSS): series { curve: step | step-before | step-after | step-middle, fill,
-- color } (series:nth-child(N), series.<name>), point { display, content (a marker
-- character) }, grid.x / grid.y { display: block } (grid lines).
local C = require("dbdash.render.charts.common")
local W = require("dbdash.util.width")
local fmt = require("dbdash.render.format")

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
    ticks[#ticks + 1] = { col = col, label = labels[i], value = i }
  end
  return ticks
end

local function numeric_ticks(ctx, lo, hi, cols, xformat, count, log)
  local values, labels
  if log then
    values, labels = C.log_ticks(lo, hi)
  else
    values, labels = ctx.ticks(lo, hi, count or math.max(2, math.min(8, math.floor(cols / 10))))
  end
  local ticks = {}
  for i, v in ipairs(values) do
    local col = math.floor((v - lo) / (hi - lo) * (cols - 1) + 0.5)
    local label = xformat and fmt.python(log and 10 ^ v or v, xformat) or labels[i]
    ticks[#ticks + 1] = { col = col, label = label, value = v }
  end
  return ticks
end

---@class dbdash.render.PlotPoint
---@field x number
---@field y number
---@field size number?
---@field text string?
---@field brk boolean? a gap in the line before this point

---@class dbdash.render.PlotSeries
---@field label string
---@field group string
---@field points dbdash.render.PlotPoint[]

---Collect the series to plot.
---@return dbdash.render.PlotSeries[] series
---@return dbdash.render.XAxis xaxis
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
        local cat = ci and C.text(row[ci]) or ""
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

  if nn(show.series_column) then -- long data: one series per value of series_column
    local xaxis, long = C.long(rs, show)
    for i, s in ipairs(long) do
      if xaxis.numeric then
        table.sort(s.points, function(a, b)
          return a.x < b.x
        end)
      end
      series[i] =
        { label = s.label, group = C.color(ctx, show, i, nil, s.label), points = s.points }
    end
    return series, xaxis
  end
  local span_gaps = nn(show.span_gaps) ~= false
  local xaxis = C.x_axis(rs, nn(show.x_column))
  for i, s in ipairs(C.series(rs, show)) do
    local pts, gap = {}, false
    for r, row in ipairs(rs.rows) do
      local x, y = xaxis.values[r], C.num(row[s.index])
      if x and y then
        pts[#pts + 1] = { x = x, y = y, brk = gap or nil }
        gap = false
      elseif x and not span_gaps and #pts > 0 then
        gap = true -- Chart.js spanGaps: false: a NULL breaks the line
      end
    end
    if xaxis.numeric then
      table.sort(pts, function(a, b)
        return a.x < b.x
      end)
    end
    series[i] = { label = s.label, group = C.color(ctx, show, i, nil, s.label), points = pts }
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

local function log10(v)
  return v > 0 and math.log10(v) or nil
end

---Least-squares line y = a + b x through the points, or nil.
local function regression(pts)
  local n, sx, sy, sxx, sxy = #pts, 0, 0, 0, 0
  if n < 2 then
    return nil
  end
  for _, p in ipairs(pts) do
    sx, sy, sxx, sxy = sx + p.x, sy + p.y, sxx + p.x * p.x, sxy + p.x * p.y
  end
  local d = n * sxx - sx * sx
  if d == 0 then
    return nil
  end
  local b = (n * sxy - sx * sy) / d
  return (sy - b * sx) / n, b
end

---Draw one segment a -> b, stepped or straight.
local function segment(canvas, a, b, mode, group)
  if not mode then
    canvas:line(a.x, a.y, b.x, b.y, group)
  elseif mode == "after" then
    canvas:line(a.x, a.y, b.x, a.y, group)
    canvas:line(b.x, a.y, b.x, b.y, group)
  elseif mode == "middle" then
    local m = (a.x + b.x) / 2
    canvas:line(a.x, a.y, m, a.y, group)
    canvas:line(m, a.y, m, b.y, group)
    canvas:line(m, b.y, b.x, b.y, group)
  else -- true / "before": the value changes at the start of the step
    canvas:line(a.x, a.y, a.x, b.y, group)
    canvas:line(a.x, b.y, b.x, b.y, group)
  end
end

---A text label in the canvas at (row, col), moved left so it fits.
local function label_at(canvas, row, col, text, group)
  col = math.max(0, math.min(col, canvas.cols - W.width(text)))
  canvas:text(row, col, text, group)
end

---@param kind "line"|"area"|"scatter"|"bubble"
function M.render(rs, show, ctx, kind)
  local axes = C.axes(show)
  local stacked = kind == "area" and nn(show.stacked)
  stacked = (stacked == true or stacked == "percent") and stacked or false
  local series, xaxis = collect(rs, show, ctx, kind)
  local ylog = axes.yscale == "log"
  local xlog = xaxis.numeric and axes.xscale == "log"

  -- The real values, before stacking or log scales (for mark_lines / mark_points).
  local all_y = {}
  for _, s in ipairs(series) do
    for _, p in ipairs(s.points) do
      all_y[#all_y + 1] = p.y
      p.real = p.y
    end
  end

  if stacked == "percent" then -- every x sums to 100 (ECharts 100% stacking)
    local total = {}
    for _, s in ipairs(series) do
      for _, p in ipairs(s.points) do
        total[p.x] = (total[p.x] or 0) + p.y
      end
    end
    for _, s in ipairs(series) do
      for _, p in ipairs(s.points) do
        p.y = total[p.x] ~= 0 and p.y / total[p.x] * 100 or 0
      end
    end
  end
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
  if ylog or xlog then -- plot log10 of the values; non-positive values cannot be shown
    for _, s in ipairs(series) do
      local kept = {}
      for _, p in ipairs(s.points) do
        p.y = ylog and log10(p.y) or p.y
        p.x = xlog and log10(p.x) or p.x
        if p.x and p.y then
          kept[#kept + 1] = p
        end
      end
      s.points = kept
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
    return {
      lines = { "(no data to plot)" },
      hl = { { row = 0, col_s = 0, col_e = 17, group = ctx.css:hl("note") } },
    }
  end
  if kind == "area" and not ylog then
    ylo, yhi = math.min(ylo, 0), math.max(yhi, 0)
  end
  if ylog then
    ylo = axes.ymin and log10(axes.ymin) or math.floor(ylo)
    yhi = axes.ymax and log10(axes.ymax) or math.ceil(yhi)
    if ylo == yhi then
      yhi = ylo + 1
    end
  else
    ylo, yhi = C.limits(ctx, ylo, yhi, axes.ymin, axes.ymax)
  end
  if xaxis.numeric then
    if xlog then
      xlo = axes.xmin and log10(axes.xmin) or math.floor(xlo)
      xhi = axes.xmax and log10(axes.xmax) or math.ceil(xhi)
    else
      xlo, xhi = axes.xmin or xlo, axes.xmax or xhi
    end
    if xlo == xhi then
      xlo, xhi = xlo - 1, xhi + 1
    end
  elseif xlo == xhi then
    xlo, xhi = xlo - 0.5, xhi + 0.5
  end

  local legend_pos = C.legend_position(ctx, #series)
  local legend = {}
  for i, s in ipairs(series) do
    legend[i] =
      { label = s.label, group = s.group, label_group = C.item_hl(ctx, "legend", i, "legend") }
  end
  local spec = {
    xlabel = axes.xlabel,
    ylabel = axes.ylabel,
    legend = legend,
    legend_position = legend_pos,
    height = ctx.plot_height,
  }
  -- Size the margin with a first set of tick labels, then compute the real ticks.
  local _, labels = C.y_ticks(ctx, ylo, yhi, 15, axes.yformat, axes.yticks, ylog)
  spec.ylabels = labels
  local _, rows = ctx.frame.plot_size(ctx, spec)
  local yticks
  yticks, spec.ylabels = C.y_ticks(ctx, ylo, yhi, rows, axes.yformat, axes.yticks, ylog)
  spec.yticks = yticks
  local cols
  cols, rows = ctx.frame.plot_size(ctx, spec)
  if xaxis.numeric then
    spec.xticks = numeric_ticks(ctx, xlo, xhi, cols, axes.xformat, axes.xticks, xlog)
  else
    spec.xticks = category_ticks(xaxis.labels, cols, #xaxis.labels)
  end

  local canvas = ctx.canvas(cols, rows, { xlo, xhi }, { ylo, yhi })

  -- Grid lines first, so the data is drawn over them (Chart.js grid.display).
  local grid_hl = ctx.css:hl("grid")
  if ctx.css:get("grid", { classes = { "y" } }).display ~= "none" then
    for _, t in ipairs(spec.yticks or {}) do
      local py = (rows - 1 - t.row) * canvas.px_y + math.floor(canvas.px_y / 2)
      for px = 0, canvas:width_px() - 1, 4 do
        canvas:pixel(px, py, grid_hl)
      end
    end
  end
  if ctx.css:get("grid", { classes = { "x" } }).display ~= "none" then
    for _, t in ipairs(spec.xticks or {}) do
      local px = t.col * canvas.px_x + math.floor(canvas.px_x / 2)
      for py = 0, canvas:height_px() - 1, 4 do
        canvas:pixel(px, py, grid_hl)
      end
    end
  end

  -- point markers, each series' own point element: content is the marker character; on
  -- lines and areas they show with display: block (hidden by the UA sheet), scatter and
  -- bubble always draw them
  local show_points, marker
  local size_range = nn(show.size_range)
  local CURVE = {
    step = "before",
    ["step-before"] = "before",
    ["step-after"] = "after",
    ["step-middle"] = "middle",
  }

  local function mark(p, group)
    local row, col = canvas:cell_of(p.x, p.y)
    canvas:text(row, col, marker, group)
  end

  for si = #series, 1, -1 do
    local s = series[si]
    local pts = s.points
    local sc = C.item_style(ctx, "series", si, "series")
    local point = C.item_style(ctx, "series", si, "point", "point")
    show_points = point.display ~= "none"
    marker = point.content
    if kind == "line" or kind == "area" then
      marker = show_points and marker or nil
    end
    local fill = kind == "area" or sc.fill == true
    local stepped = CURVE[sc.curve]
    if kind == "scatter" then
      for _, p in ipairs(pts) do
        if marker then
          mark(p, s.group)
        else
          canvas:point(p.x, p.y, s.group)
        end
      end
    elseif kind == "bubble" then
      local smax = 0
      for _, ss in ipairs(series) do
        for _, p in ipairs(ss.points) do
          smax = math.max(smax, math.abs(p.size or 0))
        end
      end
      local rmax = math.max(1, math.min(canvas.px_x * 3, canvas.px_y * 2))
      local function radius(f)
        if type(size_range) == "table" then -- Chart.js radius range, in canvas pixels
          local lo, hi = tonumber(size_range[1]) or 1, tonumber(size_range[2]) or rmax
          return lo + (hi - lo) * f
        end
        return math.max(1, f * rmax)
      end
      for _, p in ipairs(pts) do
        local f = smax > 0 and p.size and math.sqrt(math.abs(p.size) / smax) or 0
        canvas:circle(p.x, p.y, radius(f), s.group)
        if marker then
          mark(p, s.group)
        else
          canvas:point(p.x, p.y, s.group)
        end
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
        if not pts[i + 1].brk then
          segment(canvas, pts[i], pts[i + 1], stepped, s.group)
        end
      end
      if marker then
        for _, p in ipairs(pts) do
          mark(p, s.group)
        end
      elseif #pts == 1 or show_points then
        for _, p in ipairs(pts) do
          canvas:point(p.x, p.y, s.group)
        end
      end
    end
    if nn(show.trend_line) == "linear" then -- ECharts regression: a dashed fit per series
      local a, b = regression(pts)
      if a then
        canvas:line(xlo, a + b * xlo, xhi, a + b * xhi, s.group, 2)
      end
    end
  end

  -- Reference lines (ECharts markLine): a value, or the mean / min / max of the data.
  local function stat_of(what)
    if #all_y == 0 then
      return nil
    end
    if what == "mean" or what == "average" then
      local sum = 0
      for _, v in ipairs(all_y) do
        sum = sum + v
      end
      return sum / #all_y
    elseif what == "min" then
      return math.min(unpack(all_y))
    elseif what == "max" then
      return math.max(unpack(all_y))
    end
  end
  for k, m in ipairs(nn(show.mark_lines) or {}) do
    local group = C.item_hl(ctx, "marks", k, "mark")
      or ctx.css:hl("mark", { classes = nn(m.class) and { m.class } or nil })
    local axis = nn(m.axis) or "y"
    local v = nn(m.value)
    if axis == "x" then
      local x
      if not xaxis.numeric then -- a category: its label
        for i, l in ipairs(xaxis.labels or {}) do
          if l == tostring(v) then
            x = i
          end
        end
      else
        x = tonumber(v)
      end
      if x and xlog then
        x = log10(x)
      end
      if x then
        canvas:line(x, ylo, x, yhi, group, 2)
        if nn(m.label) then
          local _, col = canvas:cell_of(x, yhi)
          label_at(canvas, 0, col + 1, m.label, group)
        end
      end
    else
      local real = tonumber(v) or stat_of(v)
      local y = real and (ylog and log10(real) or real)
      if y then
        canvas:line(xlo, y, xhi, y, group, 2)
        local text = nn(m.label)
          or (type(v) == "string" and ("%s %s"):format(v, fmt.number(real)))
          or nil
        if text then
          local row = canvas:cell_of(xhi, y)
          label_at(canvas, math.max(row - 1, 0), canvas.cols, text, group)
        end
      end
    end
  end
  -- Marked points (ECharts markPoint): each series' max / min with its value.
  for _, what in ipairs(nn(show.mark_points) or {}) do
    for _, s in ipairs(series) do
      local best
      for _, p in ipairs(s.points) do
        if
          not best
          or (what == "max" and p.real > best.real)
          or (what == "min" and p.real < best.real)
        then
          best = p
        end
      end
      if best then
        local row, col = canvas:cell_of(best.x, best.y)
        local text = (what == "max" and "▲" or "▼") .. fmt.number(best.real)
        -- above the max and below the min, or the other side at the plot's edge
        local up = what == "max"
        if (up and row == 0) or (not up and row == canvas.rows - 1) then
          up = not up
        end
        label_at(canvas, up and row - 1 or row + 1, col, text, s.group)
      end
    end
  end

  local lines, hl = canvas:render()
  return ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
end

M.interp = interp

return M
