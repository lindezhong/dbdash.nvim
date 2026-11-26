-- Drawing a dashboard: header, countdowns, argument lines and the panel grid.
local M = require("dbdash.scheduler")
local S = require("dbdash.scheduler.shared")
local Panel, Dashboard = S.Panel, S.Dashboard
local opts, now = S.opts, S.now
local args = require("dbdash.args")
local buffer = require("dbdash.view.buffer")
local W = require("dbdash.util.width")

---Countdown text: {time} the seconds left, {clock} m:ss (h:mm:ss from an hour);
---"…" while refreshing.
function M.countdown_text(fmt, secs, running)
  if running then
    return "…"
  end
  local f = math.floor
  local clock = secs >= 3600 and ("%d:%02d:%02d"):format(f(secs / 3600), f(secs % 3600 / 60), secs % 60)
    or ("%d:%02d"):format(f(secs / 60), secs % 60)
  return (fmt:gsub("{time}", tostring(secs)):gsub("{clock}", clock))
end

---Seconds until the next refresh of every panel (cfg.refresh_all).
function Dashboard:remaining_global()
  if not self.gnext_at then
    return 0
  end
  return math.max(0, math.ceil((self.gnext_at - now()) / 1000))
end

---The header above the panels: the dashboard title (and the global countdown, an extmark
---on its line), then an empty line; none without a title or countdown.
---ⓘ (dashboard.icons.description): there is a description to read with K.
local function desc_icon()
  return require("dbdash").options.dashboard.icons.description
end

---The header shows ⓘ for the dashboard's description, and in a one-chart dashboard for the
---chart's too (the chart has no title line of its own).
function Dashboard:header_icon()
  local cfg = self.cfg
  return cfg.description ~= nil or (not cfg.grid and self.panels[1].cfg.show.description ~= nil)
end

---The header above the panels: the dashboard title and ⓘ (and the global countdown, an
---extmark on its line), then an empty line; none without any of them.
function Dashboard:header()
  local cfg = self.cfg
  local icon = self:header_icon()
  if not (cfg.title or cfg.show_countdown or icon) then
    return {}, {}
  end
  local title = cfg.title or ""
  local line, hl = title, { { row = 0, col_s = 0, col_e = #title, group = "DbDashTitle" } }
  if icon then
    line = title ~= "" and (title .. " ") or ""
    hl[#hl + 1] = { row = 0, col_s = #line, col_e = #line + #desc_icon(), group = "DbDashDescIcon" }
    line = line .. desc_icon()
  end
  return { line, "" }, hl
end

---The args_show line of a panel (its shown_args with their current values; local ones
---highlighted apart), cut to `width`; nil when it shows none.
---@return { lines: string[], hl: table[] }?
function M.args_line(p, width)
  local specs = p.cfg.shown_args
  if #specs == 0 then
    return nil
  end
  local parts, spans, pos = {}, {}, 0
  local function put(str, group)
    if group then
      spans[#spans + 1] = { pos, pos + #str, group }
    end
    parts[#parts + 1] = str
    pos = pos + #str
  end
  for _, spec in ipairs(specs) do
    if #parts > 0 then
      put("  ")
    end
    put(spec.name, spec.panel and "DbDashArgLocal" or "DbDashArgName")
    put("=")
    put(args.format_value(args.value(spec, p.d.state)), "DbDashArgValue")
  end
  local W = require("dbdash.util.width")
  local text = table.concat(parts)
  local line = W.truncate(text, width)
  local hl = {}
  for _, sp in ipairs(spans) do
    if sp[1] < #line then
      hl[#hl + 1] = { row = 0, col_s = sp[1], col_e = math.min(sp[2], #line), group = sp[3] }
    end
  end
  return { lines = { line }, hl = hl }
end

---`parts` (rendered blocks) above `body`, rows shifted.
local function prepend(body, parts)
  local out = { lines = {}, hl = {} }
  for _, part in ipairs(vim.list_extend(vim.list_extend({}, parts), { body })) do
    local off = #out.lines
    vim.list_extend(out.lines, part.lines)
    for _, h in ipairs(part.hl) do
      out.hl[#out.hl + 1] = { row = h.row + off, col_s = h.col_s, col_e = h.col_e, group = h.group }
    end
  end
  return out
end

local function message(text, group)
  return { lines = { text }, hl = { { row = 0, col_s = 0, col_e = #text, group = group } } }
end

---Render one panel's chart (or a placeholder) at the given size.
local function render_panel(p, show, width, height, fill)
  if p.rs then
    local ok, out = pcall(
      require("dbdash.render").render,
      p.rs,
      show,
      { width = width, height = height, history = p.values, fill = fill }
    )
    if ok then
      return out
    end
    return message("render error: " .. tostring(out), "DbDashError")
  elseif not p.error then
    return message("Loading…", "DbDashMuted")
  end
  return { lines = {}, hl = {} }
end

---Multi-panel cell: a header line (title, state, error) above the chart, in the panel's
---box (render/box.lua: padding, panel_border with the title in its top line, background,
---justify / align). `exact`: the cell is `height` lines (else as tall as its content,
---for measuring).
local function panel_cell(p, width, height, fill, exact)
  local box = require("dbdash.render.box")
  local show = vim.deepcopy(p:show_config())
  local st = box.settings(show)
  show.title = nil -- shown in the header line (or the box's top border) instead
  local iw, ih = box.inner(st, width, height)
  local style = show.style ~= vim.NIL and show.style or {}
  local name = style.show_title == false and "" or p:title()
  local icon = p.cfg.show.description and desc_icon() or nil
  -- The title, aligned by title_align, then ⓘ and the error.
  local room = math.max(iw - (icon and (W.width(icon) + 1) or 0), 1)
  local head, s0, e0 = box.title_line(name, room, st.title_align or "left", st.ellipsis)
  local spans = { { s0, e0, st.title_group } }
  if icon then
    head = head .. " " .. icon
    spans[#spans + 1] = { #head - #icon, #head, "DbDashDescIcon" }
  end
  if p.error then
    local free = iw - W.width(head) - 3
    if free > 5 then
      local e = W.truncate(M.format_error(p.error):gsub("\n", " "), free)
      spans[#spans + 1] = { #head + 2, #head + 2 + #("✗ " .. e), "DbDashError" }
      head = head .. "  ✗ " .. e
    end
  end
  local border_title
  local header = { lines = { head }, hl = {} }
  for _, sp in ipairs(spans) do
    header.hl[#header.hl + 1] = { row = 0, col_s = sp[1], col_e = sp[2], group = sp[3] }
  end
  if st.border then
    -- fieldset style: ╭─ Title ⓘ ──╮
    local lead = #head - #(head:gsub("^%s+", ""))
    border_title = { text = vim.trim(head), spans = {} }
    for _, sp in ipairs(spans) do
      border_title.spans[#border_title.spans + 1] = { sp[1] - lead, sp[2] - lead, sp[3] }
    end
    header = nil
  end
  local args_line = M.args_line(p, iw)
  local bh = ih - (header and 1 or 0) - (args_line and 1 or 0)
  local body = render_panel(p, show, iw, bh, fill)
  body = box.position(body, st, iw, exact and bh or nil)
  local parts = {}
  if header then
    parts[#parts + 1] = header
  end
  if args_line then
    parts[#parts + 1] = args_line
  end
  local out = prepend(body, parts)
  return box.wrap(out, st, width, exact and height or nil, border_title)
end

---The chart of a one-chart dashboard in its box (padding, panel_border, background,
---justify / align); the title stays the chart's own unless the border carries it.
function M.single(p, width, height)
  local box = require("dbdash.render.box")
  local show = p:show_config()
  local st = box.settings(show)
  local iw, ih = box.inner(st, width, height)
  local border_title
  if st.border and show.title ~= nil and show.title ~= vim.NIL then
    border_title = { text = show.title, spans = { { 0, #show.title, st.title_group } } }
    show = vim.deepcopy(show)
    show.title = nil
  end
  local body = render_panel(p, show, iw, ih)
  local exact = st.align ~= "start" or st.border ~= nil or st.background ~= nil
  body = box.position(body, st, iw, exact and ih or nil)
  return box.wrap(body, st, width, exact and height or nil, border_title)
end

---A panel's heights at `width` (CSS min-content / max-content): with its smallest plot
---and with its full plot. Cached until its result, error, style or width change.
---@return integer hmin, integer hmax
local function measure(p, width)
  local show = p:show_config()
  local key = vim.json.encode({ width, show, p.error and true or false })
  local m = p.measured
  if not (m and m.rs == p.rs and m.key == key) then
    m = {
      rs = p.rs,
      key = key,
      hmin = #panel_cell(p, width, 0).lines,
      hmax = #panel_cell(p, width, 100000).lines,
    }
    p.measured = m
  end
  return m.hmin, m.hmax
end

---The panels laid out on the grid (CSS Grid: column and row tracks, areas, placement;
---render/layout.lua). Rows get at least their panels' min-content; free lines of the
---window grow them; a grid taller than the window scrolls.
---@param width integer
---@param avail integer lines below the header
function Dashboard:grid(width, avail)
  local L = require("dbdash.render.layout")
  local lay = self.cfg.layout
  local cols = L.columns(lay.columns, width, lay.gap)
  local nrows = 0
  for _, pl in ipairs(lay.places) do
    nrows = math.max(nrows, pl.row + pl.row_span - 1)
  end
  local tracks = {}
  for r = 1, nrows do
    tracks[r] = lay.rows[r] or lay.auto_row
  end
  local cells, items = {}, {}
  for i, p in ipairs(self.panels) do
    local pl = lay.places[i]
    local first, last = cols[pl.col], cols[pl.col + pl.span - 1]
    local w = last.x + last.width - first.x
    local hmin, hmax = measure(p, w)
    cells[i] = { x = first.x, width = w }
    items[i] = { row = pl.row, row_span = pl.row_span, hmin = hmin, hmax = hmax }
  end
  local heights, fill = L.rows(tracks, items, avail - lay.row_gap * math.max(nrows - 1, 0), lay.row_gap)
  local top, y = {}, 0
  for r = 1, nrows do
    top[r] = y
    y = y + heights[r] + lay.row_gap
  end
  local outs = {}
  for i, p in ipairs(self.panels) do
    local pl, c = lay.places[i], cells[i]
    local h, f = lay.row_gap * (pl.row_span - 1), false
    for r = pl.row, pl.row + pl.row_span - 1 do
      h = h + heights[r]
      f = f or fill[r]
    end
    c.y, c.height = top[pl.row], h
    outs[i] = panel_cell(p, c.width, h, f, true)
  end
  return L.compose(cells, outs)
end

---Re-render cached results into the buffer (no query).
function Dashboard:redraw()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local width, height = buffer.size(self.buf)
  self.last_size = { width, height }
  local lines, hl = self:header()
  local offset = #lines
  local body
  if not self.cfg.grid then
    local p = self.panels[1]
    local args_line = M.args_line(p, width)
    local h = height - offset
    if args_line then
      h = h - 2
    end
    body = M.single(p, width, h)
    if args_line then
      body = prepend(body, { args_line, { lines = { "" }, hl = {} } })
    end
    self.regions = nil
  else
    body = self:grid(width, height - offset)
    self.regions = {}
    for i, r in ipairs(body.regions) do
      self.regions[i] = { row_s = r.row_s + offset, row_e = r.row_e + offset, x = r.x, width = r.width }
    end
  end
  vim.list_extend(lines, body.lines)
  for _, h in ipairs(body.hl) do
    hl[#hl + 1] = { row = h.row + offset, col_s = h.col_s, col_e = h.col_e, group = h.group }
  end
  if #lines == 0 then
    lines = { "" }
  end
  self.header_rows = offset
  buffer.draw(self.buf, lines, hl)
  vim.b[self.buf].dbdash_regions = self.regions
  self:update_status()
end

---Countdown and error extmarks.
function Dashboard:update_status()
  local header
  if self.cfg.show_countdown then
    local running = false
    if self.refreshing_all then
      for _, p in ipairs(self.panels) do
        running = running or p.running
      end
      self.refreshing_all = running or nil
    end
    header = M.countdown_text(self.cfg.countdown_format, self:remaining_global(), running)
  end
  if not self.cfg.grid then
    local p = self.panels[1]
    local show = p.cfg.show
    local countdown
    if show.show_countdown then
      countdown = M.countdown_text(show.countdown_format, p:remaining(), p.running)
    end
    if p.push then
      countdown = p:push_state() .. (countdown and p:push_state() ~= "ended" and ("  " .. countdown) or "")
    end
    buffer.set_status(self.buf, {
      header = header,
      countdown = countdown,
      row = self.header_rows or 0,
      error = p.error and M.format_error(p.error) or nil,
      position = opts().countdown_position,
    })
    return
  end
  local marks = {}
  for i, p in ipairs(self.panels) do
    local r = self.regions and self.regions[i]
    local show = p.cfg.show
    if r and (show.show_countdown or p.running or p.push) then
      local text = M.countdown_text(show.countdown_format, p:remaining(), p.running)
      if p.push then
        text = p:push_state() .. (show.show_countdown and p:push_state() ~= "ended" and ("  " .. text) or "")
      end
      marks[#marks + 1] = { row = r.row_s, col = r.x + r.width - vim.fn.strdisplaywidth(text), text = text }
    end
  end
  buffer.set_status(self.buf, { header = header, panels = marks })
end

---Panel whose region contains buffer line `lnum` (1-based) and display column `dcol`
---(0-based); the only panel when single. Panels side by side share lines, so the column
---decides between them.
function Dashboard:panel_at(lnum, dcol)
  if not self.cfg.grid then
    return self.panels[1]
  end
  for i, r in ipairs(self.regions or {}) do
    if lnum - 1 >= r.row_s and lnum - 1 <= r.row_e and (dcol or 0) >= r.x and (dcol or 0) < r.x + r.width then
      return self.panels[i]
    end
  end
end
