-- Dashboards: the global timer, refreshing every panel, pause and resume.
local M = require("dbdash.scheduler")
local S = require("dbdash.scheduler.shared")
local Dashboard = S.Dashboard
local opts, now, close_timer = S.opts, S.now, S.close_timer

---Refresh every panel now and restart all timers.
---Start (or restart) the global refresh timer (cfg.refresh_all).
---@param first integer? ms until the first tick (default: the interval)
function Dashboard:start_global_timer(first)
  local interval = self.cfg.refresh_all
  first = first or interval
  self.gnext_at = now() + first
  self.gtimer:stop()
  self.gtimer:start(first, interval, function()
    vim.schedule(function()
      if self.gtimer then
        self:restart({ timer = true })
      end
    end)
  end)
end

---Refresh every panel now and restart the timers. User actions (refresh key, changed
---arguments) cancel a running refresh and start again; timer ticks (`o.timer`) skip it.
---@param o { timer: boolean? }?
function Dashboard:restart(o)
  local tick = o and o.timer
  local ro = { queue = not tick }
  if self.paused and not tick then
    -- Not visible (setup({ dashboard = { pause_hidden = true } })): refresh once; only the
    -- show.refresh_hidden panels keep their timers.
    for _, p in ipairs(self.panels) do
      p:start_timer()
      p:refresh(ro)
    end
    return
  end
  -- Visible, or a global tick while paused (it is kept for show.refresh_hidden panels).
  if self.gtimer then
    self:start_global_timer()
    if tick and not self.paused then
      self.refreshing_all = true -- "…" in the header until every panel is done
    end
  end
  local t = now()
  local panels = vim.tbl_filter(function(p)
    return p:active()
  end, self.panels)
  for _, p in ipairs(panels) do
    -- A timer tick leaves panels that are backing off after failures alone.
    local backing_off = tick and p.retry_at and t < p.retry_at
    if backing_off then
      p.skip_tick = true
    else
      p:start_timer()
    end
  end
  for _, p in ipairs(panels) do
    if p.skip_tick then
      p.skip_tick = nil
      p.next_at = p.retry_at
    else
      p:refresh(ro)
    end
  end
end

function Dashboard:start_timers()
  if self.cfg.refresh_all then
    self.gtimer = vim.uv.new_timer()
  end
  self.ctimer = vim.uv.new_timer()
  local every = opts().countdown_interval
  self.ctimer:start(every, every, function()
    vim.schedule(function()
      if self.ctimer then
        self:update_status()
      end
    end)
  end)
  self:restart()
end

---Cancel the refreshes running in the dashboard's panels (Panel:cancel).
---@param reason string
function Dashboard:cancel(reason)
  for _, p in ipairs(self.panels) do
    p:cancel(reason)
  end
end

function Dashboard:stop_timers()
  close_timer(self.gtimer)
  close_timer(self.ctimer)
  self.gtimer, self.ctimer = nil, nil
  for _, p in ipairs(self.panels) do
    p:stop_timer()
  end
end

---State summary across panels: "running query", "error" or "idle".
function Dashboard:status_word()
  if self.paused then
    return "paused"
  end
  for _, p in ipairs(self.panels) do
    if p.retry_at then
      return "retrying"
    end
  end
  for _, p in ipairs(self.panels) do
    if p.running then
      return "running query"
    end
  end
  for _, p in ipairs(self.panels) do
    if p.error then
      return "error"
    end
  end
  return "idle"
end

---Seconds until the next refresh of any panel.
---Stop refreshing while no window of the current tab page shows the dashboard.
function Dashboard:pause()
  if self.paused then
    return
  end
  self.paused = true
  -- show.refresh_hidden panels keep refreshing: their own timers, and the global one when
  -- one of them follows it.
  close_timer(self.ctimer)
  self.ctimer = nil
  local keep_global = false
  for _, p in ipairs(self.panels) do
    if p.cfg.show.refresh_hidden then
      keep_global = keep_global or p.cfg.follows_global
    else
      p:stop_timer()
    end
  end
  if not keep_global then
    close_timer(self.gtimer)
    self.gtimer = nil
  end
  require("dbdash.view.sidebar").refresh()
end

---Continue after pause(): refresh what is due now, keep the remaining time of the rest.
function Dashboard:resume()
  if not self.paused then
    return
  end
  self.paused = false
  local t = now()
  self.ctimer = vim.uv.new_timer()
  local every = opts().countdown_interval
  self.ctimer:start(every, every, function()
    vim.schedule(function()
      if self.ctimer then
        self:update_status()
      end
    end)
  end)
  if self.cfg.refresh_all then
    self.gtimer = self.gtimer or vim.uv.new_timer() -- kept while paused for refresh_hidden
    local left = (self.gnext_at or t) - t
    if left <= 0 then
      self:restart({ timer = true }) -- the global interval elapsed: refresh every panel
      require("dbdash.view.sidebar").refresh()
      return
    end
    self:start_global_timer(left)
  end
  for _, p in ipairs(self.panels) do
    if not (self.gtimer and p.cfg.follows_global) then
      local left = (p.next_at or t) - t
      if left <= 0 then
        p:start_timer()
        p:refresh()
      else
        p:start_timer(left)
      end
    end
  end
  if self.render_skipped then
    self.render_skipped = false
    self:request_render()
  end
  self:update_status()
  require("dbdash.view.sidebar").refresh()
end

function Dashboard:remaining()
  local r
  for _, p in ipairs(self.panels) do
    r = r and math.min(r, p:remaining()) or p:remaining()
  end
  return r or 0
end
