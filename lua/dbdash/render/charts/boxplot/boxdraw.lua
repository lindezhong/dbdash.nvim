-- Horizontal box plots drawn with box-drawing characters (after UnicodePlots):
--        ╷  ┌────┬───┐    ╷
--    A   ├──┤    │   ├────┤  •
--        ╵  └────┴───┘    ╵
-- Whiskers reach the furthest values within 1.5 IQR (style.whiskers: iqr), the extremes
-- (minmax), or two percentiles ([5, 95]); values beyond are outliers. show_values writes
-- q1, the median and q3 under each box.
local C = require("dbdash.render.charts.common")

local M = { name = "boxdraw" }

---Quantile with linear interpolation (numpy's default).
local function quantile(sorted, q)
  local pos = (#sorted - 1) * q + 1
  local lo = math.floor(pos)
  local frac = pos - lo
  if lo >= #sorted then
    return sorted[#sorted]
  end
  return sorted[lo] + (sorted[lo + 1] - sorted[lo]) * frac
end
M.quantile = quantile

---Five-number summary plus outliers and mean. `whiskers`: "iqr" (1.5 IQR, default),
---"minmax", or { lo_percentile, hi_percentile }.
function M.stats(values, whiskers)
  table.sort(values)
  local q1, med, q3 = quantile(values, 0.25), quantile(values, 0.5), quantile(values, 0.75)
  local iqr = q3 - q1
  local lo_fence, hi_fence = q1 - 1.5 * iqr, q3 + 1.5 * iqr
  if whiskers == "minmax" then
    lo_fence, hi_fence = -math.huge, math.huge
  elseif type(whiskers) == "table" then
    lo_fence = quantile(values, (tonumber(whiskers[1]) or 5) / 100)
    hi_fence = quantile(values, (tonumber(whiskers[2]) or 95) / 100)
  end
  local wlo, whi, outliers, sum = nil, nil, {}, 0
  for _, v in ipairs(values) do
    sum = sum + v
    if v < lo_fence or v > hi_fence then
      outliers[#outliers + 1] = v
    else
      wlo = wlo and math.min(wlo, v) or v
      whi = whi and math.max(whi, v) or v
    end
  end
  return {
    q1 = q1,
    median = med,
    q3 = q3,
    wlo = wlo or q1,
    whi = whi or q3,
    min = values[1],
    max = values[#values],
    mean = sum / #values,
    outliers = outliers,
    n = #values,
  }
end

function M.render(rs, show, ctx)
  local style = C.nn(show.style) or {}
  local axes = C.axes(show)
  local vi = C.col(rs, C.nn(show.value_column), "value_column")
  local ci = C.nn(show.category_column) and C.col(rs, show.category_column, "category_column")
  local groups, order = {}, {}
  for _, row in ipairs(rs.rows) do
    local v = C.num(row[vi])
    if v then
      local cat = ci and C.text(row[ci]) or C.nn(show.value_column)
      if not groups[cat] then
        groups[cat] = {}
        order[#order + 1] = cat
      end
      table.insert(groups[cat], v)
    end
  end
  if #order == 0 then
    return { lines = { "(no data to plot)" }, hl = {} }
  end
  local stats, lo, hi = {}, nil, nil
  for i, cat in ipairs(order) do
    stats[i] = M.stats(groups[cat], C.nn(style.whiskers))
    lo = math.min(lo or stats[i].min, stats[i].min)
    hi = math.max(hi or stats[i].max, stats[i].max)
  end
  lo, hi = C.limits(ctx, lo, hi, axes.xmin or axes.ymin, axes.xmax or axes.ymax)

  local show_values = C.nn(style.show_values) == true
  local rows_needed = #order * 4 - (show_values and 0 or 1)
  local spec = {
    title = C.nn(show.title),
    xlabel = axes.xlabel or axes.ylabel,
    ylabels = order,
    height = rows_needed,
    min_rows = rows_needed,
  }
  local cols = ctx.frame.plot_size(ctx, spec)
  local rows = rows_needed
  local grid, colors = {}, {}
  for r = 0, rows - 1 do
    grid[r], colors[r] = {}, {}
  end
  local function col(v)
    return math.floor((v - lo) / (hi - lo) * (cols - 1) + 0.5)
  end
  local function put(r, c, ch, g, only_blank)
    if c >= 0 and c < cols and (not only_blank or not grid[r][c]) then
      grid[r][c], colors[r][c] = ch, g
    end
  end
  local show_outliers = C.nn(style.show_outliers) ~= false
  local show_means = C.nn(style.show_means) == true
  spec.yticks = {}
  for i, s in ipairs(stats) do
    local g = C.color(ctx, show, i, nil, order[i])
    local top = (i - 1) * 4
    local mid, bot = top + 1, top + 2
    local a, q1, m, q3, b = col(s.wlo), col(s.q1), col(s.median), col(s.q3), col(s.whi)
    for c = a + 1, q1 - 1 do
      put(mid, c, "─", g)
    end
    for c = q3 + 1, b - 1 do
      put(mid, c, "─", g)
    end
    for c = q1 + 1, q3 - 1 do
      put(top, c, "─", g)
      put(bot, c, "─", g)
    end
    put(top, a, "╷", g)
    put(mid, a, "├", g)
    put(bot, a, "╵", g)
    put(top, b, "╷", g)
    put(mid, b, "┤", g)
    put(bot, b, "╵", g)
    put(top, q1, "┌", g)
    put(mid, q1, "┤", g)
    put(bot, q1, "└", g)
    put(top, q3, "┐", g)
    put(mid, q3, "├", g)
    put(bot, q3, "┘", g)
    put(top, m, "┬", g)
    put(mid, m, "│", g)
    put(bot, m, "┴", g)
    if show_means then
      put(mid, col(s.mean), "+", g, true)
    end
    if show_outliers then
      for _, v in ipairs(s.outliers) do
        put(mid, col(v), "•", g, true)
      end
    end
    if show_values then -- q1, median, q3 under the box, where they fit
      local used = -1
      for _, v in ipairs({ s.q1, s.median, s.q3 }) do
        local text = require("dbdash.render.format").number(v)
        local start = math.max(col(v) - math.floor(#text / 2), used + 1)
        if start + #text <= cols then
          for k = 1, #text do
            put(bot + 1, start + k - 1, text:sub(k, k), "DbDashNumber")
          end
          used = start + #text
        end
      end
    end
    spec.yticks[#spec.yticks + 1] = { row = mid, label = order[i] }
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
  local values, labels = ctx.ticks(lo, hi, math.max(2, math.min(8, math.floor(cols / 10))))
  spec.xticks = {}
  for i, v in ipairs(values) do
    spec.xticks[i] = { col = col(v), label = labels[i] }
  end
  return ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
end

return M
