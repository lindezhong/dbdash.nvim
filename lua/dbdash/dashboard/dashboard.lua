-- Dashboards: their clock (dashboard/timer.lua), refreshing every panel, pause and resume.
local S = require("dbdash.dashboard.shared")
local Dashboard = S.Dashboard
local opts, close_timer = S.opts, S.close_timer

---The countdown display: updated every countdown_interval while shown.
local function start_countdowns(d)
  d.ctimer = vim.uv.new_timer()
  local every = opts().countdown_interval
  d.ctimer:start(every, every, function()
    vim.schedule(function()
      if d.ctimer then
        d:update_status()
      end
    end)
  end)
end

---Refresh every panel now (r, changed arguments): a query running is cancelled, and every
---panel counts its interval from now.
function Dashboard:restart()
  if self.clock then
    self.clock:start()
  end
  for _, p in ipairs(self.panels) do
    p:restart()
  end
end

---Start the dashboard's clock and every panel's source (its first query now).
function Dashboard:start_timers()
  start_countdowns(self)
  self.clock = require("dbdash.dashboard.timer").new(self)
  self.clock:start()
  for _, p in ipairs(self.panels) do
    p:start()
  end
end

---Cancel what runs in the dashboard's panels (Panel:cancel).
---@param reason string
function Dashboard:cancel(reason)
  for _, p in ipairs(self.panels) do
    p:cancel(reason)
  end
end

function Dashboard:stop_timers()
  close_timer(self.ctimer)
  self.ctimer = nil
  if self.clock then
    self.clock:stop()
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

---Stop refreshing while no window of the current tab page shows the dashboard
---(show.refresh_hidden panels keep refreshing).
function Dashboard:pause()
  if self.paused then
    return
  end
  self.paused = true
  close_timer(self.ctimer)
  self.ctimer = nil
  if self.clock then
    self.clock:pause()
  end
  require("dbdash.view.sidebar").refresh()
end

---Continue after pause(): what came due while hidden refreshes now, the rest keeps its
---remaining time.
function Dashboard:resume()
  if not self.paused then
    return
  end
  self.paused = false
  start_countdowns(self)
  if self.clock then
    self.clock:resume()
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
