-- Metadata: read-only values dbdash provides to every template and every piece of Lua code
-- as `meta` (meta.config_dir, meta.os, ...), next to the dashboard arguments in `args`.
-- They are computed for each render, so meta.now and meta.refresh_count are current.
local map = require("dbdash.util.map")

local M = {}

-- Every name, in documentation order.
M.NAMES = {
  "cwd",
  "config_file",
  "config_dir",
  "config_name",
  "dashboard_title",
  "db_type",
  "db_host",
  "db_port",
  "db_name",
  "db_user",
  "db_url",
  "panel_index",
  "panel_title",
  "chart_type",
  "interval",
  "max_rows",
  "timeout",
  "refresh_count",
  "prev_query",
  "prev_result",
  "prev_error",
  "now",
  "today",
  "hostname",
  "user",
  "nvim_version",
  "os",
  "arch",
}

---"linux" | "windows" | "macos" | "bsd" | the lower-case system name.
function M.os_name()
  local sys = vim.uv.os_uname().sysname
  if sys == "Windows_NT" then
    return "windows"
  elseif sys == "Darwin" then
    return "macos"
  elseif sys:find("BSD$") then
    return "bsd"
  end
  return sys:lower()
end

---Local time as ISO 8601 with the UTC offset, e.g. 2026-11-24T10:00:00+08:00 (os.date's
---%z is not portable: Windows prints the zone name).
function M.iso_now(t)
  t = t or os.time()
  local offset = os.difftime(t, os.time(os.date("!*t", t)))
  if os.date("*t", t).isdst then
    offset = offset + 3600
  end
  local sign = offset < 0 and "-" or "+"
  offset = math.abs(offset)
  return os.date("%Y-%m-%dT%H:%M:%S", t) .. ("%s%02d:%02d"):format(sign, math.floor(offset / 3600), math.floor(offset % 3600 / 60))
end

local function user_name()
  local ok, pw = pcall(vim.uv.os_get_passwd)
  if ok and pw and pw.username then
    return pw.username
  end
  return vim.env.USER or vim.env.USERNAME
end

---Host, port, database and user of a URL as written in the config (no password, ${NAME}
---not expanded); each nil when the URL does not say and the driver has no default.
local function url_parts(raw, typ)
  local ok, u = pcall(require("dbdash.db.url").parse, raw)
  if not ok then
    return {}
  end
  local okd, driver = pcall(require("dbdash.db").driver, typ)
  if okd and driver.parse_url then
    u.options = {}
    local okp, parsed = pcall(driver.parse_url, u)
    if okp and parsed then
      u = parsed
    end
  end
  return { host = u.host, port = u.port, name = u.database, user = u.user ~= "" and u.user or nil }
end

---The metadata of a panel for one render.
---@param panel table scheduler Panel (cfg, d, index, refresh_count)
---@param run table? the run (scheduler dbdash.Run) being rendered
---@return table values by name (nil where there is no value)
function M.values(panel, run)
  local cfg = panel.cfg
  local q, show = cfg.query, cfg.show
  local dbdash = require("dbdash")
  local out = M.dashboard_values(panel.d, cfg.database)
  out.panel_index = panel.index
  out.panel_title = show.title ~= "" and show.title or nil
  out.chart_type = show.type
  out.interval = show.interval
  out.max_rows = q.max_rows or dbdash.options.defaults.max_rows
  out.timeout = q.timeout or dbdash.default_ms("timeout")
  out.refresh_count = panel.refresh_count or 0
  -- The previous refresh: its query's own result and the final rows (the last success),
  -- and its error when it failed.
  out.prev_query = panel.prev_query
  out.prev_result = panel.prev_result
  out.prev_error = panel.prev_error
  return out
end

---The metadata outside any panel (the dashboard's description): no panel_*, chart_type,
---interval, ...; db_* of `dbcfg` (default: the top-level database, none without one).
---@param d table scheduler Dashboard (path, cfg)
---@param dbcfg table?
function M.dashboard_values(d, dbcfg)
  dbcfg = dbcfg or d.cfg.database
  local parts = dbcfg and url_parts(dbcfg.url, dbcfg.type) or {}
  local v = vim.version()
  return {
    cwd = vim.fs.normalize(vim.fn.getcwd()),
    config_file = d.path,
    config_dir = d.cfg.dir,
    config_name = vim.fn.fnamemodify(d.path, ":t:r"),
    dashboard_title = d.cfg.title,
    db_type = dbcfg and dbcfg.type,
    db_host = parts.host,
    db_port = parts.port,
    db_name = parts.name,
    db_user = parts.user,
    db_url = dbcfg and require("dbdash.db.url").redact(dbcfg.url),
    now = M.iso_now(),
    today = os.date("%Y-%m-%d"),
    hostname = vim.uv.os_gethostname(),
    user = user_name(),
    nvim_version = ("%d.%d.%d"):format(v.major, v.minor, v.patch),
    os = M.os_name(),
    arch = jit and jit.arch or nil,
  }
end

---A metadata value for templates: result tables keep NULL cells as none (their rows may
---have holes), other tables are converted as Lua data.
local function template_value(x)
  if type(x) ~= "table" then
    return x
  end
  local R = require("dbdash.template.runtime")
  if type(x.columns) == "table" and type(x.rows) == "table" then
    local rows = {}
    for r, row in ipairs(x.rows) do
      local out = {}
      for i = 1, #x.columns do
        out[i] = R.from_lua(row[i])
      end
      rows[r] = out
    end
    local m = map.new()
    map.set(m, "columns", R.from_lua(x.columns))
    if x.types then
      map.set(m, "types", R.from_lua(x.types))
    end
    map.set(m, "rows", rows)
    return m
  end
  return R.from_lua(x)
end

---The values as a template mapping (missing values are none).
function M.for_template(values)
  local m = map.new()
  for _, name in ipairs(M.NAMES) do
    local x = values[name]
    map.set(m, name, x == nil and vim.NIL or template_value(x))
  end
  return m
end

---The values as a read-only table for Lua code (missing values are nil).
function M.for_lua(values)
  return setmetatable({}, {
    __index = values,
    __newindex = function(_, k)
      error(("meta is read-only (meta.%s)"):format(tostring(k)), 2)
    end,
    __pairs = function()
      return next, values, nil
    end,
  })
end

return M
