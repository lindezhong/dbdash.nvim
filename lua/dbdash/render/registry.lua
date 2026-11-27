-- Registry of render implementations by "category/name" (:help dbdash-styles):
--   chart/<type>/<renderer>, canvas/<name>, ticks/<name>, frame/<name>, palette/<name>
-- Built-ins load on demand; setup({ register = {...} }) adds or replaces entries.
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

-- Built-in default style per chart type (§11.1).
M.DEFAULTS = {
  table = { renderer = "box" },
  line = { renderer = "canvas", canvas = "braille" },
  scatter = { renderer = "canvas", canvas = "braille" },
  area = { renderer = "canvas", canvas = "braille" },
  bubble = { renderer = "canvas", canvas = "braille" },
  bar = { renderer = "horizontal" },
  histogram = { renderer = "horizontal" },
  boxplot = { renderer = "boxdraw" },
  heatmap = { renderer = "halfblock" },
  pie = { renderer = "bar" },
  stat = { renderer = "big" },
  text = { renderer = "plain" },
}

-- Built-in names, for completion and documentation.
---@type table<string, any> chart: type -> names; the others: names
M.BUILTIN = {
  chart = {
    table = { "box" },
    line = { "canvas", "asciichart" },
    scatter = { "canvas" },
    area = { "canvas" },
    bubble = { "canvas" },
    bar = { "horizontal", "vertical" },
    histogram = { "horizontal", "vertical" },
    boxplot = { "boxdraw", "vertical" },
    heatmap = { "halfblock", "block" },
    pie = { "bar", "circle" },
    stat = { "big" },
    text = { "plain" },
  },
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
  for kind, list in pairs(M.BUILTIN) do
    if kind == "chart" then
      for t, rs in pairs(list) do
        for _, r in ipairs(rs) do
          add("chart/" .. t .. "/" .. r)
        end
      end
    else
      for _, n in ipairs(list) do
        add(kind .. "/" .. n)
      end
    end
  end
  table.sort(out)
  return out
end

---Effective renderer and canvas: the chart element's computed renderer / canvas (from
---style sheets: setup({ style }), the dashboard's, the panel's, :DbDashStyle), else the
---built-in defaults of the type.
---@param t string chart type
---@param computed table? computed style of the chart element
---@return string renderer, string canvas
function M.resolve(t, computed)
  computed = computed or {}
  local d = M.DEFAULTS[t] or {}
  return computed.renderer or d.renderer or "canvas", computed.canvas or d.canvas or "braille"
end

---Known names of a kind: "renderer" (of any chart type), "canvas", "ticks", "palette",
---"frame".
local function known(kind)
  if kind == "renderer" then
    local out = {}
    for t in pairs(M.BUILTIN.chart) do
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
      if not M.DEFAULTS[show.type] and not M.names("chart/" .. show.type .. "/")[1] then
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
