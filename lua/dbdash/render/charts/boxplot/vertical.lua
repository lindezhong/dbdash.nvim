-- Vertical box plots (ECharts boxplot, one column per category):
--      ─┬─      whisker cap (whi)
--       │
--     ┌───┐     q3
--     ├───┤     median
--     └───┘     q1
--       │
--      ─┴─      whisker cap (wlo)
-- The options are those of boxdraw: whiskers, show_outliers, show_means, show_values.
local C = require("dbdash.render.charts.common")
local W = require("dbdash.util.width")
local boxdraw = require("dbdash.render.charts.boxplot.boxdraw")
local fmt = require("dbdash.render.format")

local M = { name = "vertical" }

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
    stats[i] = boxdraw.stats(groups[cat], C.nn(style.whiskers))
    lo = math.min(lo or stats[i].min, stats[i].min)
    hi = math.max(hi or stats[i].max, stats[i].max)
  end
  lo, hi = C.limits(ctx, lo, hi, axes.ymin, axes.ymax)
  local spec = { xlabel = axes.xlabel, ylabel = axes.ylabel, height = ctx.plot_height }
  local _, labels = C.y_ticks(ctx, lo, hi, 15, axes.yformat)
  spec.ylabels = labels
  local cols, rows = ctx.frame.plot_size(ctx, spec)
  spec.yticks, spec.ylabels = C.y_ticks(ctx, lo, hi, rows, axes.yformat)
  cols, rows = ctx.frame.plot_size(ctx, spec)

  local grid, colors = {}, {}
  for r = 0, rows - 1 do
    grid[r], colors[r] = {}, {}
  end
  local function row(v)
    return rows - 1 - math.floor((v - lo) / (hi - lo) * (rows - 1) + 0.5)
  end
  local function put(r, c, ch, g, only_blank)
    if r >= 0 and r < rows and c >= 0 and c < cols and (not only_blank or not grid[r][c]) then
      grid[r][c], colors[r][c] = ch, g
    end
  end
  local slot = math.max(5, math.floor(cols / #order))
  local half = math.max(1, math.min(3, math.floor((slot - 2) / 2)))
  local show_outliers = C.nn(style.show_outliers) ~= false
  local show_means = C.nn(style.show_means) == true
  local show_values = C.nn(style.show_values) == true
  spec.xticks = {}
  for i, s in ipairs(stats) do
    local g = C.color(ctx, show, i, nil, order[i])
    local c = (i - 1) * slot + math.floor(slot / 2)
    local a, q1, m, q3, b = row(s.wlo), row(s.q1), row(s.median), row(s.q3), row(s.whi)
    for r = b + 1, q3 - 1 do
      put(r, c, "│", g)
    end
    for r = q1 + 1, a - 1 do
      put(r, c, "│", g)
    end
    for k = -half + 1, half - 1 do
      put(b, c + k, "─", g)
      put(a, c + k, "─", g)
    end
    put(b, c, "┬", g)
    put(a, c, "┴", g)
    for r = q3, q1 do
      put(r, c - half, "│", g)
      put(r, c + half, "│", g)
    end
    for k = -half + 1, half - 1 do
      put(q3, c + k, "─", g)
      put(q1, c + k, "─", g)
      put(m, c + k, "─", g)
    end
    put(q3, c - half, "┌", g)
    put(q3, c + half, "┐", g)
    put(q1, c - half, "└", g)
    put(q1, c + half, "┘", g)
    put(m, c - half, "├", g)
    put(m, c + half, "┤", g)
    if show_means then
      put(row(s.mean), c, "+", g)
    end
    if show_outliers then
      for _, v in ipairs(s.outliers) do
        put(row(v), c, "•", g, true)
      end
    end
    if show_values then -- the median beside the box
      local text = fmt.number(s.median)
      for k = 1, #text do
        put(m, c + half + 1 + k, text:sub(k, k), ctx.css:hl("value"), true)
      end
    end
    spec.xticks[i] = { col = c, label = W.truncate(order[i], slot - 1) }
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
  return ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
end

return M
