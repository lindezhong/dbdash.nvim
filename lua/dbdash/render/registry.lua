-- Registry of render implementations by "category/name" (design §11.2, §11.3):
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

---@param name string e.g. "chart/bar/mine", "canvas/sextant"
---@param impl any
function M.register(name, impl)
  assert(name:match("^%w+/.+$"), "registry names look like 'category/name'")
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
  local mod = name == "chart/table/box" and "dbdash.render.table" or (prefix .. rest:gsub("/", "."))
  local ok, res = pcall(require, mod)
  if ok then
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

-- The rules of a config's style sheets (dbdash.config.validators): implementations named
-- in renderer, canvas and palette exist.
M.validators = {
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
              table.concat(vim.fn.uniq(names), ", ")
            )
          end
        end
      end
    end,
  },
}

return M
