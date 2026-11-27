-- Drawing a dashboard: header, countdowns, argument lines and the panel grid.
local M = require("dbdash.scheduler")
local S = require("dbdash.scheduler.shared")
local Dashboard = S.Dashboard
local opts, now = S.opts, S.now
local buffer = require("dbdash.view.buffer")

---Countdown text: {time} the seconds left, {clock} m:ss (h:mm:ss from an hour);
---"…" while refreshing.
function M.countdown_text(fmt, secs, running)
  if running then
    return "…"
  end
  local f = math.floor
  local clock = secs >= 3600
      and ("%d:%02d:%02d"):format(f(secs / 3600), f(secs % 3600 / 60), secs % 60)
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

---Style queries on an element of the dashboard's document (css.scope).
local function scope(node)
  return require("dbdash.css").scope(node, nil)
end

---The header shows ⓘ for the dashboard's description, and in a one-chart dashboard for the
---chart's too (the chart has no title line of its own).
function Dashboard:header_icon()
  local cfg = self.cfg
  return cfg.description ~= nil or (not cfg.grid and self.panels[1].cfg.show.description ~= nil)
end

---Rendering update (Servo's "update the rendering"): bring the DOM up to date with the
---dashboard's state, lay it out (layout/view.lua), paint it (paint/) and composite the
---layers into lines (compositor/).
---@return string[] lines, table[] hl, table[]? regions
function Dashboard:render_view(width, height)
  require("dbdash.dom.build").sync(self, {
    format_error = M.format_error,
    header_icon = self:header_icon(),
  })
  -- style phase: restyle from the dirty root before layout reads computed styles and
  -- decides what it can reuse
  self.last_restyle = require("dbdash.css.style").take_restyled(self.doc)
  local tree = require("dbdash.layout.view").reflow(self, width, height)
  local list = require("dbdash.paint").view(tree)
  local lines, hl = vim.deepcopy(list.header.lines), vim.deepcopy(list.header.hl)
  local offset = #lines
  local body, regions
  if list.body then
    body = list.body
  else
    local cells, outs = {}, {}
    for i, l in ipairs(list.layers) do
      cells[i] = { x = l.x, width = l.width, y = l.y, height = l.height }
      outs[i] = l.out
    end
    body = require("dbdash.compositor").compose(cells, outs)
    regions = {}
    for i, r in ipairs(body.regions) do
      regions[i] = { row_s = r.row_s + offset, row_e = r.row_e + offset, x = r.x, width = r.width }
    end
  end
  -- hit-test regions in buffer rows (events/)
  self.hits = {}
  for _, h in ipairs(list.hits or {}) do
    self.hits[#self.hits + 1] = {
      row_s = h.row_s + offset,
      row_e = h.row_e + offset,
      x = h.x,
      width = h.width,
      node = h.node,
    }
  end
  return lines, hl, body, offset, regions
end

---Ask for a rendering update (Servo: a task marks state dirty and the event loop runs
---"update the rendering" once): every request until it runs is one update, at most one
---every 20 ms. User actions call redraw() directly.
function Dashboard:request_render()
  if self.render_pending then
    return
  end
  self.render_pending = true
  local since = vim.uv.now() - (self.last_render_at or 0)
  vim.defer_fn(function()
    self.render_pending = false
    if require("dbdash.scheduler").get(self.path) ~= self then
      return
    end
    if self.paused then
      self.render_skipped = true -- hidden: drawn when shown again (resume)
      return
    end
    self:redraw()
  end, math.max(0, 20 - since))
end

---Re-render cached results into the buffer (no query).
function Dashboard:redraw()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local width, height = buffer.size(self.buf)
  self.last_size = { width, height }
  self.last_render_at = vim.uv.now()
  local lines, hl, body, offset, regions = self:render_view(width, height)
  self.regions = regions
  vim.list_extend(lines, body.lines)
  for _, h in ipairs(body.hl) do
    hl[#hl + 1] = {
      row = h.row + offset,
      col_s = h.col_s,
      col_e = h.col_e,
      group = h.group,
      priority = h.priority,
    }
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
  local build = require("dbdash.dom.build")
  local shown, format = build.countdown(self.header_node)
  if shown and self.cfg.refresh_all then
    local running = false
    if self.refreshing_all then
      for _, p in ipairs(self.panels) do
        running = running or p.running
      end
      self.refreshing_all = running or nil
    end
    header = M.countdown_text(format, self:remaining_global(), running)
  end
  if not self.cfg.grid then
    local p = self.panels[1]
    local countdown
    local p_shown, p_format = build.countdown(p.node)
    if p_shown then
      countdown = M.countdown_text(p_format, p:remaining(), p.running)
    end
    if p.push then
      countdown = p:push_state()
        .. (countdown and p:push_state() ~= "ended" and ("  " .. countdown) or "")
    end
    buffer.set_status(self.buf, {
      header = header,
      countdown = countdown,
      row = self.header_rows or 0,
      error = p.error and M.format_error(p.error) or nil,
      position = opts().countdown_position,
      countdown_hl = scope(self.header_node):hl("countdown"),
      error_hl = scope(p.node):hl("error"),
    })
    return
  end
  local marks = {}
  for i, p in ipairs(self.panels) do
    local r = self.regions and self.regions[i]
    local p_shown, p_format = build.countdown(p.node)
    if r and (p_shown or p.running or p.push) then
      local text = M.countdown_text(p_format, p:remaining(), p.running)
      if p.push then
        text = p:push_state() .. (p_shown and p:push_state() ~= "ended" and ("  " .. text) or "")
      end
      marks[#marks + 1] =
        { row = r.row_s, col = r.x + r.width - vim.fn.strdisplaywidth(text), text = text }
    end
  end
  buffer.set_status(
    self.buf,
    { header = header, panels = marks, countdown_hl = scope(self.header_node):hl("countdown") }
  )
end

---Panel whose region contains buffer line `lnum` (1-based) and display column `dcol`
---(0-based); the only panel when single. Panels side by side share lines, so the column
---decides between them.
function Dashboard:panel_at(lnum, dcol)
  if not self.cfg.grid then
    return self.panels[1]
  end
  -- hit test: the node at the position, then its panel (events/)
  local events = require("dbdash.events")
  return events.panel_of(self, events.hit_test(self, lnum, dcol))
end
