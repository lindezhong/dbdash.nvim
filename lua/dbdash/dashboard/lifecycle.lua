-- Starting and stopping dashboards (the model's side): a config loaded, checked and
-- trusted, its dashboard created and registered, its sources started; stopped, cancelled
-- and unregistered. The views (view/dashboard.lua) ask for arguments and show it.
local M = {}
local S = require("dbdash.dashboard.shared")
local Panel, Dashboard = S.Panel, S.Dashboard
local opts, now = S.opts, S.now
local args = require("dbdash.args")
local config = require("dbdash.config")
local events = require("dbdash.dashboard.events")
local registry = require("dbdash.dashboard.registry")

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

---True when the config may run: it has no Lua (lua:// or query.transform), or the user
---trusts it (dbdash.trust: asks once, and again after the file changes) unless setup turns
---the question off. Returns false and the reason otherwise.
---@param on_viewed fun(answer: string)? the decision made after viewing the files
function M.trusted(path, cfg, on_viewed)
  local trust = require("dbdash.trust")
  local files, has_lua = trust.collect(path, cfg)
  if not has_lua or not M.trust_required(path) then
    return true
  end
  return trust.check(path, files, on_viewed)
end

---Load a config to start: its config and its argument state from the command line.
---Returns nil and an error (or a message and its level) when it cannot start.
---@param path string normalized config path
---@param tokens string[]? command-line name=value arguments
---@param on_viewed fun(answer: string)? the decision made in the trust prompt's View float
---@return dbdash.Config? cfg, dbdash.ArgState|table|string|nil state_or_err, integer? level
function M.prepare(path, tokens, on_viewed)
  if vim.fn.filereadable(path) == 0 then
    return nil, { phase = "config", message = "config file not found: " .. path }
  end
  local cfg, err = config.load(path)
  if not cfg then
    return nil, err
  end
  local trusted, why, level = M.trusted(path, cfg, on_viewed)
  if not trusted then
    return nil, why, level or vim.log.levels.WARN
  end
  local ok, cli = pcall(args.parse_cli, cfg.args, tokens or {})
  if not ok then
    return nil, cli
  end
  return cfg, args.new_state(cli)
end

---Set argument values (text) as edited values; returns true if any was applied.
function M.apply_args(d, values)
  local applied = false
  for key, text in pairs(values) do
    -- By key ("name" shared, "<panel>.name" local); a key of no argument (sessions from
    -- before local arguments) sets every argument of that name.
    local specs = {}
    if type(text) == "string" and type(key) == "string" then
      local spec = args.find(d.cfg.args, key)
      specs = spec and { spec } or args.match(d.cfg.args, key)
    end
    for _, spec in ipairs(specs) do
      local ok, v = pcall(args.parse_value, spec, text)
      if ok then
        args.set_modified(d.state, spec.key or spec.name, v)
        applied = true
      end
    end
  end
  return applied
end

---Create, register and start the dashboard of a prepared config.
---@param restored table<string, string>? argument values (text) restored from a session
---@return dbdash.Dashboard
function M.create(path, cfg, state, restored)
  local d = setmetatable({
    path = path,
    cfg = cfg,
    state = state,
    panels = {},
    -- curl -c in its queries: trusted above (or trust is not required here)
    writes_trusted = require("dbdash.trust").writes(cfg),
  }, Dashboard)
  for i, pc in ipairs(cfg.panels) do
    d.panels[i] = setmetatable({
      d = d,
      index = i,
      cfg = pc,
      running = false,
      push = config.PUSH_TYPES[pc.database.type] or nil, -- shown as a push source
      next_at = now(),
      history = {},
      style = {},
      store = {}, -- `store` of the panel's Lua code, for as long as the dashboard runs
    }, Panel)
  end
  local document = require("dbdash.dashboard.document")
  document.dashboard(d) -- d.doc: the dashboard's document
  if restored then
    M.apply_args(d, restored)
  end
  registry.dashboards[path] = d
  document.sync(d)
  d:start_timers()
  events:emit("started", d)
  return d
end

---Stop a dashboard: its sources and clock stop, queries are cancelled.
---@param path string
---@param o { keep_buffer: boolean? }? (for its view)
function M.stop(path, o)
  local d = registry.dashboards[path]
  if not d then
    return false
  end
  registry.dashboards[path] = nil
  d:stop_timers()
  d:cancel("dashboard stopped")
  events:emit("stopped", d, o or {})
  return true
end

function M.stop_all()
  for path in pairs(registry.dashboards) do
    M.stop(path, { keep_buffer = true })
  end
end

---On exit: stop timers and cancel running queries (waiting up to a second for the cancels
---to reach the servers), but keep the dashboards and their arguments so session hooks
---that run later (VimLeave) can still save them.
function M.freeze_all()
  for _, d in pairs(registry.dashboards) do
    d:pause() -- (its views stop their countdowns)
    d:stop_timers()
    d:cancel("Neovim exits")
  end
  local db = require("dbdash.db")
  vim.wait(1000, function()
    return db.pending_cancels() == 0
  end, 10)
end

return M
