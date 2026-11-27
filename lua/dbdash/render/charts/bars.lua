-- Shared bar drawing for bar charts and histograms.
--
-- Bars are categories with one segment per series. Options after Chart.js / ECharts:
--   show.stacked     true: segments on top of each other (default: side by side)
--   show.sort        asc / desc (by value, or total when stacked)
--   show.top         keep the first N categories (after sorting)
-- Appearance (CSS):
--   bar   width (vertical: columns per bar; horizontal: lines per bar), gap (between
--         categories)
--   value display: none hides the values; position: inside puts them in the bar end
--   axes.y_axis.min_value / max_value   the value axis (the baseline of the bars)
--   mark_lines       reference lines on the value axis (a value, mean, min, max)
local C = require("dbdash.render.charts.common")
local W = require("dbdash.util.width")
local fmt = require("dbdash.render.format")

local M = {}

local nn = require("dbdash.util.null").nn

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
---@field segments { value: number, group: string, series: string? }[]?

---Every bar's segments (a plain bar is one segment).
local function segments(b)
  return b.segments or { { value = b.value, group = b.group, item = b.item } }
end

---A bar's element (render/content/chart.lua: bar[category][series], in result order).
local function bar_node(ctx, k)
  return k and require("dbdash.render.content.find").item(ctx.css.node, "bars", k) or nil
end

---The color of a bar: its own element's (bar.<category>, bar[category=...]), else its
---series'.
local function bar_group(ctx, k, series_group)
  local node = bar_node(ctx, k)
  local own = node and require("dbdash.css.style").get(node).color
  if node and own then
    return require("dbdash.css").hl_of(node)
  end
  return series_group
end

---The group of a segment's value label, or false when its value element is hidden.
local function value_group(ctx, seg)
  local node = require("dbdash.render.content.find").child(bar_node(ctx, seg and seg.item), "value")
  if not node then
    return ctx.css:hl("value")
  end
  if require("dbdash.css.style").get(node).display == "none" then
    return false
  end
  return require("dbdash.css").hl_of(node)
end

---The values shown along the value axis, and their range.
local function value_range(bars, stacked, axes)
  local lo, hi, all = 0, 0, {}
  for _, b in ipairs(bars) do
    local pos, neg = 0, 0
    for _, s in ipairs(segments(b)) do
      all[#all + 1] = s.value
      if stacked then
        if s.value >= 0 then
          pos = pos + s.value
        else
          neg = neg + s.value
        end
      else
        lo, hi = math.min(lo, s.value), math.max(hi, s.value)
      end
    end
    if stacked then
      lo, hi = math.min(lo, neg), math.max(hi, pos)
    end
  end
  if axes then
    lo, hi = axes.ymin or lo, axes.ymax or hi
  end
  return lo, hi, all
end

---Reference line values (numbers, or mean / min / max of `all`).
local function mark_values(marks, all)
  local out = {}
  for k, m in ipairs(marks or {}) do
    local v = nn(m.value)
    local x = tonumber(v)
    if not x and #all > 0 then
      if v == "mean" or v == "average" then
        local s = 0
        for _, a in ipairs(all) do
          s = s + a
        end
        x = s / #all
      elseif v == "min" then
        x = math.min(unpack(all))
      elseif v == "max" then
        x = math.max(unpack(all))
      end
    end
    if x then
      out[#out + 1] = {
        value = x,
        label = nn(m.label) or (type(v) == "string" and ("%s %s"):format(v, fmt.number(x))),
        class = nn(m.class),
        index = k,
      }
    end
  end
  return out
end

---The group of the k-th mark line: its element's color (mark.<class>, mark[label=...]).
local function mark_group(ctx, m)
  return C.item_hl(ctx, "marks", m.index, "mark")
    or ctx.css:hl("mark", { classes = m.class and { m.class } or nil })
end
M.mark_group = mark_group

---@class dbdash.render.charts.bars.HorizontalOpts
---@field title string?
---@field xlabel string?
---@field ylabel string?
---@field show_values boolean
---@field fine boolean
---@field glyph string?
---@field value_format string?
---@field stacked boolean?
---@field bar_width integer?
---@field bar_gap integer?
---@field inside boolean?
---@field axes table?
---@field marks table?
---@field legend table?
---@field legend_position string?

---The rows of horizontal bars: every segment (grouped) or bar (stacked), `thick` lines
---each, `gap` blank rows between bars.
local function bar_rows(bars, stacked, thick, gap)
  local rows = {}
  for bi, b in ipairs(bars) do
    if bi > 1 then
      for _ = 1, gap do
        rows[#rows + 1] = { blank = true }
      end
    end
    local segs = segments(b)
    local groups = stacked and { segs } or vim.tbl_map(function(s)
      return { s }
    end, segs)
    for gi, g in ipairs(groups) do
      for k = 1, thick do
        rows[#rows + 1] =
          { bar = b, segs = g, label = (gi == 1 and k == 1) and b.label or "", first = k == 1 }
      end
    end
  end
  return rows
end

---One row of horizontal bars (`g`: { zero, span, room, stacked }): its segments from the
---zero column (negative ones to the left), then its value after the bar or inside its end.
---@return string line
local function bar_line(ctx, g, r, i, text, o, hl)
  local line = ""
  local cursor_pos, cursor_neg = g.zero, g.zero
  local cells = {} -- { start, text, group }
  for _, s in ipairs(r.segs) do
    local len = g.span > 0 and math.abs(s.value) / g.span * g.room or 0
    local bar = hbar(len, o.fine, o.glyph)
    local bw = W.width(bar)
    local start
    if s.value < 0 then
      start = math.max(0, (g.stacked and cursor_neg or g.zero) - bw)
      cursor_neg = start
    else
      start = g.stacked and cursor_pos or g.zero
      cursor_pos = start + bw
    end
    cells[#cells + 1] = { start, bar, s.group }
  end
  table.sort(cells, function(a, b)
    return a[1] < b[1]
  end)
  local pos = 0
  for _, c in ipairs(cells) do
    if c[1] > pos then
      line = line .. string.rep(" ", c[1] - pos)
      pos = c[1]
    end
    local before = #line
    line = line .. c[2]
    hl[#hl + 1] = { row = i - 1, col_s = before, col_e = #line, group = c[3] }
    pos = pos + W.width(c[2])
  end
  local vg = o.show_values and r.first and text and value_group(ctx, r.segs[1])
  if not vg then
    return line
  end
  if o.inside and pos >= W.width(text) + 1 then
    -- the value inside the end of the bar (ECharts label.position: insideRight)
    local keep = W.truncate(line, pos - W.width(text) - 1, "")
    line = keep .. " " .. text
    hl[#hl + 1] = { row = i - 1, col_s = #keep, col_e = #line, group = vg, priority = 110 }
  else
    local before = #line
    line = line .. " " .. text
    hl[#hl + 1] = { row = i - 1, col_s = before + 1, col_e = #line, group = vg }
  end
  return line
end

---A column of ┆ at column `c` down the bar lines: after a shorter line, or over a blank.
local function mark_column(lines, hl, c, group)
  for i = 1, #lines do
    local l = lines[i]
    local w = W.width(l)
    if w <= c then
      local add = string.rep(" ", c - w) .. "┆"
      hl[#hl + 1] = { row = i - 1, col_s = #l + #add - #"┆", col_e = #l + #add, group = group }
      lines[i] = l .. add
    elseif W.width(W.truncate(l, c, "")) == c then
      -- over a blank (or the end of a value): replace the cell at c
      local head = W.truncate(l, c, "")
      local rest = l:sub(#head + 1)
      local ch = rest:match("^[%z\1-\127\194-\244][\128-\191]*") or ""
      if ch == " " then
        lines[i] = head .. "┆" .. rest:sub(2)
        for _, h in ipairs(hl) do
          if h.row == i - 1 and h.col_s > #head then
            h.col_s, h.col_e = h.col_s + #"┆" - 1, h.col_e + #"┆" - 1
          end
        end
        hl[#hl + 1] = { row = i - 1, col_s = #head, col_e = #head + #"┆", group = group }
      end
    end
  end
end

---Reference lines of horizontal bars: a column of ┆ at each value, their labels on a line
---below the bars (added to `lines`; returns whether it was).
local function horizontal_marks(ctx, lines, hl, marks, col_of)
  table.sort(marks, function(a, b)
    return a.value < b.value
  end)
  local label_line, label_hl = "", {}
  for _, m in ipairs(marks) do
    local c = col_of(m.value)
    local group = mark_group(ctx, m)
    mark_column(lines, hl, c, group)
    if m.label then
      local at = math.max(
        W.width(label_line) + (label_line ~= "" and 1 or 0),
        c - math.floor(W.width(m.label) / 2)
      )
      local before = label_line .. string.rep(" ", at - W.width(label_line))
      label_line = before .. m.label
      label_hl[#label_hl + 1] = { col_s = #before, col_e = #label_line, group = group }
    end
  end
  if label_line == "" then
    return false
  end
  lines[#lines + 1] = label_line
  for _, h in ipairs(label_hl) do
    hl[#hl + 1] = { row = #lines - 1, col_s = h.col_s, col_e = h.col_e, group = h.group }
  end
  return true
end

---Horizontal bars: one row (or bar_width rows) per bar, labels on the left, values after.
---@param bars dbdash.render.Bar[]
---@param o dbdash.render.charts.bars.HorizontalOpts
function M.horizontal(ctx, bars, o)
  local stacked = o.stacked
  local gap = math.max(
    0,
    o.bar_gap or ((not stacked and #(bars[1] and segments(bars[1]) or {}) > 1) and 1 or 0)
  )
  local minv, maxv, all = value_range(bars, stacked, o.axes)
  local rows = bar_rows(bars, stacked, math.max(1, o.bar_width or 1), gap)
  local labels, vw, texts = {}, 0, {}
  for i, r in ipairs(rows) do
    labels[i] = r.label or ""
    if r.segs and r.first then
      local total = 0
      for _, s in ipairs(r.segs) do
        total = total + s.value
      end
      texts[i] = fmt.value(total, o.value_format)
      vw = math.max(vw, W.width(texts[i]))
    end
  end
  local spec = {
    title = o.title,
    xlabel = o.xlabel,
    ylabel = o.ylabel,
    ylabels = labels,
    x_axis = false,
    height = math.max(#rows, 1),
    min_rows = math.max(#rows, 1),
    legend = o.legend,
    legend_position = o.legend_position,
  }
  for i, l in ipairs(spec.ylabels) do
    spec.ylabels[i] = W.truncate(l, math.max(8, math.floor(ctx.width / 3)))
  end
  local cols = ctx.frame.plot_size(ctx, spec)
  local g = {
    stacked = stacked,
    span = maxv - minv,
    room = cols - ((o.show_values and not o.inside) and (vw + 1) or 0),
  }
  local function col_of(v)
    return g.span > 0 and math.floor((v - minv) / g.span * g.room + 0.5) or 0
  end
  g.zero = col_of(math.max(minv, math.min(0, maxv)))
  local lines, hl, yticks = {}, {}, {}
  for i, r in ipairs(rows) do
    lines[i] = r.segs and bar_line(ctx, g, r, i, texts[i], o, hl) or ""
    if labels[i] ~= "" then
      yticks[#yticks + 1] = { row = i - 1, label = spec.ylabels[i] }
    end
  end
  -- The plot spans the whole value axis (max_value may be past the longest bar).
  if o.axes and (o.axes.ymax or o.axes.ymin) then
    for i, l in ipairs(lines) do
      lines[i] = l .. string.rep(" ", math.max(0, cols - W.width(l)))
    end
  end
  if horizontal_marks(ctx, lines, hl, mark_values(o.marks, all), col_of) then
    spec.min_rows = #lines
  end
  spec.yticks = yticks
  return ctx.frame.render(ctx, spec, { lines = lines, hl = hl })
end

---Fill column c from `from` (rows of height, float) to `to`: full blocks, an eighth on top.
local function fill(g, c, from, to, group)
  local rows = g.rows
  local full_from, full_to = math.floor(from + 0.5), math.floor(to)
  for k = full_from, full_to - 1 do
    g:put(rows - 1 - k, c, "█", group)
  end
  local rest = math.floor((to - full_to) * 8 + 0.5)
  if rest > 0 and full_to < rows and full_to >= full_from then
    g:put(rows - 1 - full_to, c, EIGHTHS_V[rest], group)
  end
end

---Text from (r, start) on, a character (of any width) per cell.
local function put_text(g, r, start, text, group)
  local k = 0
  for ch in W.chars(text) do
    g:put(r, start + k, ch, group)
    k = k + 1
  end
end

---A value over (or, inside, at the top of) a bar `width` cells wide at column `at`, the
---bar's top at height `to`: only when that cell is free (inside: over the bar).
local function put_value(g, o, text, at, to, room, group)
  local r = o.inside and (g.rows - math.floor(to))
    or (g.rows - 1 - math.min(math.ceil(to), g.rows - 1))
  if W.width(text) <= room and r >= 0 and r < g.rows and (o.inside or not g.cells[r][at]) then
    put_text(g, r, at, text, group)
  end
end

---Bar i of vertical bars (`v`: { slot, bw, height_of, lo, stacked }): its segments side
---by side (grouped) or on top of each other (stacked), with their values. Returns the
---column of its center.
local function vertical_bar(ctx, g, v, i, b, o)
  local bw, lo = v.bw, v.lo
  local segs = segments(b)
  local width_all = v.stacked and bw or bw * #segs
  local c0 = (i - 1) * v.slot + math.floor((v.slot - width_all) / 2)
  local top_h, total = v.height_of(math.max(lo, 0)), 0
  for si, s in ipairs(segs) do
    local start_c = v.stacked and c0 or (c0 + (si - 1) * bw)
    local base = v.stacked and top_h or v.height_of(math.max(lo, 0))
    local to = v.stacked and v.height_of(total + s.value) or v.height_of(s.value)
    for c = start_c, start_c + bw - 1 do
      if c < g.cols then
        fill(g, c, base, to, s.group)
      end
    end
    total = total + s.value
    top_h = to
    local vg = o.show_values and not v.stacked and value_group(ctx, s)
    if vg then
      local text = fmt.value(s.value, o.value_format)
      put_value(g, o, text, start_c + math.floor((bw - W.width(text)) / 2), to, bw + 1, vg)
    end
  end
  local svg = o.show_values and v.stacked and value_group(ctx, segs[1])
  if svg then
    local text = fmt.value(total, o.value_format)
    put_value(g, o, text, c0 + math.floor((bw - W.width(text)) / 2), top_h, v.slot, svg)
  end
  return c0 + math.floor(width_all / 2)
end

---Vertical bars: columns with eighth-block tops, category labels below.
function M.vertical(ctx, bars, o)
  local stacked = o.stacked
  local minv, maxv, all = value_range(bars, stacked, o.axes)
  local lo, hi = C.limits(ctx, minv, maxv, o.axes and o.axes.ymin or 0, o.axes and o.axes.ymax)
  local spec = {
    title = o.title,
    xlabel = o.xlabel,
    ylabel = o.ylabel,
    height = ctx.plot_height,
    legend = o.legend,
    legend_position = o.legend_position,
  }
  local _, labels = C.y_ticks(ctx, lo, hi, 15, o.value_format)
  spec.ylabels = labels
  local _, rows = ctx.frame.plot_size(ctx, spec)
  spec.yticks, spec.ylabels = C.y_ticks(ctx, lo, hi, rows, o.value_format)
  local cols
  cols, rows = ctx.frame.plot_size(ctx, spec)
  local nseg = (not stacked and bars[1]) and #segments(bars[1]) or 1
  local slot = math.max(1, math.floor(cols / math.max(#bars, 1)))
  local inner = math.max(1, slot - (o.bar_gap or (slot > 2 and 1 or 0)))
  local v = {
    slot = slot,
    lo = lo,
    stacked = stacked,
    bw = o.bar_width and math.max(1, math.min(o.bar_width, math.floor(inner / nseg)))
      or math.max(1, math.floor(inner / nseg)),
    height_of = function(x)
      return hi > lo and math.max(0, x - lo) / (hi - lo) * rows or 0
    end,
  }
  local g = require("dbdash.render.charts.grid").new(rows, cols)
  local centers = {}
  for i, b in ipairs(bars) do
    centers[i] = vertical_bar(ctx, g, v, i, b, o)
  end
  -- Reference lines: a row of ┄ at the value over the empty cells, the label at the end.
  for _, m in ipairs(mark_values(o.marks, all)) do
    local r = rows - 1 - math.floor(v.height_of(m.value))
    if r >= 0 and r < rows then
      local group = mark_group(ctx, m)
      for c = 0, cols - 1 do
        g:put(r, c, "┄", group, true)
      end
      if m.label then
        put_text(g, r, cols - W.width(m.label), m.label, group)
      end
    end
  end
  local out = g:output()
  -- Label every bar, truncated to its slot; with very narrow slots, label every k-th bar.
  spec.xticks = {}
  local every = slot >= 4 and 1 or math.ceil(4 / slot)
  for i = 1, #bars, every do
    local label = slot >= 4 and W.truncate(bars[i].label, slot - 1) or bars[i].label
    spec.xticks[#spec.xticks + 1] = { col = centers[i], label = label }
  end
  return ctx.frame.render(ctx, spec, out)
end

---Bars from x_column and y_column / y_columns / series_column (bar charts), sorted and
---cut to style.top. Returns the bars and the legend (several series).
function M.from_show(rs, show, ctx)
  local bars, legend = {}, nil
  if nn(show.series_column) then
    local xaxis, long = C.long(rs, show)
    legend = {}
    for i, s in ipairs(long) do
      legend[i] = {
        label = s.label,
        group = C.color(ctx, show, i, nil, s.label),
        label_group = C.item_hl(ctx, "legend", i, "legend"),
      }
    end
    for ci, label in ipairs(xaxis.labels) do
      local segs = {}
      for si, s in ipairs(long) do
        local v = 0
        for _, p in ipairs(s.points) do
          if p.x == xaxis.values[ci] then
            v = p.y
          end
        end
        local k = (ci - 1) * #long + si
        segs[si] =
          { value = v, group = bar_group(ctx, k, legend[si].group), series = s.label, item = k }
      end
      bars[ci] = { label = label, segments = segs }
    end
  else
    local xi = C.col(rs, nn(show.x_column), "x_column")
    local series = C.series(rs, show)
    local entries = {} -- (several series: their legend)
    if #series > 1 then
      for i, s in ipairs(series) do
        entries[i] = {
          label = s.label,
          group = C.color(ctx, show, i, nil, s.label),
          label_group = C.item_hl(ctx, "legend", i, "legend"),
        }
      end
      legend = entries
    end
    for _, row in ipairs(rs.rows) do
      local label = C.text(row[xi])
      if #series == 1 then
        local v = C.num(row[series[1].index])
        if v then
          local k = #bars + 1
          bars[k] = {
            label = label,
            value = v,
            group = bar_group(ctx, k, C.color(ctx, show, 1, nil, label)),
            item = k,
          }
        end
      else
        local segs = {}
        local base = #bars * #series
        for i, s in ipairs(series) do
          segs[i] = {
            value = C.num(row[s.index]) or 0,
            group = bar_group(ctx, base + i, entries[i].group),
            series = s.label,
            item = base + i,
          }
        end
        bars[#bars + 1] = { label = label, segments = segs }
      end
    end
  end
  local order = nn(show.sort)
  if order == "asc" or order == "desc" then
    local function total(b)
      local t = 0
      for _, s in ipairs(segments(b)) do
        t = t + s.value
      end
      return t
    end
    table.sort(bars, function(a, b)
      if order == "asc" then
        return total(a) < total(b)
      end
      return total(a) > total(b)
    end)
  end
  local top = tonumber(nn(show.top))
  if top and #bars > top then
    bars = { unpack(bars, 1, top) }
  end
  return bars, legend
end

---The options shared by bar charts and histograms.
function M.options(show, ctx, legend)
  local axes = C.axes(show)
  local bar, value = ctx.css:get("bar"), ctx.css:get("value")
  return {
    xlabel = axes.xlabel,
    ylabel = axes.ylabel,
    show_values = value.display ~= "none",
    value_format = axes.yformat,
    stacked = nn(show.stacked) == true,
    bar_width = bar.width,
    bar_gap = bar.gap,
    inside = value.position == "inside",
    axes = axes,
    marks = nn(show.mark_lines),
    legend = legend,
    legend_position = legend and C.legend_position(ctx, #legend) or "none",
  }
end

---Histogram bins from value_column. bins defaults to Sturges' rule; bin_width and
---bin_range fix the bins (Vega-Lite bin.step / extent); cumulative adds up; normalize:
---percent (of all values) or density (per unit of the value).
-- bins by result: the DOM build (render/content/chart.lua) and the renderer share them
local bin_cache = setmetatable({}, { __mode = "k" })

---The bins of a result (without colors), computed once per result and settings.
function M.bins(rs, show)
  local key = vim.json.encode({
    show.value_column,
    show.bins,
    show.bin_width,
    show.bin_range,
    show.cumulative,
    show.normalize,
  })
  local hit = bin_cache[rs]
  if hit and hit.key == key then
    return hit.bins, hit.vals
  end
  local bins, vals = M.compute_bins(rs, show)
  bin_cache[rs] = { key = key, bins = bins, vals = vals }
  return bins, vals
end

---Bins colored for a chart (each bin a copy: renderers annotate them).
function M.histogram(rs, show, ctx)
  local bins, vals = M.bins(rs, show)
  local group = C.color(ctx, show, 1)
  local out = {}
  for i, b in ipairs(bins) do
    out[i] = {
      lower = b.lower,
      upper = b.upper,
      label = b.label,
      value = b.value,
      group = ctx and bar_group(ctx, i, group) or group,
      item = i,
    }
  end
  return out, vals
end

function M.compute_bins(rs, show)
  local vi = C.col(rs, nn(show.value_column), "value_column")
  local vals = {}
  for _, row in ipairs(rs.rows) do
    local v = C.num(row[vi])
    if v then
      vals[#vals + 1] = v
    end
  end
  if #vals == 0 then
    return {}, vals
  end
  local lo, hi = math.min(unpack(vals)), math.max(unpack(vals))
  local range = nn(show.bin_range)
  if type(range) == "table" then
    lo, hi = tonumber(range[1]) or lo, tonumber(range[2]) or hi
  end
  local bw = tonumber(nn(show.bin_width))
  local nb
  if bw and bw > 0 then
    nb = math.max(1, math.ceil((hi - lo) / bw - 1e-9))
  else
    nb = tonumber(nn(show.bins)) or math.ceil(math.log(#vals, 2)) + 1
    nb = math.max(1, math.floor(nb))
    if lo == hi then
      nb = 1
    end
    bw = nb > 0 and (hi - lo) / nb or 1
  end
  local counts = {}
  for i = 1, nb do
    counts[i] = 0
  end
  for _, v in ipairs(vals) do
    if v >= lo and v <= hi then
      local b = bw > 0 and math.floor((v - lo) / bw) + 1 or 1
      b = math.min(math.max(b, 1), nb)
      counts[b] = counts[b] + 1
    end
  end
  if nn(show.cumulative) == true then
    for i = 2, nb do
      counts[i] = counts[i] + counts[i - 1]
    end
  end
  local norm = nn(show.normalize)
  if norm == "percent" then
    for i = 1, nb do
      counts[i] = counts[i] / #vals * 100
    end
  elseif norm == "density" then
    for i = 1, nb do
      counts[i] = bw > 0 and counts[i] / (#vals * bw) or 0
    end
  end
  local bins = {}
  for i = 1, nb do
    local a, b = lo + (i - 1) * bw, lo + i * bw
    bins[i] = {
      lower = a,
      upper = b,
      label = ("[%s, %s%s"):format(fmt.number(a), fmt.number(b), i == nb and "]" or ")"),
      value = counts[i],
    }
  end
  return bins, vals
end

---mark_lines of a histogram are on the value axis of the data (the bins): turn them
---into the bin they fall in, as a marked label.
function M.histogram_marks(show, bins, vals)
  local out = {}
  for _, m in ipairs(mark_values(nn(show.mark_lines), vals)) do
    for _, b in ipairs(bins) do
      if m.value >= b.lower and m.value <= b.upper then
        out[#out + 1] =
          { bin = b, label = m.label or fmt.number(m.value), class = m.class, index = m.index }
        break
      end
    end
  end
  return out
end

return M
