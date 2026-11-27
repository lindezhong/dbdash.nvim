-- Dashboards: their clock (dashboard/timer.lua), refreshing every panel, pause and resume.
local S = require("dbdash.dashboard.shared")
---@class dbdash.Dashboard
local Dashboard = S.Dashboard
local events = require("dbdash.dashboard.events")

---Commit (dashboard/document.lua): the document takes the dashboard's state; a panel whose
---result settled is laid out again (its chart's values may change with the same result).
---@param p dbdash.Panel?
function Dashboard:commit(p)
  if not self.doc then
    return
  end
  require("dbdash.dashboard.document").sync(self)
  if p and p.chart_node then
    p.chart_node:dirty("content")
  end
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
  if self.clock then
    self.clock:pause()
  end
  events:emit("paused", self)
end

---Continue after pause(): what came due while hidden refreshes now, the rest keeps its
---remaining time.
function Dashboard:resume()
  if not self.paused then
    return
  end
  self.paused = false
  if self.clock then
    self.clock:resume()
  end
  events:emit("resumed", self)
end

function Dashboard:remaining()
  local r
  for _, p in ipairs(self.panels) do
    r = r and math.min(r, p:remaining()) or p:remaining()
  end
  return r or 0
end
