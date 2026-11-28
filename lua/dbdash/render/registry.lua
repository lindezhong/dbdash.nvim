-- Registry of render implementations by "category/name" (:help dbdash-styles):
--   chart/<type>/<renderer>, canvas/<name>, ticks/<name>, frame/<name>, palette/<name>
-- Built-ins load on demand; setup({ register = {...} }) adds or replaces entries (a
-- renderer of a chart type, a canvas, ...). Chart types themselves are directories, found
-- (M.types).
local M = {}

local items = {}

---The tick algorithm of charts that name none (setup ticks).
M.ticks = "nice"

local MODULES = {
  chart = "dbdash.render.charts.",
  canvas = "dbdash.render.canvas.",
  ticks = "dbdash.render.ticks.",
  frame = "dbdash.render.frame.",
  palette = "dbdash.render.palette.",
}

-- Chart types are directories (ARCHITECTURE.md#extending): render/charts/<type>/init.lua
-- on the runtimepath, built-in or the user's, found by their path.
local TYPE_DIR = "lua/dbdash/render/charts/%s/init.lua"
local types -- name -> chart type, once found

---@class dbdash.render.ChartType
---@field renderers string[] its renderers (charts/<type>/<name>.lua), the first the default
---@field canvas string? a canvas chart's default canvas
---@field parts dbdash.render.ChartParts its content as DOM (render/content builds it with it)
---@field style table<string, table>? the default style of its parts (the UA sheet's)

---@class dbdash.render.ChartParts
---@field key fun(show: table): table the show fields the content depends on
---@field build fun(chart: dbdash.dom.Node, rs: dbdash.db.ResultSet, show: table): dbdash.dom.Node?

local function check_type(name, t)
  if type(t) ~= "table" or type(t.renderers) ~= "table" or not t.renderers[1] then
    error(("chart type %s: needs renderers (a list, the first the default)"):format(name), 0)
  end
  if
    type(t.parts) ~= "table"
    or type(t.parts.build) ~= "function"
    or type(t.parts.key) ~= "function"
  then
    error(("chart type %s: needs parts { key, build }"):format(name), 0)
  end
end

---Every chart type (found once; their styles go into the UA sheet).
---@return table<string, dbdash.render.ChartType>
function M.types()
  if not types then
    types = {}
    for _, f in ipairs(vim.api.nvim_get_runtime_file(TYPE_DIR:format("*"), true)) do
      local name = vim.fs.basename(vim.fs.dirname(vim.fs.normalize(f)))
      if not types[name] then
        local t = require("dbdash.render.charts." .. name)
        check_type(name, t)
        types[name] = t
        if t.style then
          require("dbdash.css").add_ua(t.style)
        end
      end
    end
  end
  return types
end

---A chart type by name; nil when there is none.
---@return dbdash.render.ChartType?
function M.type(name)
  return M.types()[name]
end

---The names of the chart types, sorted.
---@return string[]
function M.type_names()
  local out = vim.tbl_keys(M.types())
  table.sort(out)
  return out
end

-- Built-in names of the other categories, for completion and documentation.
---@type table<string, string[]>
M.BUILTIN = {
  canvas = { "braille", "quadrant", "block", "halfblock", "ascii" },
  ticks = { "nice", "linear" },
  frame = { "unicodeplots" },
  palette = { "theme", "tableau" },
}

-- What an implementation of each category provides (render/types.lua).
local REQUIRED = {
  chart = { render = "function" },
  canvas = { new = "function", px_per_char = "table" },
  ticks = { ticks = "function", limits = "function" },
  palette = { color = "function" },
  frame = { render = "function", plot_size = "function", apply_style = "function" },
}

---Raise unless `impl` provides what its category requires.
local function check(name, impl)
  local kind = name:match("^(%w+)/.+$")
  local required = kind and REQUIRED[kind]
  if not required then
    error(
      ("registry names are category/name with a category of %s, not %q"):format(
        table.concat(vim.tbl_keys(REQUIRED), ", "),
        name
      ),
      0
    )
  end
  if type(impl) ~= "table" then
    error(("%s must be a table, not a %s"):format(name, type(impl)), 0)
  end
  for field, want in pairs(required) do
    if type(impl[field]) ~= want then
      error(("%s needs %s (a %s)"):format(name, field, want), 0)
    end
  end
  if (kind == "chart" or kind == "canvas") and impl.name == nil then
    impl.name = name:match("([^/]+)$") -- its name in the registry
  end
end

---Register an implementation (built-in ones load on first use, checked the same way).
---@param name string e.g. "chart/bar/mine", "canvas/sextant"
---@param impl table what its category provides (render/types.lua)
function M.register(name, impl)
  check(name, impl)
  items[name] = impl
end

---Look up an implementation; nil when unknown.
function M.get(name)
  local impl = items[name]
  if impl then
    return impl
  end
  local kind, rest = name:match("^(%w+)/(.+)$")
  local prefix = kind and MODULES[kind]
  if not prefix then
    return nil
  end
  local mod = prefix .. rest:gsub("/", ".")
  local ok, res = pcall(require, mod)
  if ok then
    check(name, res)
    items[name] = res
    return res
  end
  if type(res) == "string" and not res:find("module '" .. mod .. "' not found", 1, true) then
    error(res, 0)
  end
  return nil
end

---Registered and built-in names under a prefix ("chart/line/", "canvas/").
function M.names(prefix)
  local seen, out = {}, {}
  local function add(n)
    if vim.startswith(n, prefix) and not seen[n] then
      seen[n] = true
      out[#out + 1] = n:sub(#prefix + 1)
    end
  end
  for n in pairs(items) do
    add(n)
  end
  for t, def in pairs(M.types()) do
    for _, r in ipairs(def.renderers) do
      add("chart/" .. t .. "/" .. r)
    end
  end
  for kind, list in pairs(M.BUILTIN) do
    for _, n in ipairs(list) do
      add(kind .. "/" .. n)
    end
  end
  table.sort(out)
  return out
end

---Effective renderer and canvas: the chart element's computed renderer / canvas (from
---style sheets: setup({ style }), the dashboard's, the panel's, :DbDashStyle), else the
---defaults of the type (its first renderer, its canvas).
---@param t string chart type
---@param computed table? computed style of the chart element
---@return string renderer, string canvas
function M.resolve(t, computed)
  computed = computed or {}
  local d = M.type(t) or { renderers = {} }
  return computed.renderer or d.renderers[1] or "canvas", computed.canvas or d.canvas or "braille"
end

---Known names of a kind: "renderer" (of any chart type), "canvas", "ticks", "palette",
---"frame".
local function known(kind)
  if kind == "renderer" then
    local out = {}
    for t in pairs(M.types()) do
      vim.list_extend(out, M.names("chart/" .. t .. "/"))
    end
    return out
  end
  return M.names(kind .. "/")
end

-- The rules of a config's charts and style sheets (config/validators.lua): the chart type
-- is known; implementations named in renderer, canvas and palette exist.
M.validators = {
  {
    field = "show",
    validate = function(show, ctx, path)
      if not M.type(show.type) then
        ctx:fail(path .. ".type", "unknown chart type '%s'", show.type)
      end
    end,
  },
  {
    field = "style",
    validate = function(rules, ctx, path)
      for _, rule in ipairs(rules or {}) do
        for _, kind in ipairs({ "renderer", "canvas", "palette" }) do
          local name = rule.decls[kind]
          if type(name) == "string" and not vim.tbl_contains(known(kind), name) then
            local names = known(kind)
            table.sort(names)
            ctx:fail(
              ("%s.%s.%s"):format(path, rule.key, kind),
              "unknown %s '%s' (known: %s)",
              kind,
              name,
              table.concat(vim.fn.uniq(names) --[[@as string[] ]], ", ")
            )
          end
        end
      end
    end,
  },
}

return M
