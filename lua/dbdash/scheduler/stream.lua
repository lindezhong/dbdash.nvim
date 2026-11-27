-- Push sources in a dashboard (:help dbdash-push): a producer (db.stream) and a consumer.
-- Items go into the panel's queue as they arrive; one consumer task takes them in order,
-- one at a time, through the panel's pipeline (a run of kind "push": query.transform or
-- the JSON rows check, callbacks, store, meta.prev ...). The panel is drawn on its
-- interval when there is something new. When the producer ends (exec://, luastream://)
-- the queue is drained, the last result drawn and the panel stops; r or changed arguments
-- start it again.
local M = require("dbdash.scheduler")
local S = require("dbdash.scheduler.shared")
local Panel = S.Panel
local opts, notify, now, close_timer, as_error = S.opts, S.notify, S.now, S.close_timer, S.as_error
local db = require("dbdash.db")

---@class dbdash.PushStream
---@field queue table[] { value, vars } waiting
---@field token dbdash.db.CancelToken stops the producer
---@field handle table? db.stream's handle
---@field state string "starting" | "running" | "listening ..." | "ended" | "failed" | "stopped"
---@field received integer
---@field processed integer
---@field dropped integer
---@field busy boolean the consumer is working
---@field ended boolean the producer ended
---@field sql string? the rendered query.sql (script, document, code)

---(Re)start the push source: render query.sql, then run the producer.
function Panel:stream_start()
  self:stream_stop("restarted")
  local st = {
    queue = {},
    token = require("dbdash.db.cancel").new(),
    state = "starting",
    received = 0,
    processed = 0,
    dropped = 0,
  }
  self.stream = st
  self.error = nil
  self.ended = nil
  local q = self.cfg.query
  require("dbdash.util.async").run(function()
    -- Rendered once per start (arguments and meta of that moment).
    local run = self:new_run(nil, nil, "render")
    local o = self:template_opts(run)
    o.cancel = st.token
    local sql = M.render_text(
      self.d,
      q.sql,
      q.sql_line,
      vim.tbl_extend("force", o, { autoescape = q.autoescape })
    )
    return sql, run
  end, function(err, sql, run)
    vim.schedule(function()
      if self.stream ~= st then
        return
      end
      if err then
        self:stream_end(st, as_error(err))
        return
      end
      st.sql = sql
      st.state = "running"
      local source = vim.fn.fnamemodify(self.d.path, ":~:.")
      st.handle = db.stream(self.cfg.database.url, sql, {
        options = self.cfg.database.options,
        base_dir = self.d.cfg.dir,
        password_cmd = self.cfg.database.password_cmd,
        timeout = q.timeout,
        max_rows = q.max_rows,
        args = run.args,
        meta = run.meta,
        lua = run.lua,
        source = source,
        line = q.sql_line,
        cancel = st.token,
        on_status = function(text)
          if self.stream == st then
            st.state = text
            self.d:update_status()
          end
        end,
      }, function(value, vars)
        self:stream_item(st, value, vars)
      end, function(e)
        self:stream_end(st, e)
      end)
      self.d:request_render()
    end)
  end)
  self:start_draw_timer()
  self.d:request_render()
end

---Stop the push source (dashboard stopped, restarted): items still queued are dropped.
function Panel:stream_stop(reason)
  local st = self.stream
  if not st then
    return
  end
  st.stopped = true
  st.queue = {}
  st.token:cancel(reason or "stopped")
end

---An item from the producer: queue it (the oldest is dropped when the queue is full).
function Panel:stream_item(st, value, vars)
  if self.stream ~= st or st.stopped then
    return
  end
  st.received = st.received + 1
  if #st.queue >= opts().push.max_queue then
    table.remove(st.queue, 1)
    st.dropped = st.dropped + 1
  end
  st.queue[#st.queue + 1] = { value = value, vars = vars }
  self:stream_consume(st)
end

---The consumer: one task taking the queued items in order, one at a time.
function Panel:stream_consume(st)
  if st.busy then
    return
  end
  st.busy = true
  require("dbdash.util.async").run(function()
    while self.stream == st and not st.stopped and #st.queue > 0 do
      local item = table.remove(st.queue, 1)
      local run = self:new_run(nil, nil, "push")
      run.item = item
      self.refresh_count = (self.refresh_count or 0) + 1 -- meta.refresh_count
      local ok, rs = pcall(self.pipeline, self, run)
      self:stream_done(st, run, not ok and as_error(rs) or nil, ok and rs or nil)
    end
  end, function(err)
    st.busy = false
    if err then
      notify(as_error(err))
    end
    if self.stream == st and st.ended then
      self:stream_finish(st)
    end
  end)
end

---The end of one item: its record, the result or error (drawn on the next tick).
function Panel:stream_done(st, run, err, rs)
  st.processed = st.processed + 1
  self:finish_record(run, err)
  self.prev, self.prev_runs = run.record, run.life.runs
  run.life.cancel:release()
  if err then
    self:push_history({ error = M.format_error(err) })
    local changed = not self.error or M.format_error(self.error) ~= M.format_error(err)
    self.error = err
    local mode = opts().errors.notify
    if mode == "always" or (mode == "once" and changed) then
      notify(err)
    end
  else
    self.prev_ok, self.prev_ok_runs = run.record, run.life.runs
    self:push_history({ elapsed_ms = run.record.elapsed_ms, rows = rs.row_count })
    self.rs = rs
    self.error = nil
    self:track(rs)
    self:check_thresholds(rs)
  end
  self.dirty = true
end

---The producer ended (or failed): finish once the queue is drained.
function Panel:stream_end(st, err)
  if self.stream ~= st then
    return
  end
  if err and err.phase == "cancelled" and st.stopped then
    return -- stopped on purpose
  end
  st.ended = true
  st.end_error = err
  if not st.busy then
    self:stream_finish(st)
  end
end

---The panel stops: the last result drawn now, the state "ended" or "failed".
function Panel:stream_finish(st)
  if st.finished then
    return
  end
  st.finished = true
  st.state = st.end_error and "failed" or "ended"
  self.ended = true
  if st.end_error then
    self.error = st.end_error
    self:push_history({ error = M.format_error(st.end_error) })
    notify(st.end_error)
  end
  close_timer(self.timer)
  self.timer = nil
  self.dirty = false
  self.d:request_render()
end

---The redraw timer of a push panel: on its interval, draw when something is new.
function Panel:start_draw_timer(first)
  local interval = self.cfg.show.interval
  first = first or interval
  self.next_at = now() + first
  if self.ended or not self:active() then
    return
  end
  self.timer = self.timer or vim.uv.new_timer()
  self.timer:stop()
  self.timer:start(first, interval, function()
    self.next_at = now() + interval
    vim.schedule(function()
      if self.timer and self.dirty then
        self.dirty = false
        self.d:request_render()
      end
    end)
  end)
  if self.dirty then
    -- Shown again (resume): draw what came while hidden.
    vim.schedule(function()
      if self.dirty and self:active() then
        self.dirty = false
        self.d:request_render()
      end
    end)
  end
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
  local st = self.stream
  return st and st.state or "stopped"
end
