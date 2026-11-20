-- Running dashboards and their refresh cycle (design §12).
--
-- Refresh: render template -> db.query -> render chart -> write buffer. A refresh that
-- comes due while a query is still running is skipped (and recorded). On error the last
-- good content stays and the error is shown above it.
local args = require("dbdash.args")
local buffer = require("dbdash.view.buffer")
local config = require("dbdash.config")
local db = require("dbdash.db")
local template = require("dbdash.template")

local M = {}

---@class dbdash.HistoryEntry
---@field at integer os.time()
---@field elapsed_ms number?
---@field rows integer?
---@field error string?
---@field skipped boolean?

---@class dbdash.Dashboard
---@field path string
---@field cfg dbdash.Config
---@field state dbdash.ArgState
---@field buf integer
---@field timer uv.uv_timer_t?
---@field ctimer uv.uv_timer_t?
---@field running boolean
---@field next_at integer loop time (ms) of the next refresh
---@field rs dbdash.db.ResultSet? last successful result
---@field sql string? last rendered query
---@field error table? last error (cleared on success)
---@field history dbdash.HistoryEntry[]
---@field style table per-dashboard overrides from :DbDashStyle
---@field last_size integer[]?
---@field generation integer incremented on stop, to drop late query results
local Dashboard = {}
Dashboard.__index = Dashboard

---@type table<string, dbdash.Dashboard>
M.dashboards = {}

M.HISTORY_MAX = 20

local function opts()
  return require("dbdash").options
end

---Report an error once per distinct message (§3.8: only errors produce messages).
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

function Dashboard:push_history(entry)
  entry.at = os.time()
  table.insert(self.history, 1, entry)
  while #self.history > M.HISTORY_MAX do
    table.remove(self.history)
  end
end

---Seconds until the next refresh.
function Dashboard:remaining()
  return math.max(0, math.ceil((self.next_at - now()) / 1000))
end

---The effective show config (config file + :DbDashStyle overrides).
function Dashboard:show_config()
  if next(self.style) == nil then
    return self.cfg.show
  end
  local show = vim.deepcopy(self.cfg.show)
  for k, v in pairs(self.style) do
    show[k] = v
  end
  return show
end

---Lines shown above the chart: argument values when query.args_show is on.
function Dashboard:header()
  local lines, hl = {}, {}
  if not self.cfg.query.args_show then
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
  for _, spec in ipairs(self.cfg.query.args) do
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

---Re-render the cached result into the buffer (no query).
function Dashboard:redraw()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local width, height = buffer.size(self.buf)
  self.last_size = { width, height }
  local lines, hl = self:header()
  if self.rs then
    local ok, out = pcall(require("dbdash.render").render, self.rs, self:show_config(), {
      width = width,
      height = height - #lines,
    })
    if not ok then
      out = { lines = { "render error: " .. tostring(out) }, hl = { { row = 0, col_s = 0, col_e = 12, group = "DbDashError" } } }
    end
    local offset = #lines
    vim.list_extend(lines, out.lines)
    for _, h in ipairs(out.hl) do
      hl[#hl + 1] = { row = h.row + offset, col_s = h.col_s, col_e = h.col_e, group = h.group }
    end
  elseif not self.error then
    lines[#lines + 1] = "Loading…"
    hl[#hl + 1] = { row = #lines - 1, col_s = 0, col_e = #lines[#lines], group = "DbDashMuted" }
  end
  if #lines == 0 then
    lines = { "" }
  end
  buffer.draw(self.buf, lines, hl)
  self:update_status()
end

---Countdown and error extmarks.
function Dashboard:update_status()
  local show = self.cfg.show
  local countdown
  if show.show_countdown then
    countdown = self.running and "…" or show.countdown_format:gsub("{time}", tostring(self:remaining()))
  end
  buffer.set_status(self.buf, {
    countdown = countdown,
    error = self.error and M.format_error(self.error) or nil,
    position = opts().countdown_position,
  })
end

---Render the query template for the current arguments.
---@return string? sql, table? err
function Dashboard:render_sql()
  local ok, driver = pcall(db.driver, self.cfg.database.type)
  if not ok then
    return nil, db.Error.wrap(driver)
  end
  local vars = args.resolve(self.cfg.query.args, self.state)
  local sql, err = template.render(self.cfg.query.sql, vars, {
    env = template.env(driver.dialect, self.cfg.query.autoescape),
    source = vim.fn.fnamemodify(self.path, ":~:."),
    line_offset = self.cfg.query.sql_line - 1,
  })
  return sql, err
end

function Dashboard:fail(err)
  local changed = not self.error or M.format_error(self.error) ~= M.format_error(err)
  self.error = err
  if changed then
    notify(err)
  end
  self:update_status()
end

---Run the query now (unless one is in flight).
function Dashboard:refresh()
  if self.running then
    self:push_history({ skipped = true })
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
  self:update_status()
  local gen = self.generation
  local q = self.cfg.query
  db.query(self.cfg.database.url, sql, {
    max_rows = q.max_rows,
    timeout = q.timeout,
    options = self.cfg.database.options,
    base_dir = self.cfg.dir,
  }, function(qerr, rs)
    if gen ~= self.generation then
      return -- stopped meanwhile
    end
    self.running = false
    if qerr then
      self:push_history({ error = M.format_error(qerr) })
      self:fail(qerr)
      return
    end
    self:push_history({ elapsed_ms = rs.elapsed_ms, rows = rs.row_count })
    self.rs = rs
    self.error = nil
    self:redraw()
  end)
end

---Restart the interval and refresh immediately.
function Dashboard:restart()
  local interval = self.cfg.show.interval
  self.next_at = now() + interval
  if self.timer then
    self.timer:stop()
    self.timer:start(interval, interval, function()
      self.next_at = now() + interval
      vim.schedule(function()
        if self.timer then
          self:refresh()
        end
      end)
    end)
  end
  self:refresh()
end

function Dashboard:start_timers()
  self.timer = vim.uv.new_timer()
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
  for _, key in ipairs({ "timer", "ctimer" }) do
    local t = self[key]
    if t then
      t:stop()
      if not t:is_closing() then
        t:close()
      end
      self[key] = nil
    end
  end
end

---@class dbdash.StartOpts
---@field tokens string[]? command-line name=value arguments
---@field ask_all boolean? prompt for every argument (:DbDashStart!)
---@field buf integer? buffer to adopt
---@field win integer? window to show the dashboard in (default: current)
---@field no_show boolean? do not display the buffer
---@field on_started fun(d: dbdash.Dashboard)?

local function show_in(buf, win)
  win = win and vim.api.nvim_win_is_valid(win) and win or vim.api.nvim_get_current_win()
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
      local ok, cli = pcall(args.parse_cli, existing.cfg.query.args, o.tokens)
      if not ok then
        return notify(cli)
      end
      for k, v in pairs(cli) do
        existing.state.cli[k] = v
      end
      existing:restart()
    end
    if not o.no_show then
      show_in(existing.buf, o.win)
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
  local ok, cli = pcall(args.parse_cli, cfg.query.args, o.tokens or {})
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
      running = false,
      next_at = now(),
      history = {},
      style = {},
      generation = 0,
    }, Dashboard)
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
      show_in(d.buf, o.win)
    end
    d:redraw()
    d:start_timers()
    require("dbdash.view.sidebar").refresh()
    if o.on_started then
      o.on_started(d)
    end
  end

  local to_ask = o.ask_all and cfg.query.args or args.missing_required(cfg.query.args, state)
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
    local missing = args.missing_required(cfg.query.args, state)
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

return M
