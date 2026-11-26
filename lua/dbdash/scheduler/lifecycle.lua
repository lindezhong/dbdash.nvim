-- Starting and stopping dashboards: trust, buffers, windows, visibility and sessions.
local M = require("dbdash.scheduler")
local S = require("dbdash.scheduler.shared")
local Panel, Dashboard = S.Panel, S.Dashboard
local opts, notify, now = S.opts, S.notify, S.now
local args = require("dbdash.args")
local buffer = require("dbdash.view.buffer")
local config = require("dbdash.config")

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
