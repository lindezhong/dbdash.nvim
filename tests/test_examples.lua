-- Every example config must load, run as a dashboard (render, query, transform: the same
-- path as in the editor) and draw without errors, and validate against
-- example/dbdash.schema.yaml.
local config = require("dbdash.config")
local render = require("dbdash.render")
local sched = require("dbdash.scheduler")
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("dbdash").setup({ lua = { confirm = false } }) -- trust is tested in test_trust.lua
    end,
    post_case = function()
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
    end,
  },
})

-- The configs: one directory per topic (example/<topic>/<name>.yaml); deeper files and
-- *.schema.yaml are not configs.
local files = vim.tbl_filter(function(f)
  return not f:match("%.schema%.yaml$")
end, vim.fn.globpath("example", "*/*.yaml", false, true))
table.sort(files)

---Databases that need `make it-up` (docker) or the network: only with DBDASH_IT.
local LOCAL = { sqlite = true, lua = true, luastream = true, exec = true, webhook = true }

for _, f in ipairs(files) do
  T[f:gsub("^example/", "")] = function()
    local cfg, err = config.load(f)
    eq(err, nil)
    for _, p in ipairs(cfg.panels) do
      -- Examples run anywhere, except the ones on the docker services (make it-up) or the
      -- network: only with DBDASH_IT.
      if not LOCAL[p.database.type] then
        h.require_it()
      end
    end
    sched.start(f, { no_show = true })
    local d = assert(sched.get(sched.normalize(f)), "dashboard did not start")
    ---A webhook panel waits for requests: listening is enough.
    local function waiting(p)
      return p.cfg.database.type == "webhook"
        and not p.error
        and (p:push_state() or ""):match("^listening") ~= nil
    end
    vim.wait(30000, function()
      for _, p in ipairs(d.panels) do
        if not waiting(p) and (not (p.rs or p.error) or p.running) then
          return false
        end
      end
      return true
    end, 10)
    for _, p in ipairs(d.panels) do
      if p.error then
        error(f .. ": " .. sched.format_error(p.error))
      end
      if waiting(p) then
        goto continue
      end
      local rs = assert(p.rs, f .. ": no result")
      eq(rs.row_count > 0, true)
      local out = render.render(rs, p.cfg.show, { width = 100, height = 30 })
      for _, hl in ipairs(out.hl) do
        if hl.group == "DbDashError" or hl.group == "DbDashWarn" then
          error(f .. ": " .. out.lines[hl.row + 1])
        end
      end
      ::continue::
    end
  end
end

-- The template cheat sheets: every row is a template as written and what it rendered.
-- Rendering the template column again (same engine, arguments and SQL dialect) must give
-- the result column, so the examples never show a template that is not the real one.
for _, name in ipairs({ "statements", "filters", "tests_functions", "methods", "sql" }) do
  T["templates/" .. name .. ".yaml: every template renders to its result"] = function()
    local f = "example/templates/" .. name .. ".yaml"
    local cfg = assert(config.load(f))
    local map = require("dbdash.util.map")
    local args = map.new()
    for _, spec in ipairs(cfg.args) do
      map.set(args, spec.name, spec.default)
    end
    sched.start(f, { no_show = true })
    local d = assert(sched.get(sched.normalize(f)))
    vim.wait(10000, function()
      for _, p in ipairs(d.panels) do
        if not (p.rs or p.error) or p.running then
          return false
        end
      end
      return true
    end, 10)
    local tpl = require("dbdash.template")
    local env =
      tpl.env(require("dbdash.db.dialect").get("sqlite"), false, vim.fn.fnamemodify(f, ":h"))
    local checked = 0
    for _, p in ipairs(d.panels) do
      eq(p.error, nil)
      local ti, ri = p.rs:col_index("template"), p.rs:col_index("result")
      if ti and ri then
        for _, row in ipairs(p.rs.rows) do
          local out, err = tpl.render(
            row[ti],
            { args = args, meta = map.new() },
            { env = vim.deepcopy(env) }
          )
          eq({ row[ti], err and err.message or out }, { row[ti], row[ri] })
          checked = checked + 1
        end
      end
    end
    eq(checked > 0, true)
  end
end

T["every example dashboard and panel has a description that renders"] = function()
  for _, f in ipairs(files) do
    local cfg = assert(config.load(f))
    eq({ f, type(cfg.description) == "string" and cfg.description ~= "" }, { f, true })
    for i, p in ipairs(cfg.panels) do
      eq(
        { f, i, type(p.show.description) == "string" and p.show.description ~= "" },
        { f, i, true }
      )
    end
    sched.start(f, { no_show = true })
    local d = assert(sched.get(sched.normalize(f)))
    local results = {}
    local function collect(key)
      return function(err, text)
        results[key] = err and ("ERROR " .. tostring(type(err) == "table" and err.message or err))
          or text
      end
    end
    d:describe_async(collect("dashboard"))
    for i, p in ipairs(d.panels) do
      p:describe_async(collect(i))
    end
    vim.wait(5000, function()
      return vim.tbl_count(results) == #d.panels + 1
    end, 10)
    for key, text in pairs(results) do
      eq(
        { f, key, text:match("^ERROR") == nil and text or text },
        { f, key, text:match("^ERROR") and "(no error)" or text }
      )
    end
    sched.stop(d.path)
  end
end

T["examples cover every chart type and alternative style"] = function()
  local seen = {}
  for _, f in ipairs(files) do
    local d = require("dbdash.dom.build").from_config(assert(config.load(f)))
    for _, p in ipairs(d.panels) do
      local chart = require("dbdash.css.style").get(p.chart_node)
      local renderer, canvas = require("dbdash.render.registry").resolve(p.cfg.show.type, chart)
      seen[p.cfg.show.type .. "/" .. renderer] = true
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
      return vim
        .system(vim.list_extend(vim.deepcopy(cmd), { "-I", "-c", "import jsonschema, yaml" }))
        :wait()
    end)
    if ok and r.code == 0 then
      python_cmd = cmd
      break
    end
  end
  return python_cmd or nil
end

local function schema_check(...)
  local argv =
    vim.list_extend(vim.deepcopy(have_python()), { "-I", "tests/examples_schema.py", ... })
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

-- After the examples ran (the cases above): what they wrote next to themselves (a SQLite
-- file, a curl -c cookie file, ...) is hidden (a name starting with "."), so a checkout
-- stays clean to look at.
T["files the examples write are hidden"] = function()
  if vim.fn.isdirectory(".git") == 0 then
    MiniTest.skip("not a git checkout")
  end
  local r = vim
    .system(
      { "git", "ls-files", "--others", "--ignored", "--exclude-standard", "example" },
      { text = true }
    )
    :wait()
  local visible = {}
  for _, f in ipairs(vim.split(r.stdout or "", "\n", { trimempty = true })) do
    if not vim.fs.basename(f):match("^%.") then
      visible[#visible + 1] = f
    end
  end
  eq(visible, {})
end

return T
