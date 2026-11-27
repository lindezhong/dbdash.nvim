-- The box around a chart, after the CSS box model: padding, a border (panel_border, with
-- the title in its top line like a fieldset legend), a background, and where the chart
-- sits in its box (justify / align, like justify-self / align-self).
--
--   ╭─ Title ──────────╮
--   │                  │   padding: [1, 2]
--   │  chart lines     │
--   │                  │
--   ╰──────────────────╯
local W = require("dbdash.util.width")
local borders = require("dbdash.render.borders")

local M = {}

---@class dbdash.paint.BoxSettings
---@field pad integer[]
---@field border table?
---@field border_group string
---@field background string?
---@field justify string
---@field align string
---@field title_group string
---@field title_align string?
---@field ellipsis string

---The box settings of an element from its computed style: padding, border (with
---border-color), background-color, justify-self / align-self, and its title part's
---color, text-align and text-overflow.
---@param css dbdash.css.Scope? the panel's element (default: a panel of its own)
---@return dbdash.paint.BoxSettings
function M.settings(css)
  css = css or require("dbdash.css").scope(nil, nil)
  local c = css.node.tag == "panel" and css:get() or css:get("panel")
  local title = css:get("panel-title")
  local hl = require("dbdash.css.hl")
  local border = c.border ~= "none" and borders.get(c.border, "single") or nil
  return {
    pad = c.padding,
    border = border,
    border_group = hl.group({ color = c["border-color"] }),
    background = c["background-color"] and hl.group({
      ["background-color"] = c["background-color"],
    }) or nil,
    justify = c["justify-self"],
    align = c["align-self"],
    title_group = css:hl("panel-title"),
    title_align = title["text-align"] ~= "start" and title["text-align"] or nil,
    ellipsis = require("dbdash.css").ellipsis(title),
  }
end

---Room inside the box for its content.
---@return integer width, integer height
function M.inner(s, width, height)
  local b = s.border and 2 or 0
  return math.max(width - s.pad[2] - s.pad[4] - b, 10),
    math.max(height - s.pad[1] - s.pad[3] - b, 1)
end

---A title line (render/output.lua).
M.title_line = require("dbdash.render.output").title_line

local function shift(out, cols, rows)
  local lines, hl = {}, {}
  local pad = string.rep(" ", cols)
  for _ = 1, rows do
    lines[#lines + 1] = ""
  end
  for _, l in ipairs(out.lines) do
    lines[#lines + 1] = l == "" and l or (pad .. l)
  end
  for _, h in ipairs(out.hl) do
    local e = vim.deepcopy(h)
    e.row, e.col_s, e.col_e = h.row + rows, h.col_s + #pad, h.col_e + #pad
    hl[#hl + 1] = e
  end
  local hits
  for _, h in ipairs(out.hits or {}) do
    hits = hits or {}
    hits[#hits + 1] = { row_s = h.row_s + rows, row_e = h.row_e + rows, node = h.node }
  end
  return { lines = lines, hl = hl, hits = hits }
end

---Place `body` in a `width` x `height` area by justify / align.
function M.position(body, s, width, height)
  local w = 0
  for _, l in ipairs(body.lines) do
    w = math.max(w, W.width(l))
  end
  local dx, dy = 0, 0
  if s.justify == "center" then
    dx = math.floor((width - w) / 2)
  elseif s.justify == "end" then
    dx = width - w
  end
  if height then
    local free = height - #body.lines
    if s.align == "center" then
      dy = math.floor(free / 2)
    elseif s.align == "end" then
      dy = free
    end
  end
  dx, dy = math.max(dx, 0), math.max(dy, 0)
  if dx == 0 and dy == 0 then
    return body
  end
  return shift(body, dx, dy)
end

---Wrap `content` (already `inner` sized) in padding and border; `title` goes into the top
---border when there is one. The result is `width` cells wide (lines padded when there is a
---background or a border) and carries `bg` for the layout.
---@param content dbdash.render.Output
---@param s table M.settings()
---@param width integer
---@param height integer? the box height (nil: as tall as the content)
---@param title { text: string, spans: table[] }? a title for the top border
---@return dbdash.render.Output
function M.wrap(content, s, width, height, title)
  local top, right, bottom, left = unpack(s.pad)
  if top + right + bottom + left == 0 and not s.border and not s.background then
    return content
  end
  local b = s.border
  local inner_w = width - left - right - (b and 2 or 0)
  local rows = {}
  for _ = 1, top do
    rows[#rows + 1] = { text = "", spans = {} }
  end
  local by_row = {}
  for _, h in ipairs(content.hl) do
    by_row[h.row] = by_row[h.row] or {}
    table.insert(by_row[h.row], h)
  end
  for i, l in ipairs(content.lines) do
    rows[#rows + 1] = { text = l, spans = by_row[i - 1] or {} }
  end
  local inner_h = height and (height - (b and 2 or 0)) or (#rows + bottom)
  while #rows < inner_h do
    rows[#rows + 1] = { text = "", spans = {} }
  end
  local lines, hl = {}, {}
  local function add(text, spans)
    lines[#lines + 1] = text
    for _, sp in ipairs(spans) do
      hl[#hl + 1] =
        { row = #lines - 1, col_s = sp[1], col_e = sp[2], group = sp[3], priority = sp[4] }
    end
  end
  local g = s.border_group
  if b then
    local t = title and title.text or ""
    if title and t ~= "" then
      -- ╭─ Title ───╮ (the legend of a fieldset), aligned by title_align
      local room = width - 4
      local tt = W.truncate(t, math.max(room - 2, 1), s.ellipsis)
      local fill = room - W.width(tt) - 2
      local lead = s.title_align == "center" and math.floor(fill / 2)
        or (s.title_align == "right" and fill or 0)
      local pre = b.tl .. b.h .. string.rep(b.h, lead) .. " "
      local line = pre .. tt .. " " .. string.rep(b.h, fill - lead) .. b.h .. b.tr
      local spans = { { 0, #pre, g }, { #pre + #tt, #line, g } }
      for _, sp in ipairs(title.spans) do
        if sp[1] < #tt then
          spans[#spans + 1] = { #pre + sp[1], #pre + math.min(sp[2], #tt), sp[3] }
        end
      end
      add(line, spans)
    else
      local line = b.tl .. string.rep(b.h, width - 2) .. b.tr
      add(line, { { 0, #line, g } })
    end
  end
  local lpad, rpad_w = string.rep(" ", left), right
  for k = 1, math.min(#rows, inner_h) do
    local r = rows[k]
    local text = W.truncate(r.text, inner_w, "")
    local prefix = (b and b.v or "") .. lpad
    local spans = {}
    if b then
      spans[1] = { 0, #b.v, g }
    end
    for _, h in ipairs(r.spans) do
      local s_, e_ = math.min(h.col_s, #text), math.min(h.col_e, #text)
      if e_ > s_ then
        spans[#spans + 1] = { #prefix + s_, #prefix + e_, h.group, h.priority }
      end
    end
    local line = prefix .. W.pad(text, inner_w) .. string.rep(" ", rpad_w)
    if b then
      spans[#spans + 1] = { #line, #line + #b.v, g }
      line = line .. b.v
    end
    add(line, spans)
  end
  if b then
    local line = b.bl .. string.rep(b.h, width - 2) .. b.br
    add(line, { { 0, #line, g } })
  end
  if s.background then
    for r, l in ipairs(lines) do
      table.insert(
        hl,
        1,
        { row = r - 1, col_s = 0, col_e = #l, group = s.background, priority = 50 }
      )
    end
  end
  return { lines = lines, hl = hl, bg = s.background, full = s.background ~= nil or b ~= nil }
end

return M
