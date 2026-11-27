-- A panel (ARCHITECTURE.md#results): a run of its source (db.run: a database queried on its
-- ticks, or a source that sends data), the consumer that takes the results one at a time
-- through query.transform and the rows check, and what it tells (events on its dashboard).
--   panel:tick (the clock)       a waiting database query runs; one while it runs is skipped
--   panel:result / panel:error   a result settled (history, track, thresholds, commit listen)
--   panel:skipped / cancelled    a tick while the query ran / a run cancelled (history)
--   panel:state                  what its status shows changed (commit, the sidebar)
local async = require("dbdash.util.async")
local db = require("dbdash.db")
local errors = require("dbdash.util.error")
local Run = require("dbdash.dashboard.run")
local format_error = errors.format

local M = {}

---@class dbdash.Feed a run of a panel's source and its queue of results
---@field queue table[] results waiting for the consumer
---@field received integer
---@field processed integer
---@field dropped integer
---@field state string "starting" | "running" | "listening ..." | "ended" | "failed"
---@field token dbdash.db.CancelToken stops the run
---@field handle table? db.run's handle
---@field sql string? the rendered query of a source that sends data
---@field busy boolean? the consumer is working
---@field stopped boolean?
---@field ended boolean? the source returned (or failed)
---@field end_error table?
---@field finished boolean?

---@class dbdash.Panel
---@field d dbdash.Dashboard
---@field index integer
---@field cfg dbdash.PanelConfig
---@field push boolean? a push source (shown so)
---@field sends boolean? its source sends data (a driver with produce)
---@field node dbdash.dom.Node the panel's element
---@field chart_node dbdash.dom.Node its chart element
---@field running boolean a query of a tick runs
---@field current dbdash.Run? the run of that query
---@field gen integer the run's number (results of an older run are dropped)
---@field feed dbdash.Feed? the current run
---@field stream dbdash.Feed? the same (read by :DbDashStatus)
---@field waits_ticks boolean? its source waits for ticks
---@field start_tick boolean? the first wait of the run returns at once
---@field waiter fun(go: boolean)? resumes the source waiting for a tick
---@field committed boolean? a result was committed in this period (dashboard/commit.lua)
---@field pending boolean? a result waits for the next tick to be committed
---@field ended boolean? its source ended
---@field next_at integer? loop time (ms) of the next tick
---@field retry_at integer? backing off: the next query not before
---@field backoff_mult integer? the interval's multiple while backing off
---@field failures integer? failures in a row
---@field rs dbdash.db.ResultSet? last successful result
---@field sql string? last rendered query
---@field transform_code string? last rendered query.transform
---@field error table? last error (cleared on success)
---@field history dbdash.HistoryEntry[] (dashboard/history.lua)
---@field style table overrides from :DbDashStyle
---@field runtime_style table? :DbDashStyle rules of the panel
---@field store table `store` of its Lua code
---@field meta table? the metadata of the last run (meta)
---@field values number[]? the values of stat charts (dashboard/track.lua)
---@field levels table<string, integer>? threshold levels reached (dashboard/thresholds.lua)
---@field refresh_count integer? meta.refresh_count
---@field prev table? the record of the last run (meta.prev)
---@field prev_runs table[]?
---@field prev_ok table? the record of the last successful run (meta.prev_ok)
---@field prev_ok_runs table[]?
---@field layout_cache table? (layout/view.lua)
---@field measured table? (layout/view.lua)
local Panel = {}
Panel.__index = Panel
M.Panel = Panel

local function opts()
  return require("dbdash.options").current
end

local function now()
  vim.uv.update_time()
  return vim.uv.now()
end

---A panel of dashboard `d`: it takes its ticks (panel:tick) and restarts when the
---arguments change (dashboard:args).
---@param d dbdash.Dashboard
---@param cfg dbdash.PanelConfig
---@return dbdash.Panel
function M.new(d, index, cfg)
  local p = setmetatable({
    d = d,
    index = index,
    cfg = cfg,
    running = false,
    push = db.driver(cfg.database.type).produce ~= nil or nil, -- a push source (shown so)
    next_at = now(),
    history = {},
    style = {},
    store = {}, -- `store` of the panel's Lua code, for as long as the dashboard runs
  }, Panel)
  d.events:on("panel:tick", function(q)
    if q == p then
      p:on_tick()
    end
  end)
  d.events:on("dashboard:args", function()
    p:restart()
  end)
  return p
end

---Tell something on the dashboard's events (the panel first).
function Panel:emit(event, ...)
  self.d.events:emit(event, self, ...)
end

---Seconds until the panel's next refresh.
function Panel:remaining()
  if not self.next_at then
    return 0
  end
  return math.max(0, math.ceil((self.next_at - now()) / 1000))
end

---Title used in headers, status and pickers.
function Panel:title()
  local t = self.cfg.show.title
  if t and t ~= "" then
    return t
  end
  return ("Panel %d"):format(self.index)
end

---The effective show config (config file + :DbDashStyle overrides).
function Panel:show_config()
  if next(self.style) == nil then
    return self.cfg.show
  end
  local show = vim.deepcopy(self.cfg.show)
  for k, v in pairs(self.style) do
    show[k] = v
  end
  return show
end

---A visible argument of the panel by name (a local one shadows a shared one).
function Panel:arg_spec(name)
  for _, spec in ipairs(self.cfg.visible_args) do
    if spec.name == name then
      return spec
    end
  end
end

---A run of the panel's pipeline (dashboard/run.lua).
---@param kind "refresh"|"callback"|"push"|"render"?
---@return dbdash.Run
function Panel:new_run(values, parent, kind)
  return Run.new(self, values, parent, kind)
end

-- The run -----------------------------------------------------------------------------

---The options of the panel's queries: the same for every query of a run, and those of one
---run (its arguments, meta and Lua globals).
---@param run dbdash.Run?
function Panel:query_opts(run)
  local q = self.cfg.query
  local o = {
    max_rows = q.max_rows,
    timeout = q.timeout,
    options = self.cfg.database.options,
    base_dir = self.d.cfg.dir,
    password_cmd = self.cfg.database.password_cmd,
    source = vim.fn.fnamemodify(self.d.path, ":~:."),
    line = q.sql_line,
    raw = q.transform ~= nil, -- the transform gets the raw result; checked after it
    -- curl -c writes a cookie file: allowed when the config was trusted for it
    allow_writes = self.d.writes_trusted == true,
    -- failures in a row back off (db/driver.lua); a restarted run goes on counting
    interval = self.cfg.show.interval,
    backoff = opts().errors.backoff,
    failures = self.failures,
  }
  if run then
    o.args, o.meta, o.lua = run.args, run.meta, run.lua
    o.cancel = run.life.cancel -- cancelling the run stops the query
  end
  return o
end

---A new run of the panel, rendered for one query (on a tick): its sql, the run (passed
---along with the result) and the options of its query. Inside the source's task; raises
---template errors (the run is self.current).
function Panel:prepare_run()
  local run = self:new_run()
  self.current = run
  self.running = true
  self.refresh_count = (self.refresh_count or 0) + 1 -- meta.refresh_count
  self:emit("panel:state")
  local sql, code = run:render_templates()
  run.record.sql, run.code = sql, code
  if run.depth == 0 then
    self.sql, self.transform_code = sql, code
  end
  return sql, run, { args = run.args, meta = run.meta, lua = run.lua }
end

---Wait in the source's task for the panel's next tick; false when the run stopped. The
---first wait of a run returns at once. `not_before`: the source backs off after `failures`
---failures in a row (db/driver.lua): its next query not before then (the clock's deadline
---for the panel, its countdown and :DbDashStatus show it).
function Panel:wait_tick(gen, not_before, failures)
  if gen ~= self.gen then
    return false
  end
  self:back_off(not_before, failures)
  self.waits_ticks = true
  if self.start_tick then
    self.start_tick = false
    return true
  end
  local go = async.await(function(cb)
    self.waiter = cb
  end)
  return go == true and gen == self.gen
end

---Back off until `not_before` (nil: back to the interval).
function Panel:back_off(not_before, failures)
  self.failures = failures
  local clock = self.d.clock
  if not_before and (self.d.paused and not self.cfg.show.refresh_hidden) then
    return -- hidden: no ticks to wait for
  end
  local was = self.retry_at ~= nil
  local interval = self.cfg.show.interval
  self.retry_at = not_before
  self.backoff_mult = not_before and math.floor((not_before - now()) / interval + 0.5) or nil
  if not_before then
    self.next_at = not_before
  elseif was and clock then
    clock:reset(self)
  end
  if clock and (not_before or was) then
    clock:arm()
    self:emit("panel:state")
  end
end

---A tick (panel:tick from the clock): a source waiting for it queries now; one that is
---still querying skips it (and it is recorded).
function Panel:on_tick()
  local w = self.waiter
  if w and not self.running then
    self.waiter = nil
    w(true)
  elseif self.waits_ticks and not self.ended then
    self:emit("panel:skipped")
  end
end

---(Re)start the panel's source: a new run (the old one, if any, stops first).
function Panel:start()
  self:stop_run("restarted")
  local gen = self.gen
  local driver = db.driver(self.cfg.database.type)
  -- A source that sends data runs its query (rendered once) until it ends; a database is
  -- queried on every tick of the panel.
  self.sends = driver.produce ~= nil
  local feed = {
    queue = {},
    received = 0,
    processed = 0,
    dropped = 0,
    state = "starting",
    token = require("dbdash.db.cancel").new(),
  }
  self.feed = feed
  self.stream = feed -- :DbDashStatus reads the counts as `stream`
  self.waits_ticks, self.start_tick, self.waiter = false, true, nil
  self.committed, self.pending = false, false -- a new period
  if self.sends then
    self.error = nil
    self.ended = nil
  end
  local o = self:query_opts()
  o.cancel = feed.token
  o.on_status = function(text)
    if self.gen == gen then
      feed.state = text
      self:emit("panel:state")
    end
  end
  local query
  if self.sends then
    query = function()
      -- rendered once per start (the arguments and meta of that moment)
      local run = self:new_run(nil, nil, "render")
      local to = run:template_opts()
      to.cancel = feed.token
      local q = self.cfg.query
      feed.sql = Run.render_text(
        self.d,
        q.sql,
        q.sql_line,
        vim.tbl_extend("force", to, { autoescape = q.autoescape })
      )
      o.args, o.meta, o.lua = run.args, run.meta, run.lua
      if feed.state == "starting" then
        feed.state = "running"
      end
      return feed.sql
    end
  else
    feed.state = "running"
    query = function()
      return self:prepare_run()
    end
    o.wait_tick = function(not_before, failures)
      return self:wait_tick(gen, not_before, failures)
    end
  end
  feed.handle = db.run(self.cfg.database.url, query, o, function(err, v, vars, run)
    self:on_result(gen, err, v, vars, run)
  end, function(err)
    self:on_end(gen, err)
  end)
  self:emit("panel:state")
end

---Restart: the user asked (r, changed arguments). A query running is cancelled.
---@param reason string?
function Panel:restart(reason)
  self:cancel(reason or "replaced by a new refresh")
  self:start()
end

---Stop the run: results still queued are dropped, and late ones.
---@param reason string?
function Panel:stop_run(reason)
  local feed = self.feed
  self.gen = (self.gen or 0) + 1
  local w = self.waiter
  if w then
    self.waiter = nil
    w(false)
  end
  if feed and not feed.stopped then
    feed.stopped = true
    feed.queue = {}
    feed.token:cancel(reason or "stopped")
  end
end

---Cancel what runs (dashboard stopped, restarted): the run stops, a query running is
---closed as cancelled with the reason (meta.prev); the panel shows no error.
---@param reason string
function Panel:cancel(reason)
  self:stop_run(reason)
  local run = self.current
  if not run then
    return
  end
  self.current = nil
  self.running = false
  run.life.cancel:cancel(reason)
  run:finish(errors.new({ phase = "cancelled", message = "query cancelled: " .. reason }))
  self.prev, self.prev_runs = run.record, run.life.runs
  self:emit("panel:cancelled", reason)
  run.life.cancel:release()
end

-- The consumer --------------------------------------------------------------------------

---A result of the run (on the main loop): queued, then taken by the consumer.
function Panel:on_result(gen, err, value, vars, run)
  local feed = self.feed
  if gen ~= self.gen or not feed or feed.stopped then
    return
  end
  feed.received = feed.received + 1
  local max = opts().push.max_queue
  if max and #feed.queue >= max then
    table.remove(feed.queue, 1)
    feed.dropped = feed.dropped + 1
  end
  feed.queue[#feed.queue + 1] = { err = err, value = value, vars = vars, run = run }
  self:consume(gen, feed)
end

---The consumer: one task taking the queued results in order, one at a time, through
---query.transform and the rows check to settle().
---@param feed dbdash.Feed
function Panel:consume(gen, feed)
  if feed.busy then
    return
  end
  feed.busy = true
  async.run(function()
    while self.gen == gen and not feed.stopped and #feed.queue > 0 do
      local item = table.remove(feed.queue, 1)
      local run = item.run or (item.err and self.current) or nil
      if not run then -- an item of a source that sends data
        run = self:new_run(nil, nil, "push")
        run.item = { value = item.value, vars = item.vars }
        self.refresh_count = (self.refresh_count or 0) + 1 -- meta.refresh_count
      end
      local err, rs = item.err, nil
      if not err then
        local ok, res = pcall(self.apply_transform, self, run, item.value)
        if ok then
          rs = res
        else
          err = res
        end
      end
      self:settle(run, err and errors.wrap(err) or nil, rs)
    end
  end, function(err)
    feed.busy = false
    if err then
      self:emit("panel:error", errors.wrap(err), { always = true, internal = true })
    end
    if self.gen == gen and feed.ended then
      self:finish_feed(feed)
    end
  end)
end

---The run of a callback (dbdash.run()) at once: a database is queried with the callback's
---arguments; an item of a source that sends data is taken again. Inside a task.
---@param run dbdash.Run
---@return dbdash.db.ResultSet
function Panel:pipeline(run)
  if run.item then
    return self:apply_transform(run, run.item.value)
  end
  local sql, code = run:render_templates()
  run.record.sql, run.code = sql, code
  local rs = db.query_async(self.cfg.database.url, sql, self:query_opts(run))
  return self:apply_transform(run, rs)
end

---query.transform on a result, and the rows check. Inside a task. A query's result: the
---transform rendered with the query; an item of a source that sends data: the transform
---rendered for it (without one, db.run made the item rows already).
---@param run dbdash.Run
function Panel:apply_transform(run, value)
  local q = self.cfg.query
  local lua_result = require("dbdash.db.lua_result")
  local started = vim.uv.hrtime()
  local rs = value
  if run.item then
    local o = run:template_opts()
    run.record.sql = self.feed and self.feed.sql
    -- the item as it came (rows made from it keep it as .item)
    local raw = type(value) == "table" and value.item
    run.record.query = raw ~= nil and raw or value
    run.code = q.transform and Run.render_text(self.d, q.transform, q.transform_line, o) or nil
    if run.code then
      rs = lua_result.raw(value, run.item.vars)
    end
  else
    -- the query's own result (before query.transform): rows as Lua data, or the raw value
    run.record.query = lua_result.is_raw(rs) and rs.value or lua_result.to_lua(rs)
  end
  if run.code then
    local out = M.transform(run.code, rs, {
      source = vim.fn.fnamemodify(self.d.path, ":~:."),
      line = q.transform_line,
      args = run.args,
      meta = run.meta,
      lua = run.lua,
      timeout = q.timeout or require("dbdash.options").default_ms("timeout"),
      max_rows = q.max_rows or opts().defaults.max_rows,
      cancel = run.life.cancel,
    })
    out.elapsed_ms = rs.elapsed_ms
    rs = out
  end
  if run.item then
    rs.elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  end
  run.record.result = lua_result.to_lua(rs)
  return rs
end

---Run query.transform on a query result and check its value as rows. `rs` is a result set
---(given to the script as plain data) or a driver's raw result (given as is, with the
---driver's extra variables such as http's `response`). Inside a util.async task.
---@return dbdash.db.ResultSet
function M.transform(code, rs, o)
  local lua_result = require("dbdash.db.lua_result")
  local vars
  if lua_result.is_raw(rs) then
    vars = vim.tbl_extend("force", {}, rs.vars, { rs = rs.value })
  else
    vars = { rs = lua_result.to_lua(rs) }
  end
  local value = require("dbdash.db.lua_env").run(code, {
    phase = "transform",
    source = o.source,
    line = o.line,
    args = o.args,
    meta = o.meta,
    lua = o.lua,
    vars = vars,
    timeout = o.timeout,
    cancel = o.cancel,
  })
  return lua_result.normalize(value, { max_rows = o.max_rows, phase = "transform" })
end

---The end of one result: its record, then the result (panel:result) or the error
---(panel:error); the source is told how it went (a database backs off after failures).
function Panel:settle(run, err, rs)
  local ticked = run.record.kind == "refresh"
  if ticked and self.current == run then
    self.running = false
    self.current = nil
  end
  local feed = self.feed
  if feed then
    feed.processed = feed.processed + 1
  end
  run:finish(err)
  self.prev, self.prev_runs = run.record, run.life.runs
  run.life.cancel:release()
  if err then
    local changed = not self.error or format_error(self.error) ~= format_error(err)
    self.error = err
    self:emit("panel:error", err, { changed = changed })
  else
    self.prev_ok, self.prev_ok_runs = run.record, run.life.runs
    self.rs = rs
    self.error = nil
    self:emit(
      "panel:result",
      rs,
      { elapsed_ms = ticked and rs.elapsed_ms or run.record.elapsed_ms }
    )
  end
  if ticked then
    self:emit("panel:state")
  end
  if feed and feed.handle and run.depth == 0 then
    feed.handle:report(err == nil) -- the source counts failures in a row
  end
end

---The run ended (a source that sends data returned or failed): finish once the queue is
---drained.
function Panel:on_end(gen, err)
  local feed = self.feed
  if gen ~= self.gen or not feed then
    return
  end
  if err and err.phase == "cancelled" and feed.stopped then
    return -- stopped on purpose
  end
  feed.ended = true
  feed.end_error = err
  if not feed.busy then
    self:finish_feed(feed)
  end
end

---The panel stops: the state "ended" or "failed", its last result committed now.
function Panel:finish_feed(feed)
  if feed.finished then
    return
  end
  feed.finished = true
  feed.state = feed.end_error and "failed" or "ended"
  self.ended = true
  self.running = false
  self.next_at = nil
  if feed.end_error then
    self.error = feed.end_error
    self:emit("panel:error", feed.end_error, { always = true })
  end
  self:emit("panel:state")
end

---What a push panel is doing, for its header: "running", "listening 127.0.0.1:8765",
---"ended", "failed" (nil for other panels).
function Panel:push_state()
  if not self.push then
    return nil
  end
  local st = self.feed
  return st and st.state or "stopped"
end

-- Templates outside a run ---------------------------------------------------------------

---The panel's show.description rendered with its arguments and metadata (Markdown).
function Panel:describe_async(cb)
  local show = self.cfg.show
  Run.describe_async(function()
    local run = self:new_run(nil, nil, "render")
    run.read_only = true -- showing a description does not change arguments
    return Run.render_text(self.d, show.description, show.description_line, {
      dialect = require("dbdash.template.dialect").get(db.driver(self.cfg.database.type).dialect),
      specs = self.cfg.visible_args,
      values = run.args,
      meta = require("dbdash.metadata").values(self, run),
      lua = run.lua,
      set_arg = function(name, v)
        run:set_arg(name, v)
      end,
      timeout = self.cfg.query.timeout,
    })
  end, cb)
end

---Render the templates in a task; `cb(err, sql, transform_code)` on the main loop.
function Panel:render_async(cb)
  async.run(function()
    return self:new_run(nil, nil, "render"):render_templates()
  end, function(err, sql, code)
    vim.schedule(function()
      if not err then
        self.sql, self.transform_code = sql, code
      end
      cb(err, sql, code)
    end)
  end)
end

return M
