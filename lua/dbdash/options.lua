-- setup() options: their types, defaults and checks, and the options in effect.
local M = {}

local db_defaults = require("dbdash.db.defaults") -- the built-in values

---@alias dbdash.Size integer|string columns/rows, or "N%" of the editor width/height

---@alias dbdash.Key
---| "modify"
---| "show_args"
---| "refresh"
---| "reset"
---| "show_sql"
---| "export"
---| "describe"

---@class dbdash.SidebarOptions
---@field width dbdash.Size (default 30)
---@field position "left"|"right" (default "left")
---@field dir string|fun(): string|nil directory to list (default: the current directory)
---@field pattern string[] file globs to list (default { "*.yaml", "*.yml" })
---@field exclude string[] file and directory name globs to skip
---  (default { "*.schema.yaml", "*.schema.yml" })
---@field keys table<"select"|"stop"|"refresh"|"close", string|false>
---@field cursorline "line"|"name"|false cursor line: the global CursorLine over the whole line
---  (default), DbDashSidebarCursor on the name only (keeps the ●/◐/○ marker's color), or none

---@class dbdash.DashboardOptions
---@field open "current"|"vsplit"|"split"|"tab" where :DbDashStart shows a dashboard
---@field pause_hidden boolean stop refreshing while no window of the current tab shows it
---@field keys table<dbdash.Key, string|false>

---@class dbdash.PopupOptions
---@field border string|string[] floating window border (default "rounded")
---@field max_width dbdash.Size (default 120)
---@field max_height dbdash.Size (default "100%")

---@class dbdash.DefaultsOptions
---@field interval string|number refresh interval when a config sets none (default "30s")
---@field timeout string|number query timeout when the URL sets none (default "30s")
---@field connect_timeout string|number (default "10s")
---@field max_rows integer (default 10000)
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
---@field style table<string, table> the user style sheet: selector -> properties
---  (:help dbdash-css); between the default sheet and dashboards' own sheets
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
  style = {},
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
  },
  popup = { border = "rounded", max_width = 120, max_height = "100%" },
  defaults = {
    interval = "30s",
    timeout = db_defaults.BUILTIN.timeout,
    connect_timeout = db_defaults.BUILTIN.connect_timeout,
    max_rows = db_defaults.BUILTIN.max_rows,
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
    max_record = db_defaults.BUILTIN.max_record,
  },
}
M.DEFAULTS = defaults

---The options in effect (setup() replaces them).
---@type dbdash.Options
M.current = vim.deepcopy(defaults)

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
  style = function(v)
    if type(v) ~= "table" then
      return "must be a style sheet (selector -> properties)"
    end
    local selectors = vim.tbl_keys(v)
    table.sort(selectors)
    local _, err = require("dbdash.css.parser").sheet(v, selectors)
    if err then
      -- a declaration's message names its property, a selector's the selector
      return err.property and ("%s: %s"):format(err.key, err.message) or err.message
    end
  end,
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
-- Appearance options that moved into setup({ style }).
local MOVED = {
  styles = 'style: { ["chart.line"] = { renderer = "...", canvas = "..." } }',
  ["dashboard.icons"] = 'style: { ["description-icon"] = { content = "ⓘ" } }',
  ["defaults.height"] = "style: { plot = { height = N } }",
  ["defaults.min_height"] = 'style: { plot = { ["min-height"] = N } }',
  ["defaults.countdown_format"] = 'style: { countdown = { content = "..." } }',
  palette = "style: { chart = { palette = name } }",
}

local function validate(opts, spec, dflt, path, errors)
  for k, v in pairs(opts) do
    local name = path .. tostring(k)
    local check = spec[k]
    if MOVED[name] then
      errors[#errors + 1] = ("%s: appearance moved to %s"):format(name, MOVED[name])
      opts[k] = nil
    elseif check == nil then
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
  return (duration.parse(M.current.defaults[name])) or (duration.parse(defaults.defaults[name]))
end

---Set the options from setup(): invalid or unknown entries are reported (setup_errors)
---and fall back to their default; lists replace the default instead of merging by index.
---@param opts dbdash.Options?
---@return string[] errors
function M.set(opts)
  opts = vim.deepcopy(opts or {})
  local errors = M.validate(opts)
  M.setup_errors = errors -- shown by :checkhealth dbdash
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  for _, path in ipairs({
    { "sidebar", "pattern" },
    { "sidebar", "exclude" },
    { "lua", "trusted_dirs" },
  }) do
    local v = opts[path[1]] and opts[path[1]][path[2]]
    if v then
      M.current[path[1]][path[2]] = v
    end
  end
  -- Lower layers do not read these options: they are set there (required now, so a
  -- reloaded module gets them too).
  require("dbdash.db.defaults").set({
    timeout = M.current.defaults.timeout,
    connect_timeout = M.current.defaults.connect_timeout,
    max_rows = M.current.defaults.max_rows,
    max_record = M.current.push.max_record,
  })
  require("dbdash.css").user_style = M.current.style
  local registry = require("dbdash.render.registry")
  registry.ticks = M.current.ticks
  for name, impl in pairs(M.current.register or {}) do
    registry.register(name, impl)
  end
  return errors
end

return M
