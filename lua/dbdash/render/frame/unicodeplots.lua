-- Plot frame (after UnicodePlots): y-axis labels, bordered plot area, x-axis labels,
-- axis titles and legend (the chart's title is its panel's).
--
--   y title
--   150 ┌──────────┐ ■ visits
--       │⠀⠀⡠⠊⠉⠢⡀⠀⠀│ ■ signups
--     0 └──────────┘
--        00:00   23:00
--             x title
local W = require("dbdash.util.width")
local borders = require("dbdash.render.borders")

local M = { name = "unicodeplots" }

---@class dbdash.render.FrameSpec
---@field xlabel string? x-axis title
---@field ylabel string? y-axis title
---@field ylabels string[]? every y tick label (to size the left margin)
---@field yticks { row: integer, label: string }[]? 0-based plot rows
---@field xticks { col: integer, label: string }[]? 0-based plot columns
---@field legend { label: string, group: string, symbol: string? }[]?
---@field legend_position "right"|"bottom"|"none"?
---@field border boolean? default true
---@field x_axis boolean? reserve a line for x tick labels (default true)
---@field height integer? preferred plot rows
---@field min_rows integer?
---@field chars table? the border's characters (plot { border }, set by apply_style)

---Line builder that tracks byte offsets for highlights.
local function builder()
  local b = { parts = {}, pos = 0, spans = {} }
  function b.put(s, group)
    if group and #s > 0 then
      b.spans[#b.spans + 1] = { b.pos, b.pos + #s, group }
    end
    b.parts[#b.parts + 1] = s
    b.pos = b.pos + #s
  end
  function b.done()
    return table.concat(b.parts), b.spans
  end
  return b
end

local function legend_width(spec)
  if spec.legend_position ~= "right" or not spec.legend or #spec.legend == 0 then
    return 0
  end
  local w = 0
  for _, e in ipairs(spec.legend) do
    w = math.max(w, W.width(e.label))
  end
  return math.min(w, 24) + 3 -- " ■ label"
end

local function margin(spec)
  local m = 0
  for _, l in ipairs(spec.ylabels or {}) do
    m = math.max(m, W.width(l))
  end
  return m
end

---The plot's computed style through ctx: plot { border } (the line style; none drops the
---frame) and axis { display: none } (no tick labels and axis titles). Charts fill in
---their ticks between plot_size() calls, so this runs on every call.
function M.apply_style(ctx, spec)
  if spec.border ~= false and not spec.chars then
    local b = ctx.css:get("plot").border
    spec.chars = b ~= "none" and borders.get(b, "single") or nil
    spec.border = spec.chars ~= nil
  end
  if ctx.css:get("axis").display == "none" then
    spec.ylabels, spec.yticks, spec.xticks = nil, nil, nil
    spec.x_axis, spec.xlabel, spec.ylabel = false, nil, nil
  end
end

---Plot area size for the context and spec.
---@return integer cols, integer rows
function M.plot_size(ctx, spec)
  M.apply_style(ctx, spec)
  local border = spec.border ~= false and 2 or 0
  local left = margin(spec) + (margin(spec) > 0 and 1 or 0)
  local cols = ctx.width - left - border - legend_width(spec)
  local extra = border
    + (spec.ylabel and 1 or 0)
    + (spec.x_axis ~= false and 1 or 0)
    + (spec.xlabel and 1 or 0)
    + ((spec.legend_position == "bottom" and spec.legend and #spec.legend > 0) and 1 or 0)
  local rows = ctx.height - extra
  rows = math.min(rows, spec.height or 15)
  return math.max(cols, 10), math.max(rows, spec.min_rows or ctx.min_plot_height or 3)
end

---Lines with highlight spans ({ col_s, col_e, group }).
local function add(f, text, spans)
  f.lines[#f.lines + 1] = text
  for _, s in ipairs(spans or {}) do
    f.hl[#f.hl + 1] = { row = #f.lines - 1, col_s = s[1], col_e = s[2], group = s[3] }
  end
end

---A line of `text` centered over the plot (the title, the x axis title).
local function centered(f, text, group)
  local t = W.truncate(text, f.plot_w)
  local pad = f.left + math.max(0, math.floor((f.plot_w - W.width(t)) / 2))
  add(f, string.rep(" ", pad) .. t, { { pad, pad + #t, group } })
end

---Plot row r: its y tick label in the margin, the border, the body's line padded to the
---plot's width, and a legend entry on the right.
local function plot_row(f, body, r, ylab)
  local spec, ch = f.spec, f.ch
  local b = builder()
  local label = ylab[r]
  if f.m > 0 then
    b.put(string.rep(" ", f.m - (label and W.width(label) or 0)))
    if label then
      b.put(label, f.g_axis)
    end
    b.put(" ")
  end
  if f.border then
    b.put(ch.v, f.g_border)
  end
  local line = body.lines[r + 1] or ""
  local base = b.pos
  b.put(line)
  for _, h in ipairs(body.hl) do
    if h.row == r then
      b.spans[#b.spans + 1] = { base + h.col_s, base + h.col_e, h.group }
    end
  end
  local pad = f.cols - W.width(line)
  if pad > 0 then
    b.put(string.rep(" ", pad))
  end
  if f.border then
    b.put(ch.v, f.g_border)
  end
  local e = spec.legend_position == "right" and (spec.legend or {})[r + 1]
  if e then
    b.put(" ")
    b.put(e.symbol or "■", e.group)
    b.put(" " .. W.truncate(e.label, 24), e.label_group or f.g_legend)
  end
  add(f, b.done())
end

---A border line (top or bottom) of the plot.
local function border_line(f, left_ch, right_ch)
  local b = builder()
  b.put(string.rep(" ", f.left))
  b.put(left_ch .. string.rep(f.ch.h, f.cols) .. right_ch, f.g_border)
  add(f, b.done())
end

---The x axis's tick labels, centered on their columns, none overlapping the previous one.
local function x_axis(f)
  local offset = f.left + (f.border and 1 or 0)
  local width = offset + f.cols + (f.border and 1 or 0)
  local cells = {}
  for i = 1, width do
    cells[i] = " "
  end
  local last_end = 0
  for _, t in ipairs(f.spec.xticks or {}) do
    local w = W.width(t.label)
    local start = offset + t.col - math.floor(w / 2)
    start = math.max(start, offset)
    start = math.min(start, width - w)
    if start > last_end or last_end == 0 then
      local i = start + 1
      for c in W.chars(t.label) do
        cells[i] = c
        local cw = W.width(c)
        for k = 1, cw - 1 do
          cells[i + k] = ""
        end
        i = i + cw
      end
      last_end = start + w
    end
  end
  local s = table.concat(cells):gsub("%s+$", "")
  add(f, s, #s > 0 and { { 0, #s, f.g_axis } } or nil)
end

---The legend on one line below the plot.
local function bottom_legend(f, legend)
  local b = builder()
  b.put(string.rep(" ", f.left))
  for i, e in ipairs(legend) do
    if i > 1 then
      b.put("  ")
    end
    b.put(e.symbol or "■", e.group)
    b.put(" " .. e.label, e.label_group or f.g_legend)
  end
  add(f, b.done())
end

---Compose the frame around a plot body of exactly cols x rows characters.
---@param ctx dbdash.render.Ctx
---@param spec dbdash.render.FrameSpec
---@param body { lines: string[], hl: table[] }
---@return dbdash.render.Output
function M.render(ctx, spec, body)
  M.apply_style(ctx, spec)
  local cols = 0
  for _, l in ipairs(body.lines) do
    cols = math.max(cols, W.width(l))
  end
  local m = margin(spec)
  local border = spec.border ~= false
  local f = {
    spec = spec,
    ch = spec.chars or borders.STYLES.single,
    g_border = ctx.css:border_hl("plot"),
    g_axis = ctx.css:hl("axis"),
    g_legend = ctx.css:hl("legend"),
    cols = cols,
    m = m,
    left = m + (m > 0 and 1 or 0),
    border = border,
    plot_w = cols + (border and 2 or 0),
    lines = {},
    hl = {},
  }
  if spec.ylabel then
    local t = W.truncate(spec.ylabel, ctx.width)
    add(f, t, { { 0, #t, ctx.css:hl("axis-title") } })
  end
  local ylab = {}
  for _, t in ipairs(spec.yticks or {}) do
    ylab[t.row] = t.label
  end
  if border then
    border_line(f, f.ch.tl, f.ch.tr)
  end
  for r = 0, #body.lines - 1 do
    plot_row(f, body, r, ylab)
  end
  if border then
    border_line(f, f.ch.bl, f.ch.br)
  end
  if spec.x_axis ~= false then
    x_axis(f)
  end
  if spec.xlabel then
    centered(f, spec.xlabel, ctx.css:hl("axis-title"))
  end
  local legend = spec.legend or {}
  if spec.legend_position == "bottom" and #legend > 0 then
    bottom_legend(f, legend)
  end
  return { lines = f.lines, hl = f.hl }
end

M.builder = builder

return M
