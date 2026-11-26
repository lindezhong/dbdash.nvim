-- dbdash.nvim: database dashboards in Neovim.
local M = {}

---@alias dbdash.Size integer|string columns/rows, or "N%" of the editor width/height

---@class dbdash.SidebarOptions
---@field width dbdash.Size (default 30)
---@field position "left"|"right" (default "left")
---@field dir string|fun(): string|nil directory to list (default: the current directory)
---@field pattern string[] file globs to list (default { "*.yaml", "*.yml" })
---@field exclude string[] file and directory name globs to skip (default { "*.schema.yaml", "*.schema.yml" })
---@field keys table<"select"|"stop"|"refresh"|"close", string|false>
---@field cursorline "line"|"name"|false cursor line: the global CursorLine over the whole line
---  (default), DbDashSidebarCursor on the name only (keeps the ●/◐/○ marker's color), or none

---@class dbdash.DashboardOptions
---@field open "current"|"vsplit"|"split"|"tab" where :DbDashStart shows a dashboard
---@field pause_hidden boolean stop refreshing while no window of the current tab shows it
---@field keys table<"modify"|"show_args"|"refresh"|"reset"|"show_sql"|"export"|"describe", string|false>
---@field icons { description: string } ⓘ after a title with a description to read (K)

---@class dbdash.PopupOptions
---@field border string|string[] floating window border (default "rounded")
---@field max_width dbdash.Size (default 120)
---@field max_height dbdash.Size (default "100%")

---@class dbdash.DefaultsOptions
---@field interval string|number refresh interval when a config sets none (default "30s")
---@field timeout string|number query timeout when the URL sets none (default "30s")
---@field connect_timeout string|number (default "10s")
---@field max_rows integer (default 10000)
---@field height integer? chart plot rows (default: each chart's own)
---@field min_height integer smallest plot rows in a grid before it scrolls (default 8)
---@field countdown_format string (default "Next update: {time}s")
---@field history integer queries kept for :DbDashStatus (default 20)

---@class dbdash.ErrorsOptions
---@field notify "once"|"always"|"never" vim.notify for a refresh error: when it first
---  appears or changes (default), every time, or never (only shown in the dashboard)
---@field backoff integer consecutive failures wait the interval x 2^(n-1), up to the
---  interval x backoff; 1 disables backing off (default 8)

---@class dbdash.LuaOptions
---@field confirm boolean ask (vim.secure, like exrc) before running a config with Lua
---  (lua:// or query.transform); false runs them without asking (default true)
---@field trusted_dirs string[] configs under these directories run without asking
---@field max_callbacks integer dbdash.run() calls in one refresh, all levels together (default 100)
---@field max_callback_depth integer dbdash.run() nesting (meta.run.depth), default 10

---@class dbdash.Options
---@field mappings boolean|table<"start"|"refresh"|"stop"|"list"|"sidebar", string|false>
---@field countdown_interval integer ms between countdown updates (default 10000)
---@field countdown_position "right_align"|"eol"|"overlay"
---@field styles table<string, { renderer: string?, canvas: string? }> per chart type defaults
---@field ticks string tick algorithm ("nice" | "linear")
---@field register table<string, any> custom render implementations ("chart/bar/mine", ...)
---@field sidebar dbdash.SidebarOptions
---@field dashboard dbdash.DashboardOptions
---@field popup dbdash.PopupOptions
---@field defaults dbdash.DefaultsOptions
---@field errors dbdash.ErrorsOptions
---@field lua dbdash.LuaOptions
---@field push { max_queue: integer, max_record: integer|string } push sources (:help dbdash-push)
local defaults = {
  mappings = true,
  countdown_interval = 10000,
  countdown_position = "right_align",
  styles = {},
  ticks = "nice",
  register = {},
  sidebar = {
    width = 30,
    position = "left",
    dir = nil,
    pattern = { "*.yaml", "*.yml" },
    exclude = { "*.schema.yaml", "*.schema.yml" },
    keys = { select = "<CR>", stop = "t", refresh = "r", close = "q" },
    cursorline = "line",
  },
  dashboard = {
    open = "current",
    pause_hidden = true,
    keys = {
      modify = "a",
      show_args = "A",
      refresh = "r",
      reset = "R",
      show_sql = "s",
      export = "e",
      describe = "K",
    },
    icons = { description = "ⓘ" },
  },
  popup = { border = "rounded", max_width = 120, max_height = "100%" },
  defaults = {
    interval = "30s",
    timeout = "30s",
    connect_timeout = "10s",
    max_rows = 10000,
    height = nil,
    min_height = 8,
    countdown_format = "Next update: {time}s",
    history = 20,
  },
  errors = {
    notify = "once",
    backoff = 8,
  },
  lua = {
    confirm = true,
    trusted_dirs = {},
    max_callbacks = 100,
    max_callback_depth = 10,
  },
  push = {
    max_queue = 1000,
    max_record = "1MB",
  },
}
M.DEFAULTS = defaults

---@type dbdash.Options
M.options = vim.deepcopy(defaults)

---Problems found by the last setup() call (empty when setup() was not called).
---@type string[]
M.setup_errors = {}

-- Validation -------------------------------------------------------------------------------

local size = require("dbdash.util.size")
local duration = require("dbdash.util.duration")

local function enum(...)
  local allowed = { ... }
  return function(v)
    if not vim.tbl_contains(allowed, v) then
      return "must be one of " .. table.concat(vim.tbl_map(vim.inspect, allowed), ", ")
    end
  end
end

local function int(min)
  return function(v)
    if type(v) ~= "number" or v ~= math.floor(v) or v < min then
      return ("must be an integer >= %d"):format(min)
    end
  end
end

local function of_type(...)
  local types = { ... }
  return function(v)
    if not vim.tbl_contains(types, type(v)) then
      return "must be a " .. table.concat(types, " or ")
    end
  end
end

local function dur(min_ms)
  return function(v)
    local ms, err = duration.parse(v)
    if err then
      return err
    end
    if ms and ms < min_ms then
      return ("must be at least %dms"):format(min_ms)
    end
  end
end

local function string_list(v)
  if type(v) ~= "table" or not vim.islist(v) then
    return "must be a list of strings"
  end
  for _, x in ipairs(v) do
    if type(x) ~= "string" then
      return "must be a list of strings"
    end
  end
end

---Key tables: known names only, each a string or false.
local function keys(names)
  return function(v)
    if type(v) ~= "table" then
      return "must be a table"
    end
    for k, lhs in pairs(v) do
      if not vim.tbl_contains(names, k) then
        return ("unknown key %s (known: %s)"):format(vim.inspect(k), table.concat(names, ", "))
      end
      if lhs ~= false and (type(lhs) ~= "string" or lhs == "") then
        return ("%s must be a key string or false"):format(k)
      end
    end
  end
end

local function optional(check)
  return function(v)
    if v ~= nil then
      return check(v)
    end
  end
end

local MAPPING_NAMES = { "start", "refresh", "stop", "list", "sidebar" }

local SPEC = {
  mappings = function(v)
    if type(v) == "boolean" then
      return nil
    end
    return keys(MAPPING_NAMES)(v)
  end,
  countdown_interval = int(100),
  countdown_position = enum("right_align", "eol", "overlay"),
  styles = of_type("table"),
  ticks = enum("nice", "linear"),
  register = of_type("table"),
  sidebar = {
    width = size.check,
    position = enum("left", "right"),
    dir = optional(of_type("string", "function")),
    pattern = string_list,
    exclude = string_list,
    keys = keys({ "select", "stop", "refresh", "close" }),
    cursorline = function(v)
      if v ~= "line" and v ~= "name" and v ~= false then
        return 'must be "line", "name" or false'
      end
    end,
  },
  dashboard = {
    open = enum("current", "vsplit", "split", "tab"),
    pause_hidden = of_type("boolean"),
    keys = keys({ "modify", "show_args", "refresh", "reset", "show_sql", "export", "describe" }),
    icons = {
      description = function(v)
        if type(v) ~= "string" or v == "" then
          return "must be a non-empty string"
        end
      end,
    },
  },
  popup = {
    border = of_type("string", "table"),
    max_width = size.check,
    max_height = size.check,
  },
  defaults = {
    interval = dur(1000),
    timeout = dur(1),
    connect_timeout = dur(1),
    max_rows = int(1),
    height = optional(int(3)),
    min_height = int(1),
    countdown_format = of_type("string"),
    history = int(1),
  },
  errors = {
    notify = enum("once", "always", "never"),
    backoff = int(1),
  },
  lua = {
    confirm = of_type("boolean"),
    trusted_dirs = string_list,
    max_callbacks = int(1),
    max_callback_depth = int(1),
  },
  push = {
    max_queue = int(1),
    max_record = require("dbdash.util.bytes").check,
  },
}

---Check `opts` against SPEC; invalid or unknown entries are reported and replaced by the
---default, so a typo never breaks startup.
---@return string[] errors
local function validate(opts, spec, dflt, path, errors)
  for k, v in pairs(opts) do
    local name = path .. tostring(k)
    local check = spec[k]
    if check == nil then
      errors[#errors + 1] = name .. ": unknown option"
      opts[k] = nil
    elseif type(check) == "table" then
      if type(v) ~= "table" then
        errors[#errors + 1] = name .. ": must be a table"
        opts[k] = vim.deepcopy(dflt[k])
      else
        validate(v, check, dflt[k] or {}, name .. ".", errors)
      end
    else
      local err = check(v)
      if err then
        errors[#errors + 1] = name .. ": " .. err
        opts[k] = vim.deepcopy(dflt[k])
      end
    end
  end
  return errors
end
M.validate = function(opts)
  return validate(opts, SPEC, defaults, "", {})
end

---A `defaults` duration in milliseconds.
---@param name "interval"|"timeout"|"connect_timeout"
---@return integer
function M.default_ms(name)
  return (duration.parse(M.options.defaults[name])) or (duration.parse(defaults.defaults[name]))
end

-- Global mappings ---------------------------------------------------------------------------

M.MAPPINGS = {
  { name = "start", lhs = "<leader>ds", rhs = ":DbDashStart ", desc = "Start a dashboard" },
  { name = "refresh", lhs = "<leader>dr", rhs = "<Cmd>DbDashRestart<CR>", desc = "Refresh the dashboard" },
  { name = "stop", lhs = "<leader>dt", rhs = "<Cmd>DbDashStop<CR>", desc = "Stop the dashboard" },
  { name = "list", lhs = "<leader>dl", rhs = "<Cmd>DbDashList<CR>", desc = "List dashboards" },
  { name = "sidebar", lhs = "<leader>dd", rhs = "<Cmd>DbDash<CR>", desc = "Open the sidebar" },
}

---Mappings to define for the `mappings` option: { lhs, rhs, desc }[].
local function active_mappings()
  local m = M.options.mappings
  if m == false then
    return {}
  end
  local out = {}
  for _, def in ipairs(M.MAPPINGS) do
    local lhs = def.lhs
    if type(m) == "table" and m[def.name] ~= nil then
      lhs = m[def.name]
    end
    if lhs then
      out[#out + 1] = { lhs, def.rhs, def.desc }
    end
  end
  return out
end

---Define the global mappings unless the keys are already mapped by the user.
function M.set_mappings()
  for _, m in ipairs(active_mappings()) do
    if vim.fn.maparg(m[1], "n") == "" then
      vim.keymap.set("n", m[1], m[2], { desc = "dbdash: " .. m[3] })
    end
  end
end

---Remove the global mappings this plugin defined (found by their description).
function M.del_mappings()
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if map.desc and map.desc:find("^dbdash: ") then
      pcall(vim.keymap.del, "n", map.lhs)
    end
  end
end

---@param opts dbdash.Options?
function M.setup(opts)
  opts = vim.deepcopy(opts or {})
  local errors = M.validate(opts)
  M.setup_errors = errors -- shown by :checkhealth dbdash
  if #errors > 0 then
    vim.notify("dbdash setup: " .. table.concat(errors, "\n"), vim.log.levels.ERROR)
  end
  -- Lists replace the default instead of merging by index.
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  for _, path in ipairs({ { "sidebar", "pattern" }, { "sidebar", "exclude" }, { "lua", "trusted_dirs" } }) do
    local v = opts[path[1]] and opts[path[1]][path[2]]
    if v then
      M.options[path[1]][path[2]] = v
    end
  end
  M.del_mappings()
  M.set_mappings()
  for name, impl in pairs(M.options.register or {}) do
    local ok, registry = pcall(require, "dbdash.render.registry")
    if ok then
      registry.register(name, impl)
    end
  end
end

-- Public API ------------------------------------------------------------------------------

-- Sessions: argument values of dashboards, saved and loaded like :mksession / :source --

---Argument values that differ from the config (set on the command line, edited, or
---entered at start) for each running dashboard, as text.
---@private
---@return table<string, table<string, string>> { [config path] = { [argument] = "value" } }
function M._session_state()
  local args = require("dbdash.args")
  local out = {}
  for _, d in ipairs(require("dbdash.scheduler").list()) do
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

---Apply values from _session_state(): running dashboards refresh with them, the others
---get them when they start. Unknown arguments and values that no longer parse are skipped.
---@private
function M._restore_session_state(state)
  local sched = require("dbdash.scheduler")
  for path, values in pairs(state or {}) do
    if type(path) == "string" and type(values) == "table" then
      path = sched.normalize(path)
      local d = sched.get(path)
      if d then
        if M._apply_args(d, values) then
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
  local data = vim.json.encode({ version = 1, dashboards = M._session_state() })
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
  M._restore_session_state(data.dashboards)
  return true
end

---Set argument values (text) as edited values; returns true if any was applied.
---@private
function M._apply_args(d, values)
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
---@private
function M._take_pending(path)
  local v = pending[path]
  pending[path] = nil
  return v
end

---Start a dashboard. `tokens` are "name=value" arguments.
function M.start(path, tokens)
  return require("dbdash.scheduler").start(path, { tokens = tokens })
end

function M.stop(path)
  return require("dbdash.scheduler").stop(require("dbdash.scheduler").normalize(path))
end

---Run a query through the data layer: callback(err, resultset).
function M.query(url, query, opts, callback)
  return require("dbdash.db").query(url, query, opts, callback)
end

return M
