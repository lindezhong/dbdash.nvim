-- Plot frame (after UnicodePlots): title, y-axis labels, bordered plot area,
-- x-axis labels, axis titles and legend.
--
--          Title
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
---@field title string?
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
    + (spec.title and spec.title ~= "" and 1 or 0)
    + (spec.ylabel and 1 or 0)
    + (spec.x_axis ~= false and 1 or 0)
    + (spec.xlabel and 1 or 0)
    + ((spec.legend_position == "bottom" and spec.legend and #spec.legend > 0) and 1 or 0)
  local rows = ctx.height - extra
  rows = math.min(rows, spec.height or 15)
  return math.max(cols, 10), math.max(rows, spec.min_rows or ctx.min_plot_height or 3)
end

---Compose the frame around a plot body of exactly cols x rows characters.
---@param ctx dbdash.render.Ctx
---@param spec dbdash.render.FrameSpec
---@param body { lines: string[], hl: table[] }
---@return dbdash.render.Output
function M.render(ctx, spec, body)
  M.apply_style(ctx, spec)
  local ch = spec.chars or borders.STYLES.single
  local g_border, g_axis, g_legend = ctx.css:border_hl("plot"), ctx.css:hl("axis"), ctx.css:hl("legend")
  local cols, rows = 0, #body.lines
  for _, l in ipairs(body.lines) do
    cols = math.max(cols, W.width(l))
  end
  local m = margin(spec)
  local left = m + (m > 0 and 1 or 0)
  local border = spec.border ~= false
  local lines, hl = {}, {}
  local function add(text, spans)
    lines[#lines + 1] = text
    for _, s in ipairs(spans or {}) do
      hl[#hl + 1] = { row = #lines - 1, col_s = s[1], col_e = s[2], group = s[3] }
    end
  end
  local plot_w = cols + (border and 2 or 0)

  if spec.title and spec.title ~= "" then
    local t = W.truncate(spec.title, plot_w)
    local pad = left + math.max(0, math.floor((plot_w - W.width(t)) / 2))
    add(string.rep(" ", pad) .. t, { { pad, pad + #t, ctx.css:hl("title") } })
  end
  if spec.ylabel then
    local t = W.truncate(spec.ylabel, ctx.width)
    add(t, { { 0, #t, ctx.css:hl("axis-title") } })
  end

  local ylab = {}
  for _, t in ipairs(spec.yticks or {}) do
    ylab[t.row] = t.label
  end
  local legend = spec.legend or {}
  local legend_right = spec.legend_position == "right" and #legend > 0

  local function legend_cell(b, i)
    local e = legend[i]
    if legend_right and e then
      b.put(" ")
      b.put(e.symbol or "■", e.group)
      b.put(" " .. W.truncate(e.label, 24), e.label_group or g_legend)
    end
  end

  if border then
    local b = builder()
    b.put(string.rep(" ", left))
    b.put(ch.tl .. string.rep(ch.h, cols) .. ch.tr, g_border)
    add(b.done())
  end
  for r = 0, rows - 1 do
    local b = builder()
    local label = ylab[r]
    if m > 0 then
      b.put(string.rep(" ", m - (label and W.width(label) or 0)))
      if label then
        b.put(label, g_axis)
      end
      b.put(" ")
    end
    if border then
      b.put(ch.v, g_border)
    end
    local line = body.lines[r + 1] or ""
    local base = b.pos
    b.put(line)
    for _, h in ipairs(body.hl) do
      if h.row == r then
        b.spans[#b.spans + 1] = { base + h.col_s, base + h.col_e, h.group }
      end
    end
    local pad = cols - W.width(line)
    if pad > 0 then
      b.put(string.rep(" ", pad))
    end
    if border then
      b.put(ch.v, g_border)
    end
    legend_cell(b, r + 1)
    add(b.done())
  end
  if border then
    local b = builder()
    b.put(string.rep(" ", left))
    b.put(ch.bl .. string.rep(ch.h, cols) .. ch.br, g_border)
    add(b.done())
  end

  if spec.x_axis ~= false then
    local offset = left + (border and 1 or 0)
    local width = offset + cols + (border and 1 or 0)
    local cells = {}
    for i = 1, width do
      cells[i] = " "
    end
    local last_end = 0
    for _, t in ipairs(spec.xticks or {}) do
      local w = W.width(t.label)
      local start = offset + t.col - math.floor(w / 2)
      start = math.max(start, offset)
      start = math.min(start, width - w)
      if start > last_end or last_end == 0 then
        local i = start + 1
        for ch in W.chars(t.label) do
          cells[i] = ch
          local cw = W.width(ch)
          for k = 1, cw - 1 do
            cells[i + k] = ""
          end
          i = i + cw
        end
        last_end = start + w
      end
    end
    local s = table.concat(cells):gsub("%s+$", "")
    add(s, #s > 0 and { { 0, #s, g_axis } } or nil)
  end
  if spec.xlabel then
    local t = W.truncate(spec.xlabel, plot_w)
    local pad = left + math.max(0, math.floor((plot_w - W.width(t)) / 2))
    add(string.rep(" ", pad) .. t, { { pad, pad + #t, ctx.css:hl("axis-title") } })
  end
  if spec.legend_position == "bottom" and #legend > 0 then
    local b = builder()
    b.put(string.rep(" ", left))
    for i, e in ipairs(legend) do
      if i > 1 then
        b.put("  ")
      end
      b.put(e.symbol or "■", e.group)
      b.put(" " .. e.label, e.label_group or g_legend)
    end
    add(b.done())
  end
  return { lines = lines, hl = hl }
end

M.builder = builder

return M
