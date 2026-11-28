-- The clock of a dashboard (ARCHITECTURE.md#scheduling): every panel's next tick (show.interval)
-- and the top-level interval's (cfg.refresh_all, a tick for every panel) on one uv timer.
-- A wake sends each due panel one tick (panel:tick), however many deadlines it met: a
-- panel's own deadline and the top-level one at the same moment are one tick. A tick
-- restarts the panel's own count, so a panel whose interval is the top-level one or longer
-- only ever ticks with the others (cfg.follows_global). Only panels whose state says they
-- fetch tick (Panel.state.fetching: a hidden dashboard's databases do not, unless
-- show.refresh_hidden); one that fetches again ticks at once if it came due. The panels'
-- deadlines are theirs (Panel:schedule): the clock asks them to change.
local M = {}

---@class dbdash.Clock
---@field d dbdash.Dashboard
---@field timer uv.uv_timer_t?
---@field catching_up boolean? a catch-up waits for the end of the event (Clock:catch_up)
local Clock = {}
Clock.__index = Clock

local function now()
  vim.uv.update_time()
  return vim.uv.now()
end

---Deadlines this close together are one tick: the timers' own imprecision.
local function slack(interval)
  return math.max(50, math.floor(interval / 100))
end

---The clock of dashboard `d` (it starts with Clock:start).
---@param d dbdash.Dashboard
---@return dbdash.Clock
function M.new(d)
  local clock = setmetatable({ d = d }, Clock)
  d.events:on("panel:state", function(_, st, changed)
    if changed.fetching then
      if st.fetching then
        clock:catch_up()
      else
        clock:arm()
      end
    end
  end)
  return clock
end

---A tick of panel `p`: its count restarts from now.
local function tick(p, t)
  p:schedule(t + p.cfg.show.interval)
  p:emit("panel:tick")
end

---A panel counts on its own: it has a deadline of its own (not only the top-level one).
local function own(p)
  return not (p.d.cfg.refresh_all and p.cfg.follows_global)
end

---Ticks: it fetches (its state).
local function active(p)
  return p.state.fetching
end

---Start: every panel's first tick now, the next ones an interval from now.
function Clock:start()
  self.timer = self.timer or vim.uv.new_timer()
  local d, t = self.d, now()
  if d.cfg.refresh_all then
    d.gnext_at = t + d.cfg.refresh_all
  end
  for _, p in ipairs(d.panels) do
    p:schedule(t + p.cfg.show.interval)
  end
  self:arm()
end

---Restart a panel's count from now (after a tick, or when the user refreshed it).
function Clock:reset(p, t)
  p:schedule((t or now()) + p.cfg.show.interval)
end

---Set the uv timer to the earliest deadline of what ticks now.
function Clock:arm()
  if not self.timer then
    return
  end
  local d, t = self.d, now()
  local at
  local function consider(x)
    if x and (not at or x < at) then
      at = x
    end
  end
  local global_wanted = false
  for _, p in ipairs(d.panels) do
    if not p.ended and active(p) then
      if own(p) then
        consider(p.next_at)
      end
      global_wanted = true
    end
  end
  if d.cfg.refresh_all and global_wanted then
    consider(d.gnext_at)
  end
  self.timer:stop()
  if at then
    self.timer:start(math.max(at - t, 0), 0, function()
      vim.schedule(function()
        if self.timer then
          self:wake()
        end
      end)
    end)
  end
end

---The deadlines that passed: one tick per due panel, then the next deadline.
function Clock:wake()
  local d, t = self.d, now()
  local global = d.cfg.refresh_all and d.gnext_at and t + slack(d.cfg.refresh_all) >= d.gnext_at
  if global then
    d.gnext_at = t + d.cfg.refresh_all
    if not d.paused then
      d.refreshing_all = true -- "…" in the header until every panel is done
    end
  end
  for _, p in ipairs(d.panels) do
    if not p.ended and active(p) then
      local mine = own(p) and p.next_at and t + slack(p.cfg.show.interval) >= p.next_at
      if global and p.retry_at and t < p.retry_at then
        -- backing off after failures: the top-level tick leaves it alone
        p:schedule(p.retry_at)
      elseif global or mine then
        tick(p, t)
      end
    end
  end
  self:arm()
end

---Panels fetch again (shown again): once every panel has said so (after the event that
---changed them), what came due ticks now, the rest keeps its remaining time.
function Clock:catch_up()
  if self.catching_up then
    return
  end
  self.catching_up = true
  vim.schedule(function()
    self.catching_up = false
    self:resume()
  end)
end

---What came due ticks now, the rest keeps its remaining time.
function Clock:resume()
  if not self.timer then
    return
  end
  local d, t = self.d, now()
  if d.cfg.refresh_all and d.gnext_at and d.gnext_at <= t then
    self:wake() -- the top-level interval passed: every panel
    return
  end
  for _, p in ipairs(d.panels) do
    if not p.ended and active(p) and own(p) and p.next_at and p.next_at <= t then
      tick(p, t)
    end
  end
  self:arm()
end

---True while the clock has a deadline ahead (a panel or the top-level interval ticks).
function Clock:running()
  return self.timer ~= nil and self.timer:get_due_in() > 0
end

function Clock:stop()
  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end
end

return M
