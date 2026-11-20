-- Heat map with one character row per y value; cells may show their values.
local C = require("dbdash.render.charts.common")
local H = require("dbdash.render.charts.heatmap.common")
local W = require("dbdash.util.width")
local fmt = require("dbdash.render.format")

local M = { name = "block" }

---Black or white text, whichever contrasts with the background.
local function text_color(hex)
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  return (0.299 * r + 0.587 * g + 0.114 * b) > 140 and "#000000" or "#ffffff"
end

function M.render(rs, show, ctx)
  local g = H.grid(rs, show)
  local axes = C.axes(show)
  local style = C.nn(show.style) or {}
  local spec = { title = C.nn(show.title), xlabel = axes.xlabel, ylabel = axes.ylabel, ylabels = g.ys, height = #g.ys, min_rows = #g.ys }
  local cols = ctx.frame.plot_size(ctx, spec)
  local vw = 0
  if C.nn(style.show_values) == true then
    for _, v in pairs(g.values) do
      vw = math.max(vw, #fmt.number(v))
    end
  end
  local cw = math.max(2, math.min(math.max(6, vw + 1), math.floor(cols / math.max(#g.xs, 1))))
  local show_values = vw > 0 and vw <= cw
  local lines, hl = {}, {}
  for r, y in ipairs(g.ys) do
    local parts, pos = {}, 0
    for _, x in ipairs(g.xs) do
      local v = H.get(g, x, y)
      local s, group
      if v then
        local hex = H.level_hex(H.level(v, g.lo, g.hi))
        if show_values then
          s = W.pad(fmt.number(v), cw, "center")
          group = ctx.color(text_color(hex) .. " on " .. hex)
        else
          s = string.rep("█", cw)
          group = ctx.color(hex)
        end
      else
        s = string.rep(" ", cw)
      end
      if group then
        hl[#hl + 1] = { row = r - 1, col_s = pos, col_e = pos + #s, group = group }
      end
      parts[#parts + 1] = s
      pos = pos + #s
    end
    lines[r] = table.concat(parts)
  end
  spec.yticks = {}
  for r, y in ipairs(g.ys) do
    spec.yticks[r] = { row = r - 1, label = y }
  end
  spec.xticks = {}
  for i, x in ipairs(g.xs) do
    spec.xticks[i] = { col = (i - 1) * cw + math.floor(cw / 2), label = x }
  end
  local out = ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
  local m = 0
  for _, l in ipairs(g.ys) do
    m = math.max(m, W.width(l))
  end
  return H.legend(ctx, out, g, m + 2)
end

return M
