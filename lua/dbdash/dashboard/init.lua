-- The running dashboards (ARCHITECTURE.md#startup-and-configuration): a config loaded,
-- checked and trusted (prepare), its dashboard created and started (create), stopped
-- (stop). The views (view/dashboard.lua) ask for arguments and show it. Tells on its
-- events (dashboard/events.lua): dashboard:started, dashboard:stopped.
local args = require("dbdash.args")
local events = require("dbdash.dashboard.events")

local M = {}

---@type table<string, dbdash.Dashboard>
M.dashboards = {}

M.Dashboard = require("dbdash.dashboard.dashboard").Dashboard
M.Panel = require("dbdash.dashboard.panel").Panel

---Human-readable error with its phase.
M.format_error = require("dbdash.util.error").format

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

---True when the config may run: it has no Lua (lua:// or query.transform), or the user
---trusts it (dbdash.trust: asks once, and again after the file changes) unless setup turns
---the question off. Returns false and the reason otherwise.
---@param on_viewed fun(answer: string)? the decision made after viewing the files
function M.trusted(path, cfg, on_viewed)
  local trust = require("dbdash.trust")
  local files, has_lua = trust.collect(path, cfg)
  if not has_lua or not trust.required(path) then
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
    local err = require("dbdash.util.error").new({
      phase = "config",
      message = "config file not found: " .. path,
    })
    return nil, err
  end
  local cfg, err = require("dbdash.config").load(path)
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

---Create, register and start the dashboard of a prepared config (dashboard:started).
---@param restored table<string, string>? argument values (text) restored from a session
---@return dbdash.Dashboard
function M.create(path, cfg, state, restored)
  local d = require("dbdash.dashboard.dashboard").new(path, cfg, state)
  if restored then
    d:apply_args(restored, true)
  end
  M.dashboards[path] = d
  events:emit("dashboard:started", d)
  d:start()
  return d
end

---Stop a dashboard: its clock stops, queries are cancelled (dashboard:stopped).
---@param path string
---@param o { keep_buffer: boolean? }? (for its view)
function M.stop(path, o)
  local d = M.dashboards[path]
  if not d then
    return false
  end
  M.dashboards[path] = nil
  d:stop("dashboard stopped")
  events:emit("dashboard:stopped", d, o or {})
  return true
end

function M.stop_all()
  for path in pairs(M.dashboards) do
    M.stop(path, { keep_buffer = true })
  end
end

---On exit: stop the clocks and cancel running queries (waiting up to a second for the
---cancels to reach the servers), but keep the dashboards and their arguments so session
---hooks that run later (VimLeave) can still save them.
function M.freeze_all()
  for _, d in pairs(M.dashboards) do
    d:pause()
    d:stop("Neovim exits")
  end
  local db = require("dbdash.db")
  vim.wait(1000, function()
    return db.pending_cancels() == 0
  end, 10)
end

return M
