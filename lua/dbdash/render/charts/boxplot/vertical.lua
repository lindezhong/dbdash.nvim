-- Vertical box plots (ECharts boxplot, one column per category):
--      ─┬─      whisker cap (whi)
--       │
--     ┌───┐     q3
--     ├───┤     median
--     └───┘     q1
--       │
--      ─┴─      whisker cap (wlo)
-- The options are those of boxdraw: show.whiskers; outlier, mean and value elements.
local C = require("dbdash.render.charts.common")
local W = require("dbdash.util.width")
local boxdraw = require("dbdash.render.charts.boxplot.boxdraw")
local fmt = require("dbdash.render.format")

local M = { name = "vertical" }

---Box i around column c (`row` maps a value to its row): whiskers with caps, box, median,
---mean and outliers, the median beside it when its values show.
local function draw_box(ctx, show, g, i, s, label, c, half, row)
  local group = C.color(ctx, show, i, nil, label)
  -- the box's own value, outlier and mean elements
  local show_means, g_mean = C.item_part(ctx, "series", i, "mean", group)
  local show_outliers, g_out = C.item_part(ctx, "series", i, "outlier", group)
  local show_values, g_value = C.item_part(ctx, "series", i, "value", ctx.css:hl("value"))
  local a, q1, m, q3, b = row(s.wlo), row(s.q1), row(s.median), row(s.q3), row(s.whi)
  for r = b + 1, q3 - 1 do
    g:put(r, c, "│", group)
  end
  for r = q1 + 1, a - 1 do
    g:put(r, c, "│", group)
  end
  for k = -half + 1, half - 1 do
    g:put(b, c + k, "─", group)
    g:put(a, c + k, "─", group)
  end
  g:put(b, c, "┬", group)
  g:put(a, c, "┴", group)
  for r = q3, q1 do
    g:put(r, c - half, "│", group)
    g:put(r, c + half, "│", group)
  end
  for k = -half + 1, half - 1 do
    g:put(q3, c + k, "─", group)
    g:put(q1, c + k, "─", group)
    g:put(m, c + k, "─", group)
  end
  g:put(q3, c - half, "┌", group)
  g:put(q3, c + half, "┐", group)
  g:put(q1, c - half, "└", group)
  g:put(q1, c + half, "┘", group)
  g:put(m, c - half, "├", group)
  g:put(m, c + half, "┤", group)
  if show_means then
    g:put(row(s.mean), c, "+", g_mean)
  end
  if show_outliers then
    for _, v in ipairs(s.outliers) do
      g:put(row(v), c, "•", g_out, true)
    end
  end
  if show_values then -- the median beside the box
    g:text(m, c + half + 2, fmt.number(s.median), g_value, true)
  end
end

function M.render(rs, show, ctx)
  local axes = C.axes(show)
  local order, stats, lo, hi = boxdraw.groups(rs, show)
  if not order then
    return { lines = { "(no data to plot)" }, hl = {} }
  end
  lo, hi = C.limits(ctx, lo, hi, axes.ymin, axes.ymax)
  local spec = { xlabel = axes.xlabel, ylabel = axes.ylabel, height = ctx.plot_height }
  local _, labels = C.y_ticks(ctx, lo, hi, 15, axes.yformat)
  spec.ylabels = labels
  local _, rows = ctx.frame.plot_size(ctx, spec)
  spec.yticks, spec.ylabels = C.y_ticks(ctx, lo, hi, rows, axes.yformat)
  local cols
  cols, rows = ctx.frame.plot_size(ctx, spec)
  local g = require("dbdash.render.charts.grid").new(rows, cols)
  local function row(v)
    return rows - 1 - math.floor((v - lo) / (hi - lo) * (rows - 1) + 0.5)
  end
  local slot = math.max(5, math.floor(cols / #order))
  local half = math.max(1, math.min(3, math.floor((slot - 2) / 2)))
  spec.xticks = {}
  for i, s in ipairs(stats) do
    local c = (i - 1) * slot + math.floor(slot / 2)
    draw_box(ctx, show, g, i, s, order[i], c, half, row)
    spec.xticks[i] = { col = c, label = W.truncate(order[i], slot - 1) }
  end
  return ctx.frame.render(ctx, spec, g:output())
end

return M
