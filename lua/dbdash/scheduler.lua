-- Running dashboards and their refresh cycle (design §12).
--
-- A dashboard has one or more panels. Each panel refreshes on its own interval: render
-- template -> db.query -> render chart -> redraw. A refresh that comes due while the
-- panel's query is still running is skipped (and recorded). On error the panel keeps its
-- last good content and shows the error.
--
-- Multi-panel configs with a top-level `interval` also have a global timer that refreshes
-- every panel and restarts the panels' own timers.
local args = require("dbdash.args")
local buffer = require("dbdash.view.buffer")
local config = require("dbdash.config")
local db = require("dbdash.db")
local template = require("dbdash.template")
local W = require("dbdash.util.width")

local M = {}

---@class dbdash.HistoryEntry
---@field at integer os.time()
---@field elapsed_ms number?
---@field rows integer?
---@field error string?
---@field skipped boolean?

---@class dbdash.Panel
---@field d dbdash.Dashboard
---@field index integer
---@field cfg dbdash.PanelConfig
---@field timer uv.uv_timer_t?
---@field running boolean
---@field next_at integer loop time (ms) of the next refresh
---@field rs dbdash.db.ResultSet? last successful result
---@field sql string? last rendered query
---@field error table? last error (cleared on success)
---@field history dbdash.HistoryEntry[]
---@field style table overrides from :DbDashStyle
local Panel = {}
Panel.__index = Panel

---@class dbdash.Dashboard
---@field path string
---@field cfg dbdash.Config
---@field state dbdash.ArgState
---@field buf integer
---@field panels dbdash.Panel[]
---@field gtimer uv.uv_timer_t? global refresh timer (top-level interval: cfg.refresh_all)
---@field ctimer uv.uv_timer_t? countdown display timer
---@field regions table[]? buffer regions of the panels (multi-panel)
---@field last_size integer[]?
---@field generation integer incremented on stop, to drop late query results
---@field cookie_jar dbdash.http.Jar cookies servers set for http(s):// panels (in memory)
local Dashboard = {}
Dashboard.__index = Dashboard

---@type table<string, dbdash.Dashboard>
M.dashboards = {}


local function opts()
  return require("dbdash").options
end

---Report an error (§3.8: only errors produce messages).
local function notify(err)
  vim.notify("dbdash: " .. M.format_error(err), vim.log.levels.ERROR)
end

---Human-readable error with its phase.
function M.format_error(err)
  if type(err) ~= "table" then
    return tostring(err)
  end
  local phase = err.phase or "error"
  local msg = getmetatable(err) and getmetatable(err).__tostring and tostring(err) or err.message
  if err.phase == "template" and err.message then
    msg = (err.source and (err.source .. ":") or "") .. (err.line and (err.line .. ": ") or "") .. err.message
  end
  if msg:find("^" .. vim.pesc(phase)) or msg:find("^%w+ " .. vim.pesc(phase)) then
    return msg
  end
  return ("[%s] %s"):format(phase, msg)
end

function M.get(path)
  return M.dashboards[path]
end

---Dashboard shown in `buf`, if any.
function M.for_buf(buf)
  local path = vim.b[buf].dbdash_path
  if path then
    return M.dashboards[path]
  end
end

---Dashboards sorted by path.
function M.list()
  local out = vim.tbl_values(M.dashboards)
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

---Normalize a config path argument to an absolute path.
function M.normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
end

local function now()
  vim.uv.update_time()
  return vim.uv.now()
end

local function close_timer(t)
  if t then
    t:stop()
    if not t:is_closing() then
      t:close()
    end
  end
end

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

---Render query.sql and query.transform for the current arguments: one template path for
---both (same variables, imports and helpers); the transform is Lua, so never autoescaped.
---Runs inside a util.async task (template Lua may wait on dbdash.* helpers); raises a
---template or database error.
---@return string sql, string? transform_code
---@param run dbdash.Run
function Panel:render_templates(run)
  local q = self.cfg.query
  run.meta = require("dbdash.metadata").values(self, run) -- `meta` of templates and Lua
  if run.depth == 0 then
    self.meta = run.meta
  end
  local o = {
    dialect = db.driver(self.cfg.database.type).dialect,
    specs = self.cfg.visible_args,
    values = run.args,
    meta = run.meta,
    lua = run.lua,
    run = run,
    set_arg = function(name, v)
      self:set_arg(run, name, v)
    end,
    timeout = q.timeout,
    on_allow = function()
      self:refresh({ queue = true })
    end,
  }
  local sql = M.render_text(self.d, q.sql, q.sql_line, vim.tbl_extend("force", o, { autoescape = q.autoescape }))
  local code = q.transform and M.render_text(self.d, q.transform, q.transform_line, o) or nil
  return sql, code
end

---@class dbdash.Run one run of a panel's pipeline: a refresh (depth 0) or a callback
---@field values table<string, any> the arguments by name
---@field args table what Lua code sees as `args`
---@field depth integer 0 for a refresh, n for a callback n levels deep (meta.callback)
---@field counter { n: integer } callbacks so far in this refresh (shared by its callbacks)
---@field lua { store: table, helpers: table } globals of all Lua code of the run
---@field meta table? the metadata of this run

---A run of the panel's pipeline with `values` (default: the current arguments).
---@param parent dbdash.Run? the run this one is a callback of
---@return dbdash.Run
function Panel:new_run(values, parent)
  local run = {
    values = values or args.resolve_panel(self.cfg, self.d.state),
    depth = parent and parent.depth + 1 or 0,
    counter = parent and parent.counter or { n = 0 },
  }
  run.maps = {} -- the template `args` mappings of this run (kept in step with assignments)
  run.args = run.values -- Lua code sees (and may assign) the values; see Panel:sync_args
  run.seen = vim.deepcopy(run.values)
  run.lua = {
    store = self.store,
    helpers = self:helpers(run),
    after = function()
      self:sync_args(run)
    end,
  }
  return run
end

---After Lua code ran (a {% lua %} block, a module, query.transform, lua://): apply the
---arguments it assigned (`args.x = v`) with Panel:set_arg. An invalid one is put back
---and raises.
---@param run dbdash.Run
function Panel:sync_args(run)
  local values, seen = run.values, run.seen
  local names = {}
  for k in pairs(values) do
    names[k] = true
  end
  for k in pairs(seen) do
    names[k] = true
  end
  for name in pairs(names) do
    local v = values[name]
    if not vim.deep_equal(v, seen[name]) then
      values[name] = seen[name] -- set_arg stores it once it is valid
      self:set_arg(run, name, v)
    end
  end
end

---Assign argument `name` in a run (Lua `args.x = v`, {% set args.x = v %}): checked, then
---seen by the rest of the run (its templates, transform, lua://) and kept like an edit in
---the dashboard (from the next refresh on; a local argument shadows a shared one). A
---callback's run keeps its own values: the caller's do not change. Raises a message.
---@param run dbdash.Run
function Panel:set_arg(run, name, v)
  if run.read_only then
    error("arguments cannot be assigned in a description", 0)
  end
  local spec = type(name) == "string" and self:arg_spec(name)
  if not spec then
    error(("'%s' is not an argument of this panel"):format(tostring(name)), 0)
  end
  if v == vim.NIL then
    v = nil
  end
  local bad = args.check_value(spec, v)
  if bad then
    error(bad, 0)
  end
  run.values[name] = v == nil and vim.NIL or v
  run.seen[name] = vim.deepcopy(run.values[name])
  local R = require("dbdash.template.runtime")
  for _, m in ipairs(run.maps) do
    require("dbdash.util.map").set(m, name, R.from_lua(v))
  end
  args.set_modified(self.d.state, spec.key, v == nil and vim.NIL or v)
end



---A visible argument of the panel by name (a local one shadows a shared one).
function Panel:arg_spec(name)
  for _, spec in ipairs(self.cfg.visible_args) do
    if spec.name == name then
      return spec
    end
  end
end

---The `dbdash` table of a run's Lua code: the shared helpers plus the run's own:
---dbdash.run(args) runs the panel's pipeline again with `args` merged over the run's
---arguments (a callback: meta.callback is its depth) and returns its rows as Lua data.
function Panel:helpers(run)
  local own = {
    run = function(over)
      if over ~= nil and type(over) ~= "table" then
        error(("dbdash.run: expected a table of arguments, got %s"):format(type(over)), 2)
      end
      local limits = opts().lua
      if run.counter.n + 1 > limits.max_callbacks then
        error(("dbdash.run: more than %d callbacks in one refresh (lua.max_callbacks)"):format(limits.max_callbacks), 2)
      end
      if run.depth + 1 > limits.max_callback_depth then
        error(("dbdash.run: callbacks nested deeper than %d (lua.max_callback_depth)"):format(limits.max_callback_depth), 2)
      end
      local values = {}
      for k, v in pairs(run.values) do
        values[k] = v
      end
      for name, v in pairs(over or {}) do
        local spec = type(name) == "string" and self:arg_spec(name)
        if not spec then
          error(("dbdash.run: '%s' is not an argument of this panel"):format(tostring(name)), 2)
        end
        local bad = args.check_value(spec, v)
        if bad then
          error("dbdash.run: " .. bad, 2)
        end
        values[name] = v
      end
      run.counter.n = run.counter.n + 1
      local rs = self:pipeline(self:new_run(values, run))
      return require("dbdash.db.lua_result").to_lua(rs)
    end,
  }
  return setmetatable(own, { __index = require("dbdash.db.lua_env").helpers })
end

---Render the templates, query, then query.transform and the rows check (every source goes
---query -> transform -> rows check). Inside a util.async task.
---@param run dbdash.Run
---@return dbdash.db.ResultSet
function Panel:pipeline(run)
  local q = self.cfg.query
  local source = vim.fn.fnamemodify(self.d.path, ":~:.")
  local sql, code = self:render_templates(run)
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
  })
  run.query_result = rs
  if code then
    local out = M.transform(code, rs, {
      source = source,
      line = q.transform_line,
      args = run.args,
      meta = run.meta,
      lua = run.lua,
      timeout = q.timeout or require("dbdash").default_ms("timeout"),
      max_rows = q.max_rows or require("dbdash").options.defaults.max_rows,
    })
    out.elapsed_ms = rs.elapsed_ms
    rs = out
  end
  return rs
end

---Render template `text` (at `line` of the config) of dashboard `d`. Templates see exactly
---two names: args.<name> (o.specs with o.values) and meta.<name> (o.meta); imported
---templates and Lua in templates too. Inside a util.async task; raises template errors.
---@param o { dialect: table?, autoescape: boolean?, specs: dbdash.ArgSpec[], values: table, meta: table, lua: table?, timeout: integer?, on_allow: fun()? }
---  lua: { store, helpers } globals of Lua in the template ({% lua %}, imported .lua);
---  run: the run whose `args` mapping this is; set_arg: {% set args.x = v %}
function M.render_text(d, text, line, o)
  local metadata = require("dbdash.metadata")
  local map = require("dbdash.util.map")
  local R = require("dbdash.template.runtime")
  local args_map = map.new()
  for _, spec in ipairs(o.specs) do
    local v = o.values[spec.name]
    map.set(args_map, spec.name, type(v) == "table" and R.from_lua(v) or v)
  end
  if o.run then
    table.insert(o.run.maps, args_map)
  end
  local vars = { args = args_map, meta = metadata.for_template(o.meta) }
  local env = template.env(o.dialect, o.autoescape == true, d.cfg.dir)
  env.context = vars
  -- Lua in templates ({% lua %}, imported .lua): args, meta and the query timeout.
  env.lua = {
    args = o.values,
    meta = metadata.for_lua(o.meta),
    store = o.lua and o.lua.store,
    helpers = o.lua and o.lua.helpers,
    after = o.lua and o.lua.after,
  }
  env.timeout = o.timeout or require("dbdash").default_ms("timeout")
  env.set_arg = o.set_arg
  env.check_file = function(path, t, kind)
    M.check_file(d, path, t, kind, o.on_allow)
  end
  local out, err = template.render(text, vars, {
    env = env,
    source = vim.fn.fnamemodify(d.path, ":~:."),
    line_offset = line - 1,
  })
  if not out then
    error(err, 0)
  end
  return out
end

---Render a description (a template) in a task; `cb(err, text)` on the main loop.
local function describe_async(fn, cb)
  require("dbdash.util.async").run(fn, function(err, text)
    vim.schedule(function()
      cb(err, text)
    end)
  end)
end

---The panel's show.description rendered with its arguments and metadata (Markdown).
function Panel:describe_async(cb)
  local show = self.cfg.show
  describe_async(function()
    local run = self:new_run()
    run.read_only = true -- showing a description does not change arguments
    return M.render_text(self.d, show.description, show.description_line, {
      dialect = db.driver(self.cfg.database.type).dialect,
      specs = self.cfg.visible_args,
      values = run.args,
      meta = require("dbdash.metadata").values(self, run),
      lua = run.lua,
      set_arg = function(name, v)
        self:set_arg(run, name, v)
      end,
      timeout = self.cfg.query.timeout,
    })
  end, cb)
end

---The dashboard's description rendered with the shared arguments and the metadata
---outside any panel (db_* of the top-level database).
function Dashboard:describe_async(cb)
  local cfg = self.cfg
  describe_async(function()
    local values = args.resolve(cfg.shared_args, self.state)
    local seen = vim.deepcopy(values)
    local function refuse()
      error("arguments cannot be assigned in a description", 0)
    end
    return M.render_text(self, cfg.description, cfg.description_line, {
      dialect = cfg.database and db.driver(cfg.database.type).dialect or nil,
      specs = cfg.shared_args,
      values = values,
      meta = require("dbdash.metadata").dashboard_values(self),
      lua = {
        -- showing a description does not change arguments
        after = function()
          if not vim.deep_equal(values, seen) then
            refuse()
          end
        end,
      },
      set_arg = refuse,
    })
  end, cb)
end

---A file with Lua loaded while rendering (an imported .lua module or template with a
---{% lua %} block) must be covered by the config's trust. One that is not (imported
---through a computed path, or changed since the dashboard started) asks again, with all
---the config's files; allowing it from the View float refreshes the panel.
function Panel:check_file(path, text, kind)
  M.check_file(self.d, path, text, kind, function()
    self:refresh({ queue = true })
  end)
end

---check_file for any template of dashboard `d`; `on_allow` runs when it is allowed then.
function M.check_file(d, path, text, kind, on_allow)
  local trust = require("dbdash.trust")
  if kind == "template" and not trust.has_lua_block(text) then
    return
  end
  if not M.trust_required(d.path) or trust.covers(d.path, path, text) then
    return
  end
  local files = trust.collect(d.path, d.cfg)
  local real = trust.real(path)
  local listed = false
  for _, f in ipairs(files) do
    listed = listed or f.path == real
  end
  if not listed then
    files[#files + 1] = { path = real, kind = kind, text = text }
  end
  local ok, why = trust.check(d.path, files, function(answer)
    if answer == "allow" and on_allow then
      on_allow()
    end
  end)
  if not ok then
    error(require("dbdash.template.errors").new(
      "trust",
      why or ("%s runs Lua that is not trusted yet: %s"):format(
        vim.fn.fnamemodify(d.path, ":~:."),
        vim.fn.fnamemodify(path, ":~:.")
      )
    ), 0)
  end
end

---Render the templates in a task; `cb(err, sql, transform_code)` on the main loop.
function Panel:render_async(cb)
  require("dbdash.util.async").run(function()
    return self:render_templates(self:new_run())
  end, function(err, sql, code)
    vim.schedule(function()
      if not err then
        self.sql, self.transform_code = sql, code
      end
      cb(err, sql, code)
    end)
  end)
end

---Template errors keep their own shape (file and line); others become database errors.
local function as_error(err)
  if type(err) == "table" and err.phase == "template" then
    return err
  end
  return require("dbdash.db.error").wrap(err)
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

---Run the panel's query now (unless one is in flight).
---Run the panel's query. While the previous query still runs, a timer refresh is
---skipped (and recorded); a requested one (`o.queue`: manual refresh, changed
---arguments) runs again as soon as the previous query finishes.
---@param o { queue: boolean? }?
function Panel:refresh(o)
  if self.running then
    if o and o.queue then
      self.rerun = true
    else
      self:push_history({ skipped = true })
    end
    return
  end
  self.running = true
  self.refresh_count = (self.refresh_count or 0) + 1 -- meta.refresh_count
  self.d:update_status()
  local gen = self.d.generation
  -- One task: the whole pipeline (callbacks of dbdash.run() run inside it too).
  require("dbdash.util.async").run(function()
    local run = self:new_run()
    return self:pipeline(run), run
  end, function(err, rs, run)
    vim.schedule(function()
      if gen == self.d.generation then
        self:finish_refresh(gen, err and as_error(err) or nil, rs, run)
      end
    end)
  end)
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
  })
  return lua_result.normalize(value, { max_rows = o.max_rows, phase = "transform" })
end

---The end of a refresh: the query (and transform) result or error.
function Panel:finish_refresh(gen, qerr, rs, run)
  self.running = false
  if self.rerun then
    self.rerun = false
    vim.schedule(function()
      if gen == self.d.generation then
        self:refresh({ queue = true })
      end
    end)
  end
  local lua_result = require("dbdash.db.lua_result")
  if qerr then
    -- meta.prev_error; meta.prev_query / prev_result keep the last success.
    self.prev_error = M.format_error(qerr)
    self:push_history({ error = M.format_error(qerr) })
    self:fail(qerr)
    return
  end
  -- meta.prev_query (the query's own result, before query.transform) and prev_result.
  local raw = run and run.query_result
  if raw ~= nil then
    self.prev_query = lua_result.is_raw(raw) and raw.value or lua_result.to_lua(raw)
  end
  self.prev_result = lua_result.to_lua(rs)
  self.prev_error = nil
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

-- Dashboards -------------------------------------------------------------------------------

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

---The header above the panels: the dashboard title (and the global countdown, an extmark
---on its line), then an empty line; none without a title or countdown.
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

---The header above the panels: the dashboard title and ⓘ (and the global countdown, an
---extmark on its line), then an empty line; none without any of them.
function Dashboard:header()
  local cfg = self.cfg
  local icon = self:header_icon()
  if not (cfg.title or cfg.show_countdown or icon) then
    return {}, {}
  end
  local title = cfg.title or ""
  local line, hl = title, { { row = 0, col_s = 0, col_e = #title, group = "DbDashTitle" } }
  if icon then
    line = title ~= "" and (title .. " ") or ""
    hl[#hl + 1] = { row = 0, col_s = #line, col_e = #line + #desc_icon(), group = "DbDashDescIcon" }
    line = line .. desc_icon()
  end
  return { line, "" }, hl
end

---The args_show line of a panel (its shown_args with their current values; local ones
---highlighted apart), cut to `width`; nil when it shows none.
---@return { lines: string[], hl: table[] }?
function M.args_line(p, width)
  local specs = p.cfg.shown_args
  if #specs == 0 then
    return nil
  end
  local parts, spans, pos = {}, {}, 0
  local function put(str, group)
    if group then
      spans[#spans + 1] = { pos, pos + #str, group }
    end
    parts[#parts + 1] = str
    pos = pos + #str
  end
  for _, spec in ipairs(specs) do
    if #parts > 0 then
      put("  ")
    end
    put(spec.name, spec.panel and "DbDashArgLocal" or "DbDashArgName")
    put("=")
    put(args.format_value(args.value(spec, p.d.state)), "DbDashArgValue")
  end
  local W = require("dbdash.util.width")
  local text = table.concat(parts)
  local line = W.truncate(text, width)
  local hl = {}
  for _, sp in ipairs(spans) do
    if sp[1] < #line then
      hl[#hl + 1] = { row = 0, col_s = sp[1], col_e = math.min(sp[2], #line), group = sp[3] }
    end
  end
  return { lines = { line }, hl = hl }
end

---`parts` (rendered blocks) above `body`, rows shifted.
local function prepend(body, parts)
  local out = { lines = {}, hl = {} }
  for _, part in ipairs(vim.list_extend(vim.list_extend({}, parts), { body })) do
    local off = #out.lines
    vim.list_extend(out.lines, part.lines)
    for _, h in ipairs(part.hl) do
      out.hl[#out.hl + 1] = { row = h.row + off, col_s = h.col_s, col_e = h.col_e, group = h.group }
    end
  end
  return out
end

local function message(text, group)
  return { lines = { text }, hl = { { row = 0, col_s = 0, col_e = #text, group = group } } }
end

---Render one panel's chart (or a placeholder) at the given size.
local function render_panel(p, show, width, height)
  if p.rs then
    local ok, out = pcall(require("dbdash.render").render, p.rs, show, { width = width, height = height, history = p.values })
    if ok then
      return out
    end
    return message("render error: " .. tostring(out), "DbDashError")
  elseif not p.error then
    return message("Loading…", "DbDashMuted")
  end
  return { lines = {}, hl = {} }
end

---Multi-panel cell: a header line (title, state, error) above the chart.
local function panel_cell(p, width, height)
  local show = vim.deepcopy(p:show_config())
  show.title = nil -- shown in the header line instead
  local name = p:title()
  if p.cfg.show.description then
    name = name .. " " .. desc_icon()
  end
  local title = W.truncate(name, width)
  local head, spans = title, { { 0, #title, "DbDashTitle" } }
  if p.cfg.show.description and title == name then
    local icon = desc_icon()
    spans = { { 0, #title - #icon - 1, "DbDashTitle" }, { #title - #icon, #title, "DbDashDescIcon" } }
  end
  if p.error then
    local room = width - W.width(head) - 3
    if room > 5 then
      local e = W.truncate(M.format_error(p.error):gsub("\n", " "), room)
      spans[#spans + 1] = { #head + 2, #head + 2 + #("✗ " .. e), "DbDashError" }
      head = head .. "  ✗ " .. e
    end
  end
  local args_line = M.args_line(p, width)
  local body = render_panel(p, show, width, args_line and height - 1 or height)
  if args_line then
    body = prepend(body, { args_line })
  end
  local out = { lines = { head }, hl = {} }
  for _, s in ipairs(spans) do
    out.hl[#out.hl + 1] = { row = 0, col_s = s[1], col_e = s[2], group = s[3] }
  end
  for i, l in ipairs(body.lines) do
    out.lines[i + 1] = l
  end
  for _, h in ipairs(body.hl) do
    out.hl[#out.hl + 1] = { row = h.row + 1, col_s = h.col_s, col_e = h.col_e, group = h.group }
  end
  return out
end

---Re-render cached results into the buffer (no query).
function Dashboard:redraw()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local width, height = buffer.size(self.buf)
  self.last_size = { width, height }
  local lines, hl = self:header()
  local offset = #lines
  local body
  if not self.cfg.grid then
    local p = self.panels[1]
    local args_line = M.args_line(p, width)
    local h = height - offset
    if args_line then
      h = h - 2
    end
    body = render_panel(p, p:show_config(), width, h)
    if args_line then
      body = prepend(body, { args_line, { lines = { "" }, hl = {} } })
    end
    self.regions = nil
  else
    local layout = require("dbdash.render.layout")
    local lay = self.cfg.layout
    local spans = {}
    for i, p in ipairs(self.panels) do
      spans[i] = p.cfg.show.span
    end
    local cells = layout.plan(spans, width, lay.columns, lay.gap)
    local grid_rows = 0
    for _, c in ipairs(cells) do
      grid_rows = math.max(grid_rows, c.row)
    end
    local cell_h = math.max(8, math.floor((height - offset) / grid_rows) - 2)
    local outs = {}
    for i, p in ipairs(self.panels) do
      outs[i] = panel_cell(p, cells[i].width, cell_h)
    end
    body = layout.compose(cells, outs)
    self.regions = {}
    for i, r in ipairs(body.regions) do
      self.regions[i] = { row_s = r.row_s + offset, row_e = r.row_e + offset, x = r.x, width = r.width }
    end
  end
  vim.list_extend(lines, body.lines)
  for _, h in ipairs(body.hl) do
    hl[#hl + 1] = { row = h.row + offset, col_s = h.col_s, col_e = h.col_e, group = h.group }
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
    buffer.set_status(self.buf, {
      header = header,
      countdown = countdown,
      row = self.header_rows or 0,
      error = p.error and M.format_error(p.error) or nil,
      position = opts().countdown_position,
    })
    return
  end
  local marks = {}
  for i, p in ipairs(self.panels) do
    local r = self.regions and self.regions[i]
    local show = p.cfg.show
    if r and (show.show_countdown or p.running) then
      local text = M.countdown_text(show.countdown_format, p:remaining(), p.running)
      marks[#marks + 1] = { row = r.row_s, col = r.x + r.width - vim.fn.strdisplaywidth(text), text = text }
    end
  end
  buffer.set_status(self.buf, { header = header, panels = marks })
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
---arguments) queue a refresh behind a running query; timer ticks (`o.timer`) skip it.
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

---@class dbdash.StartOpts
---@field tokens string[]? command-line name=value arguments
---@field ask_all boolean? prompt for every argument (:DbDashStart!)
---@field buf integer? buffer to adopt
---@field win integer? window to show the dashboard in (default: current, or `open`)
---@field open "current"|"vsplit"|"split"|"tab"|nil how to show it when no `win` is given
---@field no_show boolean? do not display the buffer
---@field on_started fun(d: dbdash.Dashboard)?

---Show `buf` in `win`; without a window, per `open` ("current" | "vsplit" | "split" |
---"tab", see setup({ dashboard = { open = ... } })). A dashboard already visible in a
---split (current tab) or a tab (any tab) is jumped to instead of opened again.
local function show_in(buf, win, open)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    open = open or "current"
    if open ~= "current" then
      local wins = open == "tab" and vim.fn.win_findbuf(buf) or vim.tbl_filter(function(w)
        return vim.api.nvim_win_get_buf(w) == buf
      end, vim.api.nvim_tabpage_list_wins(0))
      if wins[1] then
        vim.api.nvim_set_current_win(wins[1])
        return
      end
      vim.cmd(({ vsplit = "vsplit", split = "split", tab = "tabnew" })[open])
      if open == "tab" then
        local scratch = vim.api.nvim_get_current_buf()
        vim.api.nvim_win_set_buf(0, buf)
        if scratch ~= buf and vim.fn.bufname(scratch) == "" and not vim.bo[scratch].modified then
          pcall(vim.api.nvim_buf_delete, scratch, { force = true })
        end
      end
    end
    win = vim.api.nvim_get_current_win()
  end
  if vim.api.nvim_win_get_buf(win) ~= buf then
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.api.nvim_set_current_win(win)
end

---Start a dashboard, or switch to it when it is already running.
---@param path string
---@param o dbdash.StartOpts?
function M.start(path, o)
  o = o or {}
  path = M.normalize(path)
  local existing = M.dashboards[path]
  if existing then
    if o.tokens and #o.tokens > 0 then
      local ok, cli = pcall(args.parse_cli, existing.cfg.args, o.tokens)
      if not ok then
        return notify(cli)
      end
      for k, v in pairs(cli) do
        existing.state.cli[k] = v
      end
      existing:restart()
    end
    buffer.apply_keys(existing.buf)
    if not o.no_show then
      show_in(existing.buf, o.win, o.open)
    end
    if o.on_started then
      o.on_started(existing)
    end
    return existing
  end

  if vim.fn.filereadable(path) == 0 then
    return notify({ phase = "config", message = "config file not found: " .. path })
  end
  local cfg, err = config.load(path)
  if not cfg then
    return notify(err)
  end
  local trusted, why, level = M.trusted(path, cfg, function(answer)
    -- The decision made in the View float.
    local name = vim.fn.fnamemodify(path, ":~:.")
    if answer == "allow" then
      M.start(path, o)
    elseif answer == "deny" then
      vim.notify(
        ("dbdash: %s denied; it will not run (:DbDashTrust allow %s to allow it)"):format(name, name),
        vim.log.levels.WARN
      )
    else
      vim.notify(("dbdash: %s not started (not trusted yet)"):format(name), vim.log.levels.INFO)
    end
  end)
  if not trusted then
    if why then
      vim.notify("dbdash: " .. why, level or vim.log.levels.WARN)
    end
    return
  end
  local ok, cli = pcall(args.parse_cli, cfg.args, o.tokens or {})
  if not ok then
    return notify(cli)
  end
  local state = args.new_state(cli)

  local function launch()
    if M.dashboards[path] then -- started meanwhile (e.g. twice from the sidebar)
      return
    end
    local d = setmetatable({
      path = path,
      cfg = cfg,
      state = state,
      panels = {},
      generation = 0,
      cookie_jar = require("dbdash.net.http_cookie").new(),
    }, Dashboard)
    for i, pc in ipairs(cfg.panels) do
      d.panels[i] = setmetatable({
        d = d,
        index = i,
        cfg = pc,
        running = false,
        next_at = now(),
        history = {},
        style = {},
        store = {}, -- `store` of the panel's Lua code, for as long as the dashboard runs
      }, Panel)
    end
    local restored = require("dbdash")._take_pending(path)
    if restored then
      require("dbdash")._apply_args(d, restored)
    end
    d.buf = buffer.create(path, o.buf)
    M.dashboards[path] = d
    -- Deleting the buffer (:bdelete, :bwipeout) stops the dashboard.
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      buffer = d.buf,
      once = true,
      callback = function()
        M.stop(path, { keep_buffer = true })
      end,
    })
    if not o.no_show then
      show_in(d.buf, o.win, o.open)
    end
    d:redraw()
    d:start_timers()
    vim.schedule(M.update_visibility) -- e.g. restored by a session into another tab
    require("dbdash.view.sidebar").refresh()
    if o.on_started then
      o.on_started(d)
    end
  end

  local to_ask = o.ask_all and cfg.args or args.missing_required(cfg.args, state)
  if #to_ask == 0 then
    launch()
    return
  end
  require("dbdash.view.args_ui").ask_all(to_ask, state, function(done)
    if not done then
      if o.buf and vim.api.nvim_buf_is_valid(o.buf) then
        buffer.create(path, o.buf) -- keep the adopted buffer usable
      end
      return
    end
    local missing = args.missing_required(cfg.args, state)
    if #missing > 0 then
      return notify({ phase = "args", message = "missing required argument '" .. (missing[1].key or missing[1].name) .. "'" })
    end
    launch()
  end)
end

---Stop a dashboard and close its buffer.
---@param path string
---@param o { keep_buffer: boolean? }?
function M.stop(path, o)
  local d = M.dashboards[path]
  if not d then
    return false
  end
  M.dashboards[path] = nil
  d.generation = d.generation + 1
  d:stop_timers()
  if not (o and o.keep_buffer) and vim.api.nvim_buf_is_valid(d.buf) then
    -- Keep windows open: show the alternate buffer (or an empty one) first.
    for _, win in ipairs(vim.fn.win_findbuf(d.buf)) do
      vim.api.nvim_win_call(win, function()
        local alt = vim.fn.bufnr("#")
        if alt > 0 and alt ~= d.buf and vim.fn.buflisted(alt) == 1 then
          vim.cmd("buffer " .. alt)
        else
          vim.cmd("enew")
        end
      end)
    end
    pcall(vim.api.nvim_buf_delete, d.buf, { force = true })
  end
  require("dbdash.view.sidebar").refresh()
  return true
end

---True when the config may run: it has no Lua (lua:// or query.transform), or the user
---trusts it (dbdash.trust: asks once, and again after the file changes, recorded in Neovim's
---trust database) unless setup({ lua = { confirm = false } }) or the file is in
---lua.trusted_dirs. Returns false and the reason otherwise.
---@param path string normalized config path
---@param cfg dbdash.Config
---@param on_viewed fun(answer: string)? the decision made after viewing the file
---False when setup turns the trust question off for this config (lua.confirm = false, or
---the config is under one of lua.trusted_dirs).
function M.trust_required(path)
  local o = opts().lua
  if o.confirm == false then
    return false
  end
  for _, d in ipairs(o.trusted_dirs or {}) do
    local dir = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(d), ":p")):gsub("/$", "")
    if path:sub(1, #dir + 1) == dir .. "/" then
      return false
    end
  end
  return true
end

function M.trusted(path, cfg, on_viewed)
  local trust = require("dbdash.trust")
  local files, has_lua = trust.collect(path, cfg)
  if not has_lua or not M.trust_required(path) then
    return true
  end
  return trust.check(path, files, on_viewed)
end

---On exit: stop timers and ignore queries still running, but keep the dashboards and
---their arguments so session hooks that run later (VimLeave) can still save them.
---Pause dashboards that no window of the current tab page shows, resume the others
---(setup({ dashboard = { pause_hidden = true } }), the default).
function M.update_visibility()
  local pause_hidden = opts().dashboard.pause_hidden
  local shown = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    shown[vim.api.nvim_win_get_buf(w)] = true
  end
  for _, d in pairs(M.dashboards) do
    if not pause_hidden or shown[d.buf] then
      d:resume()
    else
      d:pause()
    end
  end
end

function M.freeze_all()
  for _, d in pairs(M.dashboards) do
    d.generation = d.generation + 1
    d:stop_timers()
  end
end

---A window closes (WinClosed: it still shows its buffer). Closing the last window of a
---dashboard (:q, :close, :only, :tabclose) stops it like :DbDashStop; a dashboard that is
---only hidden (another buffer in its window, another tab page) pauses instead. Not while
---Neovim exits or a session loads (they close and recreate windows).
---@param win integer
function M.on_win_closed(win)
  if vim.v.exiting ~= vim.NIL or vim.g.SessionLoad == 1 then
    return
  end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  local d = ok and M.for_buf(buf)
  if not d then
    return
  end
  vim.schedule(function()
    if M.dashboards[d.path] ~= d or vim.v.exiting ~= vim.NIL or vim.g.SessionLoad == 1 then
      return
    end
    if vim.api.nvim_buf_is_valid(d.buf) and #vim.fn.win_findbuf(d.buf) == 0 then
      M.stop(d.path)
    end
  end)
end

function M.stop_all()
  for path in pairs(M.dashboards) do
    M.stop(path, { keep_buffer = true })
  end
end

---Redraw dashboards whose window size changed (uses cached data).
function M.on_resize()
  for _, d in pairs(M.dashboards) do
    local w, h = buffer.size(d.buf)
    if not d.last_size or d.last_size[1] ~= w or d.last_size[2] ~= h then
      d:redraw()
    end
  end
end

---Start dashboards for restored session buffers named dbdash://<path>.
function M.adopt_session_buffers()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local path = buffer.path_of(vim.api.nvim_buf_get_name(b))
    if path and vim.api.nvim_buf_is_loaded(b) and not M.dashboards[path] then
      M.start(path, { buf = b, no_show = true })
    end
  end
end

M.Dashboard = Dashboard
M.Panel = Panel

return M
