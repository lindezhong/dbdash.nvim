-- Sessions: the argument values of dashboards, saved and loaded like :mksession / :source
-- (:help dbdash-session-state). When to save and load is the user's session setup.
local M = {}

---Argument values that differ from the config (set on the command line, edited, or
---entered at start) for each running dashboard, as text.
---@return table<string, table<string, string>> { [config path] = { [argument] = "value" } }
function M.state()
  local args = require("dbdash.args")
  local out = {}
  for _, d in ipairs(require("dbdash.dashboard").list()) do
    local values = {}
    for _, spec in ipairs(d.cfg.args) do
      local v = args.value(spec, d.state)
      if v ~= nil and not vim.deep_equal(v, spec.default) then
        values[spec.key or spec.name] = args.format_value(v)
      end
    end
    if next(values) then
      out[d.path] = values
    end
  end
  return out
end

-- Values for dashboards that are not running yet, applied when they start.
local pending = {}

---Apply values from state(): running dashboards refresh with them, the others
---get them when they start. Unknown arguments and values that no longer parse are skipped.
function M.restore(state)
  local sched = require("dbdash.dashboard")
  for path, values in pairs(state or {}) do
    if type(path) == "string" and type(values) == "table" then
      path = sched.normalize(path)
      local d = sched.get(path)
      if d then
        if M.apply_args(d, values) then
          d:restart()
        end
      else
        pending[path] = values
      end
    end
  end
end

---Write the changed argument values of running dashboards to `file` (JSON), like
---:mksession writes the windows. Dashboards themselves are restored by the session.
---@param file string
---@return boolean ok, string? err
function M.mksession(file)
  local data = vim.json.encode({ version = 1, dashboards = M.state() })
  local f, err = io.open(vim.fs.normalize(file), "w")
  if not f then
    return false, err
  end
  f:write(data, "\n")
  f:close()
  return true
end

---Load argument values written by mksession() from `file`, like :source of a session.
---A missing file is not an error.
---@param file string
---@return boolean ok, string? err
function M.load_session(file)
  local f = io.open(vim.fs.normalize(file), "r")
  if not f then
    return true
  end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" or type(data.dashboards) ~= "table" then
    return false, "dbdash: invalid session file " .. file
  end
  M.restore(data.dashboards)
  return true
end

---Set argument values (text) as edited values; returns true if any was applied.
function M.apply_args(d, values)
  local args = require("dbdash.args")
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

---Values restored for `path` before it was running (consumed).
function M.take_pending(path)
  local v = pending[path]
  pending[path] = nil
  return v
end

return M
