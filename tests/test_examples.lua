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
      -- Examples run anywhere, except http ones (network access): only with DBDASH_IT.
      if p.database.type == "http" then
        h.require_it()
      end
      eq(({ sqlite = true, lua = true, http = true })[p.database.type], true)
      local sql, terr = template.render(p.query.sql, vars, {
        env = template.env(driver.dialect, p.query.autoescape, cfg.dir),
      })
      if terr then
        error(tostring(terr))
      end
      local rs = h.ok(
        p.database.url,
        sql,
        { options = p.database.options, base_dir = cfg.dir, args = vars, raw = p.query.transform ~= nil }
      )
      if p.query.transform then
        local code = assert(template.render(p.query.transform, vars, { env = template.env(driver.dialect, false, cfg.dir) }))
        local res
        require("dbdash.util.async").run(function()
          return require("dbdash.scheduler").transform(code, rs, { args = vars, max_rows = 1000 })
        end, function(e, out)
          res = { e, out }
        end)
        vim.wait(10000, function()
          return res ~= nil
        end, 5)
        if res[1] then
          error(tostring(res[1]))
        end
        rs = res[2]
      end
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

---The Python command that can run tests/examples_schema.py (python3, python or py -3 with
---jsonschema and PyYAML), or nil. Dev machines only; the plugin itself needs no Python.
local python_cmd
local function have_python()
  if python_cmd ~= nil then
    return python_cmd or nil
  end
  python_cmd = false
  for _, cmd in ipairs({ { "python3" }, { "python" }, { "py", "-3" } }) do
    local ok, r = pcall(function()
      return vim.system(vim.list_extend(vim.deepcopy(cmd), { "-I", "-c", "import jsonschema, yaml" })):wait()
    end)
    if ok and r.code == 0 then
      python_cmd = cmd
      break
    end
  end
  return python_cmd or nil
end

local function schema_check(...)
  local argv = vim.list_extend(vim.deepcopy(have_python()), { "-I", "tests/examples_schema.py", ... })
  return vim.system(argv, { text = true }):wait()
end

T["examples validate against the schema"] = function()
  if not have_python() then
    MiniTest.skip("Python (python3, python or py -3) with jsonschema and PyYAML is needed")
  end
  local r = schema_check()
  eq(r.stdout, "")
  eq(r.code, 0)
end

T["the schema rejects invalid configs"] = function()
  if not have_python() then
    MiniTest.skip("Python (python3, python or py -3) with jsonschema and PyYAML is needed")
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
  local r = schema_check(f)
  eq(r.code, 1)
  eq(r.stdout:find("query/args/0", 1, true) ~= nil, true)
  eq(r.stdout:find("show/type", 1, true) ~= nil, true)
end

return T
