-- The layers of lua/dbdash (ARCHITECTURE.md#layers): a module requires modules of its own
-- layer or below, never above, and no module requires itself through others (no cycles).
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

-- Bottom to top. A module's layer is that of its first name under dbdash ("dbdash.db.url"
-- is db's, "dbdash" itself is init's).
local LAYERS = {
  { "util" },
  { "crypto", "yaml" },
  { "net" },
  { "dom" },
  { "css" },
  { "db" },
  { "template" },
  { "args" },
  { "compositor" },
  { "render" },
  { "paint" },
  { "layout" },
  -- the application: dashboards and what they are made from
  { "options", "config", "trust", "metadata", "session", "export", "dashboard", "health_util" },
  -- UI and entry points (:checkhealth dbdash.<database> is lua/dbdash/<database>/health.lua)
  {
    "init",
    "commands",
    "view",
    "events",
    "inspect",
    "health",
    "cassandra",
    "mongodb",
    "mssql",
    "mysql",
    "postgres",
    "redis",
    "sqlite",
  },
}

-- Requires that still go up, until dashboard/ and view/dashboard are separated
-- (they build the dashboard's DOM and draw it from the application layer, and the
-- dashboard package's files add methods to one package that requires them).
local PENDING = {
  ["dbdash.dom.build"] = true,
  ["dbdash.dashboard"] = true,
  ["dbdash.dashboard.dashboard"] = true,
  ["dbdash.dashboard.lifecycle"] = true,
  ["dbdash.dashboard.panel"] = true,
  ["dbdash.dashboard.run"] = true,
  ["dbdash.dashboard.shared"] = true,
  ["dbdash.dashboard.stream"] = true,
  ["dbdash.dashboard.view"] = true,
}

local level = {}
for i, names in ipairs(LAYERS) do
  for _, n in ipairs(names) do
    level[n] = i
  end
end

local function group(mod)
  return mod:match("^dbdash%.([%w_]+)") or "init"
end

---Every module of lua/dbdash and the dbdash modules it requires.
local function graph()
  local out = {}
  for _, path in ipairs(vim.fn.globpath("lua/dbdash", "**/*.lua", false, true)) do
    local mod = path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
    local deps = {}
    for line in io.lines(path) do
      for dep in line:gmatch('require%("(dbdash[%w_.]*)"%)') do
        if dep ~= mod then
          deps[dep] = true
        end
      end
    end
    out[mod] = deps
  end
  return out
end

T["every module belongs to a layer"] = function()
  local unknown = {}
  for mod in pairs(graph()) do
    if not level[group(mod)] then
      unknown[#unknown + 1] = mod
    end
  end
  table.sort(unknown)
  eq(unknown, {})
end

T["modules require their own layer or below"] = function()
  local up = {}
  for mod, deps in pairs(graph()) do
    for dep in pairs(deps) do
      local a, b = level[group(mod)], level[group(dep)]
      if a and b and b > a and not PENDING[mod] then
        up[#up + 1] = mod .. " -> " .. dep
      end
    end
  end
  table.sort(up)
  eq(up, {})
end

T["no require cycles"] = function()
  local g = graph()
  -- Tarjan's strongly connected components: any with more than one module is a cycle.
  local index, low, stack, on, next_index, cycles = {}, {}, {}, {}, 0, {}
  local function visit(v)
    index[v], low[v], next_index = next_index, next_index, next_index + 1
    stack[#stack + 1], on[v] = v, true
    for w in pairs(PENDING[v] and {} or g[v] or {}) do
      if g[w] then
        if index[w] == nil then
          visit(w)
          low[v] = math.min(low[v], low[w])
        elseif on[w] then
          low[v] = math.min(low[v], index[w])
        end
      end
    end
    if low[v] == index[v] then
      local scc = {}
      repeat
        local w = table.remove(stack)
        on[w] = nil
        scc[#scc + 1] = w
      until w == v
      if #scc > 1 then
        table.sort(scc)
        cycles[#cycles + 1] = table.concat(scc, ", ")
      end
    end
  end
  for v in pairs(g) do
    if index[v] == nil then
      visit(v)
    end
  end
  table.sort(cycles)
  eq(cycles, {})
end

return T
