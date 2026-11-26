-- Pie chart drawn as a filled circle on a pixel canvas (braille by default), with the
-- legend on the right. Each pixel takes the color of the slice its angle falls in
-- (clockwise from 12 o'clock); a character cell shows its last-drawn color, so slice
-- borders are approximate.
local W = require("dbdash.util.width")

local M = { name = "circle" }

function M.render(rs, show, ctx)
  local P = require("dbdash.render.charts.pie.common")
  local items, sum = P.items(rs, show, ctx)
  local lines, hl = {}, {}
  local function add(s, spans, shift)
    lines[#lines + 1] = s
    for _, sp in ipairs(spans or {}) do
      hl[#hl + 1] = { row = #lines - 1, col_s = sp[1] + (shift or 0), col_e = sp[2] + (shift or 0), group = sp[3] }
    end
  end
  if #items == 0 then
    add("(no positive values to plot)", { { 0, 28, "DbDashMuted" } })
    return { lines = lines, hl = hl }
  end

  local function legend_width(l)
    local w = 0
    for _, x in ipairs(l) do
      w = math.max(w, W.width(x.text))
    end
    return w
  end
  local legend = P.legend(items, sum, show)
  local lw = legend_width(legend)
  if lw > ctx.width then -- shorten labels until the legend fits the window
    legend = P.legend(items, sum, show, math.max(3, 30 - (lw - ctx.width)))
    lw = legend_width(legend)
  end
  local px = ctx.canvas_type.px_per_char
  local function cols_for(r)
    return math.ceil(r * px.y / px.x)
  end
  -- The legend sits right of the circle when a reasonable circle still fits, else below.
  local beside = cols_for(6) + 3 + lw <= ctx.width
  local room = beside and (ctx.width - 3 - lw) or ctx.width
  -- The height left (at least min_height), then as wide as the room allows.
  local rows = math.min(ctx.plot_height or 12, ctx.height - 1 - (beside and 0 or #legend))
  rows = math.max(rows, math.min(ctx.min_plot_height or 3, ctx.plot_height or 12))
  while rows > 3 and cols_for(rows) > room do
    rows = rows - 1
  end
  rows = math.max(rows, 3)
  local cols = cols_for(rows)
  local block = beside and (cols + 3 + lw) or math.max(cols, lw)
  local title = P.title(show, math.min(block, ctx.width))

  local canvas = ctx.canvas(cols, rows, { 0, 1 }, { 0, 1 })
  local wpx, hpx = cols * px.x, rows * px.y
  local cx, cy = wpx / 2, hpx / 2
  local r = math.min(cx, cy)
  -- Cumulative slice boundaries as fractions of a full turn.
  local bounds, acc = {}, 0
  for i, it in ipairs(items) do
    acc = acc + it.value / sum
    bounds[i] = acc
  end
  for y = 0, hpx - 1 do
    for x = 0, wpx - 1 do
      local dx, dy = x + 0.5 - cx, y + 0.5 - cy
      if dx * dx + dy * dy <= r * r then
        local a = math.atan2(dx, dy) -- 0 at the top, increasing clockwise
        if a < 0 then
          a = a + 2 * math.pi
        end
        local f = a / (2 * math.pi)
        local slice = #items
        for i, b in ipairs(bounds) do
          if f < b then
            slice = i
            break
          end
        end
        canvas:pixel(x, y, items[slice].group)
      end
    end
  end
  local body, body_hl = canvas:render()

  if title then
    add(title.text, title.spans)
  end
  local first = beside and math.max(0, math.floor((rows - #legend) / 2)) or rows
  for i, line in ipairs(body) do
    local text = line
    local spans = {}
    for _, h in ipairs(body_hl) do
      if h.row == i - 1 then
        spans[#spans + 1] = { h.col_s, h.col_e, h.group }
      end
    end
    local l = legend[i - first]
    if l then
      local shift = #text + 3
      text = text .. "   " .. l.text
      for _, sp in ipairs(l.spans) do
        spans[#spans + 1] = { sp[1] + shift, sp[2] + shift, sp[3] }
      end
    end
    add(text, spans)
  end
  -- Legend entries that did not fit beside the circle go below it.
  for i = rows - first + 1, #legend do
    add(legend[i].text, legend[i].spans)
  end
  return { lines = lines, hl = hl }
end

return M
