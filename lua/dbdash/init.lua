-- dbdash.nvim: database dashboards in Neovim.
local M = {}

---@alias dbdash.Size integer|string columns/rows, or "N%" of the editor width/height

---@class dbdash.SidebarOptions
---@field width dbdash.Size (default 30)
---@field position "left"|"right" (default "left")
---@field dir string|fun(): string|nil directory to list (default: the current directory)
---@field pattern string[] file globs to list (default { "*.yaml", "*.yml" })
---@field exclude string[] file globs to skip (default { "*.schema.yaml", "*.schema.yml" })
---@field recursive boolean also list subdirectories (default false)
---@field keys table<"select"|"stop"|"refresh"|"close", string|false>

---@class dbdash.DashboardOptions
---@field open "current"|"vsplit"|"split"|"tab" where :DbDashStart shows a dashboard
---@field keys table<"modify"|"show_args"|"refresh"|"reset"|"show_sql", string|false>

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
---@field countdown_format string (default "Next update: {time}s")
---@field history integer queries kept for :DbDashStatus (default 20)

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
    recursive = false,
    keys = { select = "<CR>", stop = "t", refresh = "r", close = "q" },
  },
  dashboard = {
    open = "current",
    keys = { modify = "a", show_args = "A", refresh = "r", reset = "R", show_sql = "s" },
  },
  popup = { border = "rounded", max_width = 120, max_height = "100%" },
  defaults = {
    interval = "30s",
    timeout = "30s",
    connect_timeout = "10s",
    max_rows = 10000,
    height = nil,
    countdown_format = "Next update: {time}s",
    history = 20,
  },
}
M.DEFAULTS = defaults

---@type dbdash.Options
M.options = vim.deepcopy(defaults)

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
    recursive = of_type("boolean"),
    keys = keys({ "select", "stop", "refresh", "close" }),
  },
  dashboard = {
    open = enum("current", "vsplit", "split", "tab"),
    keys = keys({ "modify", "show_args", "refresh", "reset", "show_sql" }),
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
    countdown_format = of_type("string"),
    history = int(1),
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
  if #errors > 0 then
    vim.notify("dbdash setup: " .. table.concat(errors, "\n"), vim.log.levels.ERROR)
  end
  -- Lists replace the default instead of merging by index.
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  for _, path in ipairs({ { "sidebar", "pattern" }, { "sidebar", "exclude" } }) do
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
