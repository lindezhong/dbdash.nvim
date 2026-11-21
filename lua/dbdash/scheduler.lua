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
---@field gtimer uv.uv_timer_t? global refresh timer (multi-panel with top-level interval)
---@field ctimer uv.uv_timer_t? countdown display timer
---@field regions table[]? buffer regions of the panels (multi-panel)
---@field last_size integer[]?
---@field generation integer incremented on stop, to drop late query results
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
        or (self.d.cfg.multi and self:title() or vim.fn.fnamemodify(self.d.path, ":t"))
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

---Render the query template for the current arguments.
---@return string? sql, table? err
function Panel:render_sql()
  local q, d = self.cfg.query, self.d
  local ok, driver = pcall(db.driver, self.cfg.database.type)
  if not ok then
    return nil, db.Error.wrap(driver)
  end
  local vars = args.resolve(d.cfg.args, d.state)
  return template.render(q.sql, vars, {
    env = template.env(driver.dialect, q.autoescape, d.cfg.dir),
    source = vim.fn.fnamemodify(d.path, ":~:."),
    line_offset = q.sql_line - 1,
  })
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
  if delay > interval and not self.d.paused then
    self.retry_at = now() + delay
    self.backoff_mult = math.floor(delay / interval + 0.5)
    local follows_global = self.d.gtimer and not self.cfg.show.own_interval
    if follows_global then
      self.next_at = self.retry_at
    else
      self:start_timer(delay)
    end
  end
  if self.d.cfg.multi then
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
  local sql, err = self:render_sql()
  if not sql then
    self:push_history({ error = M.format_error(err) })
    self:fail(err)
    return
  end
  self.sql = sql
  self.running = true
  self.d:update_status()
  local gen = self.d.generation
  local q = self.cfg.query
  db.query(self.cfg.database.url, sql, {
    max_rows = q.max_rows,
    timeout = q.timeout,
    options = self.cfg.database.options,
    base_dir = self.d.cfg.dir,
    password_cmd = self.cfg.database.password_cmd,
  }, function(qerr, rs)
    if gen ~= self.d.generation then
      return -- stopped meanwhile
    end
    self.running = false
    if self.rerun then
      self.rerun = false
      vim.schedule(function()
        if gen == self.d.generation then
          self:refresh({ queue = true })
        end
      end)
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
      if was_backing_off and not self.d.paused and not (self.d.gtimer and not self.cfg.show.own_interval) then
        self:start_timer() -- back to the normal interval
      end
    end
    self:track(rs)
    self:check_thresholds(rs)
    self.error = nil
    self.d:redraw()
  end)
end

---(Re)start the panel's own timer. Panels that just follow the top-level interval of a
---multi-panel dashboard have no timer of their own: the global timer drives them.
---@param first integer? ms until the first tick (default: the interval), used on resume
function Panel:start_timer(first)
  local interval = self.cfg.show.interval
  first = first or interval
  self.next_at = now() + first
  local d = self.d
  if d.cfg.multi and d.gtimer and not self.cfg.show.own_interval then
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

function Panel:stop_timer()
  close_timer(self.timer)
  self.timer = nil
end

-- Dashboards -------------------------------------------------------------------------------

---Lines shown above the panels: argument values when args_show is on.
function Dashboard:header()
  local lines, hl = {}, {}
  if not self.cfg.args_show then
    return lines, hl
  end
  local parts, spans, pos = {}, {}, 0
  local function put(s, group)
    if group then
      spans[#spans + 1] = { pos, pos + #s, group }
    end
    parts[#parts + 1] = s
    pos = pos + #s
  end
  for _, spec in ipairs(self.cfg.args) do
    if spec.show then
      if #parts > 0 then
        put("  ")
      end
      put(spec.name, "DbDashArgName")
      put("=")
      put(args.format_value(args.value(spec, self.state)), "DbDashArgValue")
    end
  end
  if #parts == 0 then
    return lines, hl
  end
  lines[1] = table.concat(parts)
  for _, s in ipairs(spans) do
    hl[#hl + 1] = { row = 0, col_s = s[1], col_e = s[2], group = s[3] }
  end
  lines[2] = ""
  return lines, hl
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
  local title = W.truncate(p:title(), width)
  local head, spans = title, { { 0, #title, "DbDashTitle" } }
  if p.error then
    local room = width - W.width(head) - 3
    if room > 5 then
      local e = W.truncate(M.format_error(p.error):gsub("\n", " "), room)
      spans[#spans + 1] = { #head + 2, #head + 2 + #("✗ " .. e), "DbDashError" }
      head = head .. "  ✗ " .. e
    end
  end
  local body = render_panel(p, show, width, height)
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
  if not self.cfg.multi then
    local p = self.panels[1]
    body = render_panel(p, p:show_config(), width, height - offset)
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
  buffer.draw(self.buf, lines, hl)
  vim.b[self.buf].dbdash_regions = self.regions
  self:update_status()
end

---Countdown and error extmarks.
function Dashboard:update_status()
  if not self.cfg.multi then
    local p = self.panels[1]
    local show = p.cfg.show
    local countdown
    if show.show_countdown then
      countdown = p.running and "…" or show.countdown_format:gsub("{time}", tostring(p:remaining()))
    end
    buffer.set_status(self.buf, {
      countdown = countdown,
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
      local text = p.running and "…" or show.countdown_format:gsub("{time}", tostring(p:remaining()))
      marks[#marks + 1] = { row = r.row_s, col = r.x + r.width - vim.fn.strdisplaywidth(text), text = text }
    end
  end
  buffer.set_status(self.buf, { panels = marks })
end

---Panel whose region contains buffer line `lnum` (1-based) and display column `dcol`
---(0-based); the only panel when single. Panels side by side share lines, so the column
---decides between them.
function Dashboard:panel_at(lnum, dcol)
  if not self.cfg.multi then
    return self.panels[1]
  end
  for i, r in ipairs(self.regions or {}) do
    if lnum - 1 >= r.row_s and lnum - 1 <= r.row_e and (dcol or 0) >= r.x and (dcol or 0) < r.x + r.width then
      return self.panels[i]
    end
  end
end

---Refresh every panel now and restart all timers.
---Start (or restart) the global timer of a multi-panel dashboard.
---@param first integer? ms until the first tick (default: the interval)
function Dashboard:start_global_timer(first)
  local interval = self.cfg.interval
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
  local ro = { queue = not (o and o.timer) }
  if self.paused then
    -- Not visible (setup({ dashboard = { pause_hidden = true } })): refresh once, no timers.
    for _, p in ipairs(self.panels) do
      p:refresh(ro)
    end
    return
  end
  if self.gtimer then
    self:start_global_timer()
  end
  local t = now()
  for _, p in ipairs(self.panels) do
    -- A timer tick leaves panels that are backing off after failures alone.
    local backing_off = o and o.timer and p.retry_at and t < p.retry_at
    if backing_off then
      p.skip_tick = true
    else
      p:start_timer()
    end
  end
  for _, p in ipairs(self.panels) do
    if p.skip_tick then
      p.skip_tick = nil
      p.next_at = p.retry_at
    else
      p:refresh(ro)
    end
  end
end

function Dashboard:start_timers()
  if self.cfg.multi and self.cfg.interval then
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
  self:stop_timers()
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
  if self.cfg.multi and self.cfg.interval then
    self.gtimer = vim.uv.new_timer()
    local left = (self.gnext_at or t) - t
    if left <= 0 then
      self:restart({ timer = true }) -- the global interval elapsed: refresh every panel
      require("dbdash.view.sidebar").refresh()
      return
    end
    self:start_global_timer(left)
  end
  for _, p in ipairs(self.panels) do
    local follows_global = self.gtimer and not p.cfg.show.own_interval
    if not follows_global then
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
      }, Panel)
    end
    local restored = require("dbdash")._take_pending(path)
    if restored then
      require("dbdash")._apply_args(d, restored)
    end
    d.buf = buffer.create(path, o.buf)
    M.dashboards[path] = d
    vim.api.nvim_create_autocmd("BufWipeout", {
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
      return notify({ phase = "args", message = "missing required argument '" .. missing[1].name .. "'" })
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
