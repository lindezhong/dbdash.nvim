-- Every feature has an example: each template filter, test, global function, method and
-- statement, each config field of the schema, each meta name, each dbdash.* helper and each
-- database scheme appears somewhere in example/ (configs and their helper files). A new
-- feature without an example fails here, listing what is missing.
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

---All text of example/: configs, templates and Lua modules (not the schema).
local function corpus()
  local parts = {}
  for _, ext in ipairs({ "yaml", "sql", "lua" }) do
    for _, f in ipairs(vim.fn.globpath("example", "**/*." .. ext, false, true)) do
      if not f:match("dbdash%.schema%.yaml$") then
        parts[#parts + 1] = table.concat(vim.fn.readfile(f), "\n")
      end
    end
  end
  return table.concat(parts, "\n")
end

local TEXT = corpus()

local function esc(s)
  return (s:gsub("%p", "%%%0"))
end

---Names for which none of the patterns (with %s for the escaped name) matches.
local function missing(names, patterns)
  local out = {}
  for _, n in ipairs(names) do
    local found = false
    for _, p in ipairs(patterns) do
      if TEXT:find(p:format(esc(n))) then
        found = true
        break
      end
    end
    if not found then
      out[#out + 1] = n
    end
  end
  table.sort(out)
  return out
end

local function keys(t)
  local out = vim.tbl_keys(t)
  table.sort(out)
  return out
end

-- Loading the engine installs the filters, tests and globals.
require("dbdash.template")
local R = require("dbdash.template.runtime")

T["every template filter"] = function()
  -- `| name`, or by name: map('name'), select('name').
  eq(missing(keys(R.filters), { "|%%s*%s%%f[^%%w_]", "'%s'" }), {})
end

T["every template test"] = function()
  eq(missing(keys(R.tests), { "is%%s+%s%%f[^%%w_]", "is%%s+not%%s+%s%%f[^%%w_]", "'%s'" }), {})
end

T["every template global function"] = function()
  eq(missing(keys(R.globals), { "%%f[%%w_]%s%%s*%%(" }), {})
end

T["every method of str, dict, list and tuple"] = function()
  local names = {}
  for _, t in pairs(require("dbdash.template.methods").by_type) do
    for k in pairs(t) do
      names[k] = true
    end
  end
  eq(missing(keys(names), { "%%.%s%%(" }), {})
end

T["every template statement and loop attribute"] = function()
  local statements = {
    "if",
    "elif",
    "else",
    "endif",
    "for",
    "endfor",
    "break",
    "continue",
    "set",
    "endset",
    "with",
    "endwith",
    "do",
    "filter",
    "endfilter",
    "raw",
    "endraw",
    "autoescape",
    "endautoescape",
    "macro",
    "endmacro",
    "call",
    "endcall",
    "block",
    "endblock",
    "extends",
    "include",
    "import",
    "from",
    "lua",
    "endlua",
  }
  eq(missing(statements, { "{%%%%[-+]?%%s*%s%%f[^%%w_]" }), {})
  local loop = {
    "index",
    "index0",
    "revindex",
    "revindex0",
    "first",
    "last",
    "length",
    "cycle",
    "changed",
    "previtem",
    "nextitem",
    "depth",
    "depth0",
  }
  eq(missing(loop, { "loop%%.%s%%f[^%%w_]" }), {})
  local forms = {
    "recursive",
    "super()",
    "caller(",
    "varargs",
    "kwargs",
    "scoped",
    "required",
    "self.",
    "ignore missing",
    "with context",
    "without context",
  }
  eq(missing(forms, { "%s" }), {})
end

T["every config field of the schema"] = function()
  local schema = require("dbdash.yaml").parse_file("example/dbdash.schema.yaml")
  local names = {}
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.properties) == "table" then
      for k in pairs(node.properties) do
        names[k] = true
      end
    end
    for _, v in pairs(node) do
      walk(v)
    end
  end
  walk(schema)
  eq(missing(keys(names), { "%%f[%%w_]%s:", '"%s":' }), {})
end

T["every meta name"] = function()
  eq(missing(require("dbdash.metadata").NAMES, { "meta%%.%s%%f[^%%w_]", '"%s"' }), {})
end

T["every dbdash.* Lua helper"] = function()
  local names = keys(require("dbdash.db.lua_env").helpers)
  eq(missing(names, { "dbdash%%.%s%%f[^%%w_]" }), {})
end

T["every database scheme"] = function()
  -- The built-in drivers' schemes (sqlite3 and the others are aliases).
  local schemes = {
    "sqlite",
    "sqlite3",
    "postgres",
    "postgresql",
    "mysql",
    "mariadb",
    "redis",
    "rediss",
    "mongodb",
    "cassandra",
    "cql",
    "mssql",
    "sqlserver",
    "lua",
    "luastream",
    "exec",
    "webhook",
    "http",
    "https",
  }
  eq(missing(schemes, { '"%s://', "type:%%s*%s%%f[^%%w_]" }), {})
end

T["every chart type's example shows all of its renderers (and canvases)"] = function()
  local registry = require("dbdash.render.registry")
  local config = require("dbdash.config")
  local absent = {}
  for t, renderers in pairs(registry.BUILTIN.chart) do
    local f = "example/charts/" .. t .. ".yaml"
    local cfg = config.load(f)
    if not cfg then
      absent[#absent + 1] = f
    else
      local seen = {}
      local d = require("dbdash.dom.build").from_config(cfg)
      for _, p in ipairs(d.panels) do
        local r, canvas =
          registry.resolve(p.cfg.show.type, require("dbdash.css.style").get(p.chart_node))
        seen[r] = true
        if r == "canvas" then
          seen["canvas/" .. canvas] = true
        end
      end
      for _, r in ipairs(renderers) do
        if not seen[r] then
          absent[#absent + 1] = t .. "/" .. r
        end
        if r == "canvas" then
          for _, c in ipairs(registry.BUILTIN.canvas) do
            if not seen["canvas/" .. c] then
              absent[#absent + 1] = t .. "/canvas/" .. c
            end
          end
        end
      end
    end
  end
  table.sort(absent)
  eq(absent, {})
end

return T
