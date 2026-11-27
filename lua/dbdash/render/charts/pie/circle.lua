-- Pie chart drawn as a filled circle on a pixel canvas (braille by default), with the
-- legend on the right. Each pixel takes the color of the slice its angle falls in
-- (clockwise from 12 o'clock); a character cell shows its last-drawn color, so slice
-- borders are approximate.
local W = require("dbdash.util.width")

local M = { name = "circle" }

local function legend_width(l)
  local w = 0
  for _, x in ipairs(l) do
    w = math.max(w, W.width(x.text))
  end
  return w
end

---The circle's size in cells, and whether the legend fits beside it (else below): the
---height left (at least min-height), then as wide as the room allows.
---@return integer cols, integer rows, boolean beside
local function size(ctx, legend, lw, pos, half)
  local px = ctx.canvas_type.px_per_char
  local function cols_for(r)
    return math.ceil(r * px.y / px.x)
  end
  -- The legend sits right of the circle when a reasonable circle still fits, else below.
  local beside = pos ~= "bottom" and #legend > 0 and cols_for(6) + 3 + lw <= ctx.width
  local room = beside and (ctx.width - 3 - lw) or ctx.width
  local rows = math.min(
    ctx.plot_height or 12,
    (ctx.height - 1 - (beside and 0 or #legend)) * (half and 2 or 1)
  )
  rows = math.max(rows, math.min(ctx.min_plot_height or 3, ctx.plot_height or 12))
  while rows > 3 and cols_for(rows) > room do
    rows = rows - 1
  end
  rows = math.max(rows, 3)
  return cols_for(rows), rows, beside
end

---Fill the circle: each pixel takes the color of the slice its angle falls in (clockwise
---from 12 o'clock); a hole of donut * r; half: the upper half, left to right.
local function fill(canvas, items, sum, donut, half)
  local wpx, hpx = canvas:width_px(), canvas:height_px()
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
      local d2 = dx * dx + dy * dy
      if d2 <= r * r and d2 >= (donut * r) ^ 2 and (not half or dy >= 0) then
        local a = math.atan2(dx, dy) -- 0 at the top, increasing clockwise
        local f
        if half then
          f = (a + math.pi / 2) / math.pi -- left to right over the top
        else
          if a < 0 then
            a = a + 2 * math.pi
          end
          f = a / (2 * math.pi)
        end
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
end

---The total written in the hole of a doughnut (its middle line), when it fits.
local function total_in_hole(ctx, show, sum, body, body_hl, rows, donut)
  local text =
    require("dbdash.render.format").value(sum, show.format ~= vim.NIL and show.format or nil)
  local mid = math.floor(rows / 2) + 1
  local chars = {}
  for ch in W.chars(body[mid]) do
    chars[#chars + 1] = ch
  end
  local start = math.floor((#chars - #text) / 2)
  if start <= 0 or W.width(text) >= #chars * donut then
    return body_hl
  end
  local byte = #table.concat(chars, "", 1, start)
  for k = 1, #text do
    chars[start + k] = text:sub(k, k)
  end
  body[mid] = table.concat(chars)
  body_hl = vim.tbl_filter(function(h)
    return h.row ~= mid - 1
  end, body_hl)
  body_hl[#body_hl + 1] =
    { row = mid - 1, col_s = byte, col_e = byte + #text, group = ctx.css:hl("value") }
  return body_hl
end

---The circle's lines with the legend beside them (vertically centered), the entries that
---do not fit below.
local function with_legend(out, body, body_hl, legend, rows, beside)
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
    out:add(text, spans)
  end
  for i = rows - first + 1, #legend do
    out:add(legend[i].text, legend[i].spans)
  end
end

---Lines with highlight spans ({ col_s, col_e, group }).
local function new_out()
  local out = { lines = {}, hl = {} }
  function out.add(o, s, spans)
    o.lines[#o.lines + 1] = s
    for _, sp in ipairs(spans or {}) do
      o.hl[#o.hl + 1] = { row = #o.lines - 1, col_s = sp[1], col_e = sp[2], group = sp[3] }
    end
  end
  return out
end

function M.render(rs, show, ctx)
  local P = require("dbdash.render.charts.pie.common")
  local items, sum = P.items(rs, show, ctx)
  local out = new_out()
  if #items == 0 then
    out:add("(no positive values to plot)", { { 0, 28, ctx.css:hl("note") } })
    return { lines = out.lines, hl = out.hl }
  end
  local pos = P.legend_position(ctx)
  local legend = pos == "none" and {} or P.legend(items, sum, show, nil, ctx)
  local lw = legend_width(legend)
  -- chart { hole: 0.5 } (a doughnut: the hole's share of the radius), angle: 180 (half)
  local chart = ctx.css:get()
  local donut = math.max(0, math.min(chart.hole or 0, 0.9))
  local half = chart.angle == 180
  if lw > ctx.width then -- shorten labels until the legend fits the window
    legend = P.legend(items, sum, show, math.max(3, 30 - (lw - ctx.width)), ctx)
    lw = legend_width(legend)
  end
  local cols, rows, beside = size(ctx, legend, lw, pos, half)
  local title = P.title(show, math.min(beside and (cols + 3 + lw) or math.max(cols, lw), ctx.width))
  local canvas = ctx.canvas(cols, rows, { 0, 1 }, { 0, 1 })
  fill(canvas, items, sum, donut, half)
  local body, body_hl = canvas:render()
  if half then -- keep the upper half
    local keep = math.ceil(rows / 2)
    body = { unpack(body, 1, keep) }
    body_hl = vim.tbl_filter(function(h)
      return h.row < keep
    end, body_hl)
    rows = keep
  end
  if donut >= 0.5 and not half then
    body_hl = total_in_hole(ctx, show, sum, body, body_hl, rows, donut)
  end
  if title then
    out:add(title.text, title.spans)
  end
  with_legend(out, body, body_hl, legend, rows, beside)
  return { lines = out.lines, hl = out.hl }
end

return M
