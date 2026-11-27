-- Panels: a run of the panel's source (db.run: queried on ticks, or sending data), its
-- results through query.transform and the rows check, one at a time, and their records.
local M = require("dbdash.dashboard")
local S = require("dbdash.dashboard.shared")
local Panel = S.Panel
local opts, notify, now, as_error = S.opts, S.notify, S.now, S.as_error
local async = require("dbdash.util.async")
local db = require("dbdash.db")

-- Panels -----------------------------------------------------------------------------------

function Panel:push_history(entry)
  entry.at = os.time()
  table.insert(self.history, 1, entry)
  while #self.history > opts().defaults.history do
    table.remove(self.history)
  end
end

---Keep the panel's value for stat charts (change since the previous refresh, sparkline).
function Panel:track(rs)
  local show = self.cfg.show
  if show.type ~= "stat" then
    return
  end
  local C = require("dbdash.render.charts.stat.common")
  local v = C.track(rs, show)
  if v then
    self.values = self.values or {}
    table.insert(self.values, v)
    local keep = math.max(
      C.HISTORY,
      tonumber(show.sparkline_length ~= vim.NIL and show.sparkline_length or nil) or 0
    )
    while #self.values > keep do
      table.remove(self.values, 1)
    end
  end
end

---Notify once when a value rises to a threshold step with notify = true (it notifies
---again after falling back and crossing it again).
function Panel:check_thresholds(rs)
  local T = require("dbdash.render.thresholds")
  local ok, levels = pcall(T.levels, rs, self.cfg.show)
  if not ok then
    return
  end
  self.levels = self.levels or {}
  for key, cur in pairs(levels) do
    local prev = self.levels[key] or 0
    if cur.level > prev and cur.step and cur.step.notify then
      local t = self.cfg.show.title
      local title = (t and t ~= "") and t
        or self.d.cfg.title
        or (self.d.cfg.grid and self:title() or vim.fn.fnamemodify(self.d.path, ":t"))
      local what = cur.column and (cur.column .. " = ") or ""
      local value = require("dbdash.render.table").format_value(cur.value, nil, "NULL")
      vim.notify(
        ("dbdash: %s: %s%s %s %s"):format(
          title,
          what,
          value,
          cur.below and "≤" or "≥",
          require("dbdash.util.number").numstr(cur.step.value)
        ),
        vim.log.levels.WARN
      )
    end
    self.levels[key] = cur.level
  end
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

---Delay before the next try after `failures` consecutive failures: the interval doubled
---per failure after the first, at most interval x factor (errors.backoff).
---@return integer ms
function M.backoff_delay(interval, failures, factor)
  local mult = math.min(2 ^ math.max(failures - 1, 0), math.max(factor or 1, 1))
  return math.floor(interval * mult)
end

-- The run --------------------------------------------------------------------------------

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
  self.d:update_status()
  local sql, code = self:render_templates(run)
  run.record.sql, run.code = sql, code
  if run.depth == 0 then
    self.sql, self.transform_code = sql, code
  end
  return sql, run, { args = run.args, meta = run.meta, lua = run.lua }
end

---Wait in the source's task for the panel's next tick; false when the run stopped. The
---first wait of a run returns at once.
function Panel:wait_tick(gen)
  if gen ~= self.gen then
    return false
  end
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

---A tick (dashboard/timer.lua): a source queried on ticks queries now (a tick while its
---query runs is skipped); a result waiting to be shown is drawn.
function Panel:on_tick()
  if self.waiter and not self.running then
    local w = self.waiter
    self.waiter = nil
    w(true)
  elseif self.waits_ticks and not self.ended then
    self:push_history({ skipped = true })
  end
  if self.dirty then
    self.dirty = false
    self.d:request_render()
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
  if self.sends then
    self.error = nil
    self.ended = nil
  end
  local o = self:query_opts()
  o.cancel = feed.token
  o.on_status = function(text)
    if self.gen == gen then
      feed.state = text
      self.d:update_status()
    end
  end
  local query
  if self.sends then
    query = function()
      -- rendered once per start (the arguments and meta of that moment)
      local run = self:new_run(nil, nil, "render")
      local to = self:template_opts(run)
      to.cancel = feed.token
      local q = self.cfg.query
      feed.sql = M.render_text(
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
    o.wait_tick = function()
      return self:wait_tick(gen)
    end
  end
  feed.handle = db.run(self.cfg.database.url, query, o, function(err, v, vars, run)
    self:on_result(gen, err, v, vars, run)
  end, function(err)
    self:on_end(gen, err)
  end)
  self.d:request_render()
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
  if self.waiter then
    local w = self.waiter
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
  local message = "query cancelled: " .. reason
  self:finish_record(
    run,
    require("dbdash.util.error").new({ phase = "cancelled", message = message })
  )
  self.prev, self.prev_runs = run.record, run.life.runs
  self:push_history({ cancelled = reason })
  run.life.cancel:release()
end

---A timer tick (refresh()) or a requested refresh (refresh({ queue = true }): restart).
---@param o { queue: boolean? }?
function Panel:refresh(o)
  if o and o.queue then
    self:restart()
  else
    self:on_tick()
  end
end

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
  self:consume(gen)
end

---The consumer: one task taking the queued results in order, one at a time, through
---query.transform and the rows check to settle().
function Panel:consume(gen)
  local feed = self.feed
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
        local ok, res
        if run.item then
          ok, res = pcall(self.push_pipeline, self, run)
        else
          ok, res = pcall(self.apply_transform, self, run, item.value)
        end
        if ok then
          rs = res
        else
          err = res
        end
      end
      self:settle(run, err and as_error(err) or nil, rs)
    end
  end, function(err)
    feed.busy = false
    if err then
      notify(as_error(err))
    end
    if self.gen == gen and feed.ended then
      self:finish_feed(feed)
    end
  end)
end

---The run of a callback (dbdash.run()) at once: render, query, transform. Inside a task.
---@param run dbdash.Run
---@return dbdash.db.ResultSet
function Panel:pipeline(run)
  if run.item then
    return self:push_pipeline(run) -- a callback of an item works on the item too
  end
  local sql, code = self:render_templates(run)
  run.record.sql, run.code = sql, code
  local rs = db.query_async(self.cfg.database.url, sql, self:query_opts(run))
  return self:apply_transform(run, rs)
end

---query.transform (rendered with the run's query) on a query's result, and the rows
---check. Inside a task.
function Panel:apply_transform(run, rs)
  local q = self.cfg.query
  local lua_result = require("dbdash.db.lua_result")
  -- The query's own result (before query.transform): rows as Lua data, or the raw value.
  run.record.query = lua_result.is_raw(rs) and rs.value or lua_result.to_lua(rs)
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
  run.record.result = lua_result.to_lua(rs)
  return rs
end

---An error of a result: notified (errors.notify). A source queried on ticks backs off:
---after failures in a row its next query waits longer (errors.backoff).
function Panel:fail(err)
  local changed = not self.error or M.format_error(self.error) ~= M.format_error(err)
  self.error = err
  local mode = opts().errors.notify
  if mode == "always" or (mode == "once" and changed) then
    notify(err)
  end
  if not self.waits_ticks then
    return
  end
  self.failures = (self.failures or 0) + 1
  local interval = self.cfg.show.interval
  local delay = M.backoff_delay(interval, self.failures, opts().errors.backoff)
  if delay > interval and (not self.d.paused or self.cfg.show.refresh_hidden) then
    self.retry_at = now() + delay
    self.backoff_mult = math.floor(delay / interval + 0.5)
    self.next_at = self.retry_at
    if self.d.clock then
      self.d.clock:arm()
    end
  end
end

---The end of one result: its record, then the result or the error. A result of a tick's
---query is drawn at once; one the source sent waits for the panel's next tick.
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
  self:finish_record(run, err)
  self.prev, self.prev_runs = run.record, run.life.runs
  run.life.cancel:release()
  if err then
    self:push_history({ error = M.format_error(err) })
    self:fail(err)
  else
    self.prev_ok, self.prev_ok_runs = run.record, run.life.runs
    local elapsed = ticked and rs.elapsed_ms or run.record.elapsed_ms
    self:push_history({ elapsed_ms = elapsed, rows = rs.row_count })
    self.rs = rs
    if (self.failures or 0) > 0 then
      local was_backing_off = self.retry_at ~= nil
      self.failures, self.retry_at, self.backoff_mult = 0, nil, nil
      if was_backing_off and self.d.clock then
        self.d.clock:reset(self)
        self.d.clock:arm()
      end
    end
    self:track(rs)
    self:check_thresholds(rs)
    self.error = nil
  end
  if not ticked then
    self.dirty = true
  elseif err and not self.d.cfg.grid then
    self.d:update_status()
  else
    self.d:request_render()
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

---The panel stops: the last result drawn now, the state "ended" or "failed".
function Panel:finish_feed(feed)
  if feed.finished then
    return
  end
  feed.finished = true
  feed.state = feed.end_error and "failed" or "ended"
  self.ended = true
  self.running = false
  if feed.end_error then
    self.error = feed.end_error
    self:push_history({ error = M.format_error(feed.end_error) })
    notify(feed.end_error)
  end
  self.next_at = nil
  self.dirty = false
  self.d:request_render()
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

---Close a run's record: finished_at, elapsed_ms, ok and error.
function Panel:finish_record(run, err)
  local r = run.record
  r.finished_at = require("dbdash.util.uuid").now_ms()
  r.elapsed_ms = r.finished_at - r.started_at
  r.ok = err == nil
  r.error = err ~= nil and M.format_error(as_error(err)) or nil
  run.life.version = run.life.version + 1
end

---The pipeline of one pushed item: query.transform (rendered for this run) on the item,
---or the item as JSON rows. Inside the consumer's task.
---@param run dbdash.Run
function Panel:push_pipeline(run)
  local q = self.cfg.query
  local lua_result = require("dbdash.db.lua_result")
  local item = run.item
  local o = self:template_opts(run)
  run.record.sql = self.stream and self.stream.sql
  run.record.query = item.value
  local code = q.transform and M.render_text(self.d, q.transform, q.transform_line, o) or nil
  local started = vim.uv.hrtime()
  local rs
  if code then
    rs = M.transform(code, lua_result.raw(item.value, item.vars), {
      source = vim.fn.fnamemodify(self.d.path, ":~:."),
      line = q.transform_line,
      args = run.args,
      meta = run.meta,
      lua = run.lua,
      timeout = q.timeout or require("dbdash.options").default_ms("timeout"),
      max_rows = q.max_rows or opts().defaults.max_rows,
      cancel = run.life.cancel,
    })
  else
    local value = item.value
    if type(value) == "string" then
      local ok = pcall(vim.json.decode, value)
      if not ok then
        require("dbdash.util.error").raise(
          "query",
          ("the item is not JSON rows (%s); add query.transform to read it (:help dbdash-push)"):format(
            vim.trim(value):sub(1, 60)
          )
        )
      end
      value = require("dbdash.util.json").decode(value)
    end
    if require("dbdash.util.map").is_map(value) and value.rows == nil then
      value = { value } -- one record (a form, the parameters of a request)
    end
    rs = lua_result.normalize(
      value,
      { max_rows = q.max_rows or opts().defaults.max_rows, phase = "query", hint = true }
    )
  end
  rs.elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  run.record.result = lua_result.to_lua(rs)
  return rs
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
