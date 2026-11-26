-- Drawing a dashboard: header, countdowns, argument lines and the panel grid.
local M = require("dbdash.scheduler")
local S = require("dbdash.scheduler.shared")
local Panel, Dashboard = S.Panel, S.Dashboard
local opts, now = S.opts, S.now
local args = require("dbdash.args")
local buffer = require("dbdash.view.buffer")

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

---Style queries on an element of the dashboard's document (css.scope).
local function scope(node)
  return require("dbdash.css").scope(node, nil)
end

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

---Rendering update (Servo's "update the rendering"): bring the DOM up to date with the
---dashboard's state, lay it out (layout/view.lua), paint it (paint/) and composite the
---layers into lines (compositor/).
---@return string[] lines, table[] hl, table[]? regions
function Dashboard:render_view(width, height)
  require("dbdash.dom.build").sync(self, {
    icon = desc_icon(),
    format_error = M.format_error,
    header_icon = self:header_icon(),
  })
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
  return lines, hl, body, offset, regions
end

---Re-render cached results into the buffer (no query).
function Dashboard:redraw()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local width, height = buffer.size(self.buf)
  self.last_size = { width, height }
  local lines, hl, body, offset, regions = self:render_view(width, height)
  self.regions = regions
  vim.list_extend(lines, body.lines)
  for _, h in ipairs(body.hl) do
    hl[#hl + 1] = { row = h.row + offset, col_s = h.col_s, col_e = h.col_e, group = h.group, priority = h.priority }
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
      countdown_hl = scope(self.header_node):hl("countdown"),
      error_hl = scope(p.node):hl("error"),
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
  buffer.set_status(self.buf, { header = header, panels = marks, countdown_hl = scope(self.header_node):hl("countdown") })
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
