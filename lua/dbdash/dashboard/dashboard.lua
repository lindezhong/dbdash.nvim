-- A dashboard (the model, ARCHITECTURE.md#state): its panels, its document, its clock, its
-- events and its state (Dashboard.state: the sum of its panels' states, of which it is the
-- only writer). What it tells, on d.events (listeners get the panel first):
--   panel:*                  dashboard/panel.lua
--   dashboard:args           the arguments changed: the clock and every panel start again
--   dashboard:hidden/shown   no window shows it / shown again: each panel's state follows
-- and on dashboard/events.lua (every dashboard):
--   dashboard:state          what it sums changed: running, visible, fetching
local Panel = require("dbdash.dashboard.panel")
local args = require("dbdash.args")

local M = {}

---@class dbdash.DashboardState the sum of a dashboard's panels (ARCHITECTURE.md#state)
---@field path string the config file
---@field title string? the dashboard's title
---@field running boolean started (false: told once more when it stops)
---@field visible boolean a window of the current tab page shows it
---@field fetching "all"|"some"|"none" its panels' state.fetching
---@field panels table<string, dbdash.PanelState> by panel id

---@class dbdash.Dashboard
---@field path string
---@field cfg dbdash.Config
---@field state dbdash.DashboardState its state (dashboard:state tells it)
---@field arg_state dbdash.ArgState its arguments' values
---@field panels dbdash.Panel[]
---@field events dbdash.Emitter what the dashboard and its panels tell
---@field doc dbdash.dom.Document its document (dashboard/document.lua)
---@field header_node dbdash.dom.Node
---@field clock dbdash.Clock the panels' ticks and the top-level interval's (dashboard/timer.lua)
---@field paused boolean? hidden
---@field gnext_at integer? loop time (ms) of the next top-level tick
---@field refreshing_all boolean? the top-level tick's queries run ("…")
---@field writes_trusted boolean? the config was trusted with what it writes (curl -c files)
---@field runtime_style table? :DbDashStyle rules of the dashboard
---The view's (view/dashboard.lua):
---@field buf integer
---@field ctimer uv.uv_timer_t? countdown display timer
---@field regions table[]? buffer regions of the panels
---@field header_slot table? where the top-level countdown goes (view/dashboard.update_status)
---@field status_slots table[]? where each panel's status goes
---@field hits table[]? hit-test regions (events/)
---@field header_rows integer?
---@field last_size integer[]?
---@field last_render_at integer?
---@field last_restyle table?
---@field render_pending boolean?
---@field render_skipped boolean? a frame waits for the dashboard to be shown
local Dashboard = {}
Dashboard.__index = Dashboard
M.Dashboard = Dashboard

---A dashboard of a loaded config with its argument state; Dashboard:start runs it.
---@param path string
---@param cfg dbdash.Config
---@param state dbdash.ArgState
---@return dbdash.Dashboard
function M.new(path, cfg, state)
  local d = setmetatable({
    path = path,
    cfg = cfg,
    arg_state = state,
    panels = {},
    events = require("dbdash.util.emitter").new(),
    -- curl -c in its queries: trusted (or trust is not required here)
    writes_trusted = require("dbdash.trust").writes(cfg),
  }, Dashboard)
  -- the listeners in order: the clock restarts first when the arguments change
  d.clock = require("dbdash.dashboard.timer").new(d)
  d.events:on("dashboard:args", function()
    d.clock:start()
  end)
  for i, pc in ipairs(cfg.panels) do
    d.panels[i] = Panel.new(d, i, pc)
  end
  d.state = {
    path = path,
    title = cfg.title,
    running = false,
    visible = true,
    fetching = "none",
    panels = {},
  }
  for _, p in ipairs(d.panels) do
    d.state.panels[p.state.id] = p.state
  end
  -- the sum follows its panels
  d.events:on("panel:state", function(_, _, changed)
    if changed.fetching then
      d:set_state({ fetching = d:sum_fetching() })
    end
  end)
  require("dbdash.dashboard.document").dashboard(d) -- d.doc
  -- a result is recorded, kept and checked before it is committed
  require("dbdash.dashboard.history").attach(d)
  require("dbdash.dashboard.track").attach(d)
  require("dbdash.dashboard.thresholds").attach(d)
  require("dbdash.dashboard.commit").attach(d)
  return d
end

---Commit everything into the document (a changed style: :DbDashStyle).
function Dashboard:commit()
  require("dbdash.dashboard.commit").all(self)
end

-- The state -------------------------------------------------------------------------------

---"all", "some" or "none" of its panels fetch.
---@return "all"|"some"|"none"
function Dashboard:sum_fetching()
  local n = 0
  for _, p in ipairs(self.panels) do
    n = n + (p.state.fetching and 1 or 0)
  end
  return n == 0 and "none" or (n == #self.panels and "all" or "some")
end

---Set fields of the dashboard's state and tell what changed, the state whole
---(dashboard:state on dashboard/events.lua). Nothing changed: nothing is told.
function Dashboard:set_state(fields)
  local st, changed = self.state, nil
  for k, v in pairs(fields) do
    if st[k] ~= v then
      changed = changed or {}
      changed[k] = true
      st[k] = v
    end
  end
  if changed then
    require("dbdash.dashboard.events"):emit("dashboard:state", self, st, changed)
  end
end

---Start the clock and every panel's source (its first query now).
function Dashboard:start()
  self:commit()
  self.clock:start()
  for _, p in ipairs(self.panels) do
    p:start()
  end
  self:set_state({ running = true, fetching = self:sum_fetching() })
end

---Refresh every panel now (r): a query running is cancelled, and every panel counts its
---interval from now.
function Dashboard:restart()
  self.clock:start()
  for _, p in ipairs(self.panels) do
    p:restart()
  end
end

---Stop: the clock stops and what runs is cancelled.
---@param reason string
function Dashboard:stop(reason)
  self.clock:stop()
  for _, p in ipairs(self.panels) do
    p:cancel(reason)
  end
  self:set_state({ running = false, fetching = self:sum_fetching() })
end

-- Arguments: a change restarts the dashboard (dashboard:args) ----------------------------

---Set an argument by key ("name" shared, "<panel>.name" local).
function Dashboard:set_arg(key, value)
  args.set_modified(self.arg_state, key, value)
  self.events:emit("dashboard:args")
end

---Set arguments by key at once.
---@param values table<string, any>
function Dashboard:set_args(values)
  for key, v in pairs(values) do
    args.set_modified(self.arg_state, key, v)
  end
  self.events:emit("dashboard:args")
end

---Command-line values (name=value) over the config's defaults.
---@param cli table<string, any>
function Dashboard:set_cli(cli)
  for k, v in pairs(cli) do
    self.arg_state.cli[k] = v
  end
  self.events:emit("dashboard:args")
end

---Back to the command line's and the config's values.
function Dashboard:reset_args()
  args.reset(self.arg_state)
  self.events:emit("dashboard:args")
end

---Set argument values given as text (a session); returns true if any was applied.
---@param values table<string, string>
---@param quiet boolean? apply them without telling (before the dashboard starts)
function Dashboard:apply_args(values, quiet)
  local applied = false
  for key, text in pairs(values) do
    -- By key ("name" shared, "<panel>.name" local); a key of no argument (sessions from
    -- before local arguments) sets every argument of that name.
    local specs = {}
    if type(text) == "string" and type(key) == "string" then
      local spec = args.find(self.cfg.args, key)
      specs = spec and { spec } or args.match(self.cfg.args, key)
    end
    for _, spec in ipairs(specs) do
      local ok, v = pcall(args.parse_value, spec, text)
      if ok then
        args.set_modified(self.arg_state, spec.key or spec.name, v)
        applied = true
      end
    end
  end
  if applied and not quiet then
    self.events:emit("dashboard:args")
  end
  return applied
end

-- Visibility -----------------------------------------------------------------------------

---No window of the current tab page shows the dashboard: only show.refresh_hidden panels
---keep refreshing (dashboard:hidden).
function Dashboard:pause()
  if self.paused then
    return
  end
  self.paused = true
  self.events:emit("dashboard:hidden")
  self:set_state({ visible = false })
end

---Shown again: what came due while hidden refreshes now, the rest keeps its remaining time
---(dashboard:shown).
function Dashboard:resume()
  if not self.paused then
    return
  end
  self.paused = false
  self.events:emit("dashboard:shown")
  self:set_state({ visible = true })
end

-- What :DbDashStatus and the sidebar show ------------------------------------------------

---State summary across panels (their states): "paused", "retrying", "running query",
---"error" or "idle".
function Dashboard:status_word()
  if not self.state.visible then
    return "paused"
  end
  local function any(test)
    for _, p in ipairs(self.panels) do
      if test(p.state) then
        return true
      end
    end
    return false
  end
  if any(function(st)
    return st.activity == "retrying"
  end) then
    return "retrying"
  elseif any(function(st)
    return st.activity == "querying"
  end) then
    return "running query"
  elseif any(function(st)
    return st.error ~= nil
  end) then
    return "error"
  end
  return "idle"
end

---Seconds until the next refresh of any panel.
function Dashboard:remaining()
  local r
  for _, p in ipairs(self.panels) do
    r = r and math.min(r, p:remaining()) or p:remaining()
  end
  return r or 0
end

---Seconds until the next refresh of every panel (the top-level interval).
function Dashboard:remaining_global()
  if not self.gnext_at then
    return 0
  end
  vim.uv.update_time()
  return math.max(0, math.ceil((self.gnext_at - vim.uv.now()) / 1000))
end

---The dashboard's description rendered with the shared arguments and the metadata
---outside any panel (db_* of the top-level database).
function Dashboard:describe_async(cb)
  local Run = require("dbdash.dashboard.run")
  Run.describe_async(function()
    return Run.render_text(
      self,
      self.cfg.description,
      self.cfg.description_line,
      Run.dashboard_opts(self)
    )
  end, cb)
end

return M
