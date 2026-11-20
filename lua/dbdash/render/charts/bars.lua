-- Shared bar drawing for bar charts and histograms.
local C = require("dbdash.render.charts.common")
local W = require("dbdash.util.width")
local fmt = require("dbdash.render.format")

local M = {}

local EIGHTHS_H = { "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" }
local EIGHTHS_V = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

---Horizontal bar of `len` cells (fractional with eighths when `fine`).
local function hbar(len, fine, glyph)
  if not fine then
    return string.rep(glyph or "■", math.floor(len + 0.5))
  end
  local full = math.floor(len)
  local rest = math.floor((len - full) * 8 + 0.5)
  if rest == 8 then
    full, rest = full + 1, 0
  end
  return string.rep("█", full) .. (rest > 0 and EIGHTHS_H[rest] or "")
end

---@class dbdash.render.Bar
---@field label string
---@field value number
---@field group string

---Horizontal bars: one row per bar, labels on the left, values after the bar.
---@param bars dbdash.render.Bar[]
---@param o { title: string?, xlabel: string?, ylabel: string?, show_values: boolean, fine: boolean, glyph: string?, value_format: string? }
function M.horizontal(ctx, bars, o)
  local labels, maxv, minv, vw = {}, 0, 0, 0
  local texts = {}
  for i, b in ipairs(bars) do
    labels[i] = b.label
    maxv = math.max(maxv, b.value)
    minv = math.min(minv, b.value)
    texts[i] = fmt.value(b.value, o.value_format)
    vw = math.max(vw, W.width(texts[i]))
  end
  local spec = {
    title = o.title,
    xlabel = o.xlabel,
    ylabel = o.ylabel,
    ylabels = labels,
    x_axis = false,
    height = #bars,
    min_rows = 1,
  }
  for i, l in ipairs(spec.ylabels) do
    spec.ylabels[i] = W.truncate(l, math.max(8, math.floor(ctx.width / 3)))
  end
  local cols = ctx.frame.plot_size(ctx, spec)
  local room = cols - (o.show_values and (vw + 1) or 0)
  local span = maxv - minv
  local zero = span > 0 and math.floor(-minv / span * room + 0.5) or 0
  local lines, hl, yticks = {}, {}, {}
  for i, b in ipairs(bars) do
    local len = span > 0 and math.abs(b.value) / span * room or 0
    local bar = hbar(len, o.fine, o.glyph)
    local line
    local bw = W.width(bar)
    if b.value < 0 then
      local start = math.max(0, zero - bw)
      line = string.rep(" ", start) .. bar
      hl[#hl + 1] = { row = i - 1, col_s = start, col_e = start + #bar, group = b.group }
      line = line .. string.rep(" ", math.max(0, zero - start - bw))
    else
      line = string.rep(" ", zero) .. bar
      hl[#hl + 1] = { row = i - 1, col_s = zero, col_e = zero + #bar, group = b.group }
    end
    if o.show_values then
      local before = #line
      line = line .. " " .. texts[i]
      hl[#hl + 1] = { row = i - 1, col_s = before + 1, col_e = #line, group = "DbDashNumber" }
    end
    lines[i] = line
    yticks[i] = { row = i - 1, label = spec.ylabels[i] }
  end
  spec.yticks = yticks
  return ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
end

---Vertical bars: columns with eighth-block tops, category labels below.
function M.vertical(ctx, bars, o)
  local maxv = 0
  for _, b in ipairs(bars) do
    maxv = math.max(maxv, b.value)
  end
  local lo, hi = C.limits(ctx, 0, maxv)
  local spec = { title = o.title, xlabel = o.xlabel, ylabel = o.ylabel, height = ctx.plot_height }
  local _, labels = C.y_ticks(ctx, lo, hi, 15, o.value_format)
  spec.ylabels = labels
  local cols, rows = ctx.frame.plot_size(ctx, spec)
  spec.yticks, spec.ylabels = C.y_ticks(ctx, lo, hi, rows, o.value_format)
  cols, rows = ctx.frame.plot_size(ctx, spec)
  local n = math.max(#bars, 1)
  local slot = math.max(1, math.floor(cols / n))
  local bw = math.max(1, slot - (slot > 2 and 1 or 0))
  local grid = {}
  for r = 0, rows - 1 do
    grid[r] = {}
  end
  local hl_cells = {}
  for i, b in ipairs(bars) do
    local h = hi > lo and math.max(0, b.value - lo) / (hi - lo) * rows or 0
    local full = math.floor(h)
    local rest = math.floor((h - full) * 8 + 0.5)
    local c0 = (i - 1) * slot + math.floor((slot - bw) / 2)
    for c = c0, c0 + bw - 1 do
      if c < cols then
        for k = 0, full - 1 do
          grid[rows - 1 - k][c] = "█"
          hl_cells[(rows - 1 - k) * cols + c] = b.group
        end
        if rest > 0 and full < rows then
          grid[rows - 1 - full][c] = EIGHTHS_V[rest]
          hl_cells[(rows - 1 - full) * cols + c] = b.group
        end
      end
    end
    if o.show_values then
      local text = fmt.value(b.value, o.value_format)
      local r = rows - 1 - math.min(full + (rest > 0 and 1 or 0), rows - 1)
      if W.width(text) <= slot and r >= 0 and not grid[r][c0] then
        local start = c0 + math.floor((bw - W.width(text)) / 2)
        local k = 0
        for ch in W.chars(text) do
          if start + k < cols then
            grid[r][start + k] = ch
            hl_cells[r * cols + start + k] = "DbDashNumber"
          end
          k = k + 1
        end
      end
    end
  end
  local lines, hl = {}, {}
  for r = 0, rows - 1 do
    local parts, pos = {}, 0
    for c = 0, cols - 1 do
      local ch = grid[r][c] or " "
      local g = hl_cells[r * cols + c]
      if g then
        hl[#hl + 1] = { row = r, col_s = pos, col_e = pos + #ch, group = g }
      end
      parts[#parts + 1] = ch
      pos = pos + #ch
    end
    lines[#lines + 1] = table.concat(parts)
  end
  -- Label every bar, truncated to its slot; with very narrow slots, label every k-th bar.
  spec.xticks = {}
  local every = slot >= 4 and 1 or math.ceil(4 / slot)
  for i = 1, #bars, every do
    local label = slot >= 4 and W.truncate(bars[i].label, slot - 1) or bars[i].label
    spec.xticks[#spec.xticks + 1] = { col = (i - 1) * slot + math.floor(bw / 2), label = label }
  end
  return ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
end

---Bars from x_column/y_column (bar charts).
function M.from_show(rs, show, ctx)
  local xi = C.col(rs, C.nn(show.x_column), "x_column")
  local s = C.series(rs, show)[1]
  local bars = {}
  for _, row in ipairs(rs.rows) do
    local v = C.num(row[s.index])
    if v then
      local label = C.text(row[xi])
      bars[#bars + 1] = { label = label, value = v, group = C.color(ctx, show, 1, s.color, label) }
    end
  end
  return bars
end

---Histogram bins from value_column; bins defaults to Sturges' rule.
function M.histogram(rs, show, ctx)
  local vi = C.col(rs, C.nn(show.value_column), "value_column")
  local vals = {}
  for _, row in ipairs(rs.rows) do
    local v = C.num(row[vi])
    if v then
      vals[#vals + 1] = v
    end
  end
  if #vals == 0 then
    return {}
  end
  local lo, hi = math.min(unpack(vals)), math.max(unpack(vals))
  local nb = tonumber(C.nn(show.bins)) or math.ceil(math.log(#vals, 2)) + 1
  nb = math.max(1, math.floor(nb))
  if lo == hi then
    nb = 1
  end
  local width = nb > 0 and (hi - lo) / nb or 1
  local counts = {}
  for i = 1, nb do
    counts[i] = 0
  end
  for _, v in ipairs(vals) do
    local b = width > 0 and math.floor((v - lo) / width) + 1 or 1
    b = math.min(math.max(b, 1), nb)
    counts[b] = counts[b] + 1
  end
  local group = C.color(ctx, show, 1)
  local bins = {}
  for i = 1, nb do
    local a, b = lo + (i - 1) * width, lo + i * width
    bins[i] = {
      lower = a,
      label = ("[%s, %s%s"):format(fmt.number(a), fmt.number(b), i == nb and "]" or ")"),
      value = counts[i],
      group = group,
    }
  end
  return bins
end

return M
