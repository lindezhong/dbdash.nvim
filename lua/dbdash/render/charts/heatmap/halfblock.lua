-- Heat map with "▀": foreground colors the upper cell, background the lower one, so each
-- character row shows two y values.
local C = require("dbdash.render.charts.lib.common")
local H = require("dbdash.render.charts.heatmap.common")
local W = require("dbdash.util.width")

local M = { name = "halfblock" }

function M.render(rs, show, ctx)
  local g = H.grid(rs, show)
  local scale = H.colors(show, g, ctx)
  local axes = C.axes(show)
  local rows = math.ceil(#g.ys / 2)
  local ylabels = {}
  for r = 1, rows do
    local a, b = g.ys[2 * r - 1], g.ys[2 * r]
    ylabels[r] = b and (a .. "/" .. b) or a
  end
  local spec = {
    xlabel = axes.xlabel,
    ylabel = axes.ylabel,
    ylabels = ylabels,
    height = rows,
    min_rows = rows,
  }
  local cols = ctx.frame.plot_size(ctx, spec)
  local cw = math.max(1, math.min(4, math.floor(cols / math.max(#g.xs, 1))))
  local lines, hl = {}, {}
  local function color_of(x, y)
    local v = y and H.get(g, x, y)
    return v and scale.color(v) or nil
  end
  for r = 1, rows do
    local parts, pos = {}, 0
    for _, x in ipairs(g.xs) do
      local top, bottom = color_of(x, g.ys[2 * r - 1]), color_of(x, g.ys[2 * r])
      local ch, group
      if top and bottom then
        ch, group = "▀", ctx.color(top .. " on " .. bottom)
      elseif top then
        ch, group = "▀", ctx.color(top)
      elseif bottom then
        ch, group = "▄", ctx.color(bottom)
      else
        ch = " "
      end
      local s = string.rep(ch, cw)
      if group then
        hl[#hl + 1] = { row = r - 1, col_s = pos, col_e = pos + #s, group = group }
      end
      parts[#parts + 1] = s
      pos = pos + #s
    end
    lines[r] = table.concat(parts)
  end
  spec.yticks = {}
  for r = 1, rows do
    spec.yticks[r] = { row = r - 1, label = W.truncate(ylabels[r], 16) }
  end
  spec.xticks = {}
  for i, x in ipairs(g.xs) do
    spec.xticks[i] = { col = (i - 1) * cw + math.floor(cw / 2), label = x }
  end
  local out = ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
  local m = 0
  for _, l in ipairs(spec.ylabels) do
    m = math.max(m, W.width(l))
  end
  return H.legend(ctx, out, g, m + 2, scale, show)
end

return M
