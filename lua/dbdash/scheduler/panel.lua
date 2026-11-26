-- Panels: the refresh pipeline (template -> query -> transform), its result or error,
local M = require("dbdash.scheduler")
local S = require("dbdash.scheduler.shared")
local Panel = S.Panel
local opts, notify, now, close_timer, as_error = S.opts, S.notify, S.now, S.close_timer, S.as_error
local args = require("dbdash.args")
local config = require("dbdash.config")
local db = require("dbdash.db")
local W = require("dbdash.util.width")

local W = require("dbdash.util.width")

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
    while #self.values > C.HISTORY do
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
          require("dbdash.template.runtime").numstr(cur.step.value)
        ),
        vim.log.levels.WARN
      )
    end
    self.levels[key] = cur.level
  end
end

---Seconds until the panel's next refresh.
function Panel:remaining()
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

---Render the templates, query, then query.transform and the rows check (every source goes
---query -> transform -> rows check). Inside a util.async task.
---@param run dbdash.Run
---@return dbdash.db.ResultSet
function Panel:pipeline(run)
  if run.item then
    return self:push_pipeline(run) -- a push source's item (and its callbacks)
  end
  local q = self.cfg.query
  local source = vim.fn.fnamemodify(self.d.path, ":~:.")
  local sql, code = self:render_templates(run)
  run.record.sql = sql
  if run.depth == 0 then
    self.sql, self.transform_code = sql, code
  end
  local rs = db.query_async(self.cfg.database.url, sql, {
    max_rows = q.max_rows,
    timeout = q.timeout,
    options = self.cfg.database.options,
    base_dir = self.d.cfg.dir,
    password_cmd = self.cfg.database.password_cmd,
    args = run.args,
    meta = run.meta,
    lua = run.lua,
    source = source,
    line = q.sql_line,
    raw = code ~= nil, -- the transform gets the raw result; checked after it
    cookie_jar = self.d.cookie_jar,
    cancel = run.life.cancel, -- cancelling the refresh stops the query
  })
  -- The query's own result (before query.transform): rows as Lua data, or the raw value.
  local lua_result = require("dbdash.db.lua_result")
  run.record.query = lua_result.is_raw(rs) and rs.value or lua_result.to_lua(rs)
  if code then
    local out = M.transform(code, rs, {
      source = source,
      line = q.transform_line,
      args = run.args,
      meta = run.meta,
      lua = run.lua,
      timeout = q.timeout or require("dbdash").default_ms("timeout"),
      max_rows = q.max_rows or require("dbdash").options.defaults.max_rows,
      cancel = run.life.cancel,
    })
    out.elapsed_ms = rs.elapsed_ms
    rs = out
  end
  run.record.result = lua_result.to_lua(rs)
  return rs
end

---Delay before the next try after `failures` consecutive failures: the interval doubled
---per failure after the first, at most interval x factor (errors.backoff).
---@return integer ms
function M.backoff_delay(interval, failures, factor)
  local mult = math.min(2 ^ math.max(failures - 1, 0), math.max(factor or 1, 1))
  return math.floor(interval * mult)
end

function Panel:fail(err)
  local changed = not self.error or M.format_error(self.error) ~= M.format_error(err)
  self.error = err
  local mode = opts().errors.notify
  if mode == "always" or (mode == "once" and changed) then
    notify(err)
  end
  -- Back off: wait longer after each consecutive failure (errors.backoff).
  self.failures = (self.failures or 0) + 1
  local interval = self.cfg.show.interval
  local delay = M.backoff_delay(interval, self.failures, opts().errors.backoff)
  if delay > interval and self:active() then
    self.retry_at = now() + delay
    self.backoff_mult = math.floor(delay / interval + 0.5)
    if self.d.gtimer and self.cfg.follows_global then
      self.next_at = self.retry_at
    else
      self:start_timer(delay)
    end
  end
  if self.d.cfg.grid then
    self.d:redraw() -- the error shows in the panel header
  else
    self.d:update_status()
  end
end

---Run the panel's query. While the previous refresh still runs, a timer refresh is
---skipped (and recorded); a requested one (`o.queue`: manual refresh, changed arguments)
---cancels it (its queries stop on the server too) and starts at once.
---@param o { queue: boolean? }?
function Panel:refresh(o)
  if self.push then
    -- A push source starts (again) when asked: start, r, changed arguments; timer ticks
    -- only redraw it.
    if o and o.queue then
      self:stream_start()
    end
    return
  end
  if self.running then
    if not (o and o.queue) then
      self:push_history({ skipped = true })
      return
    end
    self:cancel("replaced by a new refresh")
  end
  self.running = true
  self.refresh_count = (self.refresh_count or 0) + 1 -- meta.refresh_count
  self.d:update_status()
  -- One task: the whole pipeline (callbacks of dbdash.run() run inside it too).
  local run = self:new_run()
  self.current = run
  require("dbdash.util.async").run(function()
    return self:pipeline(run)
  end, function(err, rs)
    vim.schedule(function()
      -- Not when the refresh was cancelled (replaced, the dashboard stopped).
      if self.current == run then
        self:finish_refresh(err and as_error(err) or nil, rs, run)
      end
    end)
  end)
end

---Cancel the refresh that is running (if any): its queries and Lua code stop (on the
---server too, see db.query), its result is dropped. Its record is closed as failed with
---the reason and becomes meta.prev; the panel shows no error.
---@param reason string
function Panel:cancel(reason)
  if self.push then
    self:stream_stop(reason)
    return
  end
  local run = self.current
  if not run then
    return
  end
  self.current = nil
  self.running = false
  run.life.cancel:cancel(reason)
  self:finish_record(run, require("dbdash.db.error").new({ phase = "cancelled", message = "query cancelled: " .. reason }))
  self.prev, self.prev_runs = run.record, run.life.runs
  self:push_history({ cancelled = reason })
  run.life.cancel:release()
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

---The end of a refresh: the query (and transform) result or error.
---Close a run's record: finished_at, elapsed_ms, ok and error.
function Panel:finish_record(run, err)
  local r = run.record
  r.finished_at = require("dbdash.util.uuid").now_ms()
  r.elapsed_ms = r.finished_at - r.started_at
  r.ok = err == nil
  r.error = err ~= nil and M.format_error(as_error(err)) or nil
  run.life.version = run.life.version + 1
end

function Panel:finish_refresh(qerr, rs, run)
  self.running = false
  self.current = nil
  run.life.cancel:release()
  -- The refresh's record and life become meta.prev / prev_runs (prev_ok / prev_ok_runs
  -- when it succeeded).
  if run then
    self:finish_record(run, qerr)
    self.prev, self.prev_runs = run.record, run.life.runs
    if not qerr then
      self.prev_ok, self.prev_ok_runs = run.record, run.life.runs
    end
  end
  if qerr then
    self:push_history({ error = M.format_error(qerr) })
    self:fail(qerr)
    return
  end
  self:push_history({ elapsed_ms = rs.elapsed_ms, rows = rs.row_count })
  self.rs = rs
  if (self.failures or 0) > 0 then
    local was_backing_off = self.retry_at ~= nil
    self.failures, self.retry_at, self.backoff_mult = 0, nil, nil
    if was_backing_off and self:active() and not (self.d.gtimer and self.cfg.follows_global) then
      self:start_timer() -- back to the normal interval
    end
  end
  self:track(rs)
  self:check_thresholds(rs)
  self.error = nil
  self.d:redraw()
end

---(Re)start the panel's own timer. Panels the global refresh (cfg.refresh_all) comes for
---as often as their own interval have no timer of their own: the global timer drives them.
---@param first integer? ms until the first tick (default: the interval), used on resume
function Panel:start_timer(first)
  if self.push then
    return self:start_draw_timer(first)
  end
  local interval = self.cfg.show.interval
  first = first or interval
  self.next_at = now() + first
  local d = self.d
  if (d.gtimer and self.cfg.follows_global) or not self:active() then
    return
  end
  self.timer = self.timer or vim.uv.new_timer()
  self.timer:stop()
  self.timer:start(first, interval, function()
    self.next_at = now() + interval
    vim.schedule(function()
      if self.timer then
        self:refresh() -- a timer tick: skipped while the previous query runs
      end
    end)
  end)
end

---Refreshing on its timers: the dashboard is visible, or show.refresh_hidden.
function Panel:active()
  return not self.d.paused or self.cfg.show.refresh_hidden
end

function Panel:stop_timer()
  close_timer(self.timer)
  self.timer = nil
end
