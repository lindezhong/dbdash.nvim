-- Every example config must load, render its query, run on SQLite and draw without errors,
-- and validate against example/dbdash.schema.yaml.
local config = require("dbdash.config")
local template = require("dbdash.template")
local args = require("dbdash.args")
local db = require("dbdash.db")
local render = require("dbdash.render")
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local files = vim.tbl_filter(function(f)
  return not f:match("%.schema%.yaml$")
end, vim.fn.globpath("example", "*.yaml", false, true))

for _, f in ipairs(files) do
  T[vim.fs.basename(f)] = function()
    local cfg, err = config.load(f)
    eq(err, nil)
    local vars = args.resolve(cfg.args, args.new_state())
    for _, p in ipairs(cfg.panels) do
      local driver = db.driver(p.database.type)
      eq(p.database.type, "sqlite") -- examples run anywhere
      local sql, terr = template.render(p.query.sql, vars, {
        env = template.env(driver.dialect, p.query.autoescape, cfg.dir),
      })
      if terr then
        error(tostring(terr))
      end
      local rs = h.ok(p.database.url, sql, { options = p.database.options, base_dir = cfg.dir })
      eq(rs.row_count > 0, true)
      local out = render.render(rs, p.show, { width = 100, height = 30 })
      for _, hl in ipairs(out.hl) do
        if hl.group == "DbDashError" or hl.group == "DbDashWarn" then
          error(f .. ": " .. out.lines[hl.row + 1])
        end
      end
    end
  end
end

T["examples cover every chart type and alternative style"] = function()
  local seen = {}
  for _, f in ipairs(files) do
    local cfg = assert(config.load(f))
    for _, p in ipairs(cfg.panels) do
      local renderer, canvas = require("dbdash.render.registry").resolve(p.show, {})
      seen[p.show.type .. "/" .. renderer] = true
      seen["canvas/" .. canvas] = seen["canvas/" .. canvas] or renderer == "canvas"
    end
  end
  for t, renderers in pairs(require("dbdash.render.registry").BUILTIN.chart) do
    for _, r in ipairs(renderers) do
      eq({ t .. "/" .. r, seen[t .. "/" .. r] }, { t .. "/" .. r, true })
    end
  end
end

---True when python3 with jsonschema and PyYAML can validate (dev machines only).
local function have_python()
  local ok, r = pcall(function()
    return vim.system({ "python3", "-I", "-c", "import jsonschema, yaml" }):wait()
  end)
  return ok and r.code == 0
end

T["examples validate against the schema"] = function()
  if not have_python() then
    MiniTest.skip("python3 with jsonschema and PyYAML is needed")
  end
  local r = vim.system({ "python3", "-I", "tests/examples_schema.py" }, { text = true }):wait()
  eq(r.stdout, "")
  eq(r.code, 0)
end

T["the schema rejects invalid configs"] = function()
  if not have_python() then
    MiniTest.skip("python3 with jsonschema and PyYAML is needed")
  end
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile({
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  sql: SELECT 1",
    "  args: [{ key: x }]",
    "show: { type: radar }",
    "bogus: 1",
  }, f)
  local r = vim.system({ "python3", "-I", "tests/examples_schema.py", f }, { text = true }):wait()
  eq(r.code, 1)
  eq(r.stdout:find("query/args/0", 1, true) ~= nil, true)
  eq(r.stdout:find("show/type", 1, true) ~= nil, true)
end

return T
