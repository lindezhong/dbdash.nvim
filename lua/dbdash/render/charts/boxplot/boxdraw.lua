-- Horizontal box plots drawn with box-drawing characters (after UnicodePlots):
--        ╷  ┌────┬───┐    ╷
--    A   ├──┤    │   ├────┤  •
--        ╵  └────┴───┘    ╵
-- Whiskers reach the furthest values within 1.5 IQR (show.whiskers: iqr), the extremes
-- (minmax), or two percentiles ([5, 95]); values beyond are outliers (outlier { display:
-- none } hides them). value { display: block } writes q1, the median and q3 under each box.
local C = require("dbdash.render.charts.common")
local nn = require("dbdash.util.null").nn

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

---The values of each category (category_column, else one box of value_column), in the
---order they come, with their statistics and the range of all values (nil: no data).
---@return string[]? order, table[]? stats, number? lo, number? hi
function M.groups(rs, show)
  local vi = C.col(rs, nn(show.value_column), "value_column")
  local ci = nn(show.category_column) and C.col(rs, show.category_column, "category_column")
  local groups, order = {}, {}
  for _, row in ipairs(rs.rows) do
    local v = C.num(row[vi])
    if v then
      local cat = ci and C.text(row[ci]) or tostring(nn(show.value_column))
      if not groups[cat] then
        groups[cat] = {}
        order[#order + 1] = cat
      end
      table.insert(groups[cat], v)
    end
  end
  if #order == 0 then
    return nil
  end
  local stats, lo, hi = {}, nil, nil
  for i, cat in ipairs(order) do
    stats[i] = M.stats(groups[cat], nn(show.whiskers))
    lo = math.min(lo or stats[i].min, stats[i].min)
    hi = math.max(hi or stats[i].max, stats[i].max)
  end
  return order, stats, lo, hi
end

---Box i on rows top..top+2 (`col` maps a value to its column): whiskers, box, median,
---mean and outliers, and q1, median, q3 under it when its values show.
local function draw_box(ctx, show, g, i, s, label, top, col)
  local group = C.color(ctx, show, i, nil, label)
  local show_means, g_mean = C.item_part(ctx, "series", i, "mean", group)
  local show_outliers, g_out = C.item_part(ctx, "series", i, "outlier", group)
  local box_values, g_value = C.item_part(ctx, "series", i, "value", ctx.css:hl("value"))
  local mid, bot = top + 1, top + 2
  local a, q1, m, q3, b = col(s.wlo), col(s.q1), col(s.median), col(s.q3), col(s.whi)
  for c = a + 1, q1 - 1 do
    g:put(mid, c, "─", group)
  end
  for c = q3 + 1, b - 1 do
    g:put(mid, c, "─", group)
  end
  for c = q1 + 1, q3 - 1 do
    g:put(top, c, "─", group)
    g:put(bot, c, "─", group)
  end
  -- (top, mid, bottom) of the whiskers' ends, the box's sides and the median
  for _, x in ipairs({
    { a, "╷", "├", "╵" },
    { b, "╷", "┤", "╵" },
    { q1, "┌", "┤", "└" },
    { q3, "┐", "├", "┘" },
    { m, "┬", "│", "┴" },
  }) do
    g:put(top, x[1], x[2], group)
    g:put(mid, x[1], x[3], group)
    g:put(bot, x[1], x[4], group)
  end
  if show_means then
    g:put(mid, col(s.mean), "+", g_mean, true)
  end
  if show_outliers then
    for _, v in ipairs(s.outliers) do
      g:put(mid, col(v), "•", g_out, true)
    end
  end
  if box_values then -- q1, median, q3 under the box, where they fit
    local used = -1
    for _, v in ipairs({ s.q1, s.median, s.q3 }) do
      local text = require("dbdash.render.format").number(v)
      local start = math.max(col(v) - math.floor(#text / 2), used + 1)
      if start + #text <= g.cols then
        g:text(bot + 1, start, text, g_value)
        used = start + #text
      end
    end
  end
end

function M.render(rs, show, ctx)
  local axes = C.axes(show)
  local order, stats, lo, hi = M.groups(rs, show)
  if not order then
    return { lines = { "(no data to plot)" }, hl = {} }
  end
  ---@cast stats -nil
  ---@cast lo -nil
  ---@cast hi -nil
  lo, hi = C.limits(ctx, lo, hi, axes.xmin or axes.ymin, axes.xmax or axes.ymax)
  -- each box's value, outlier and mean elements (render/content/chart.lua); the values take
  -- a line under the boxes when any box shows them (hidden by the UA sheet)
  local show_values = false
  for i = 1, #order do
    show_values = show_values or (C.item_part(ctx, "series", i, "value"))
  end
  local rows = #order * 4 - (show_values and 0 or 1)
  local spec = {
    title = nn(show.title),
    xlabel = axes.xlabel or axes.ylabel,
    ylabels = order,
    height = rows,
    min_rows = rows,
  }
  local cols = ctx.frame.plot_size(ctx, spec)
  local g = require("dbdash.render.charts.grid").new(rows, cols)
  local function col(v)
    return math.floor((v - lo) / (hi - lo) * (cols - 1) + 0.5)
  end
  spec.yticks = {}
  for i, s in ipairs(stats) do
    draw_box(ctx, show, g, i, s, order[i], (i - 1) * 4, col)
    spec.yticks[#spec.yticks + 1] = { row = (i - 1) * 4 + 1, label = order[i] }
  end
  local values, labels = ctx.ticks(lo, hi, math.max(2, math.min(8, math.floor(cols / 10))))
  spec.xticks = {}
  for i, v in ipairs(values) do
    spec.xticks[i] = { col = col(v), label = labels[i] }
  end
  return ctx.frame.render(ctx, spec, g:output())
end

return M
