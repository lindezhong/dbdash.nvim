-- query.transform: Lua that reshapes the result of any database.
local sched = require("dbdash.scheduler")
local h = require("tests.helpers")
local eq = MiniTest.expect.equality

local dir
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      require("dbdash").setup({ lua = { confirm = false } }) -- trust is tested in test_trust.lua
    end,
    post_case = function()
      require("dbdash").setup({})
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
    end,
  },
})

---Start a dashboard from config lines and wait for its first result (or error).
local function run(name, lines)
  local path = dir .. "/" .. name .. ".yaml"
  vim.fn.writefile(lines, path)
  sched.start(path, { no_show = true })
  local d = assert(sched.get(sched.normalize(path)), "dashboard did not start")
  local p = d.panels[1]
  vim.wait(20000, function()
    return (p.rs or p.error) and not p.running
  end, 10)
  return p
end

-- A transform that doubles the numeric second column and renames it.
local TRANSFORM = {
  "  transform: |",
  "    local out = {}",
  "    for _, r in ipairs(rs.rows) do out[#out + 1] = { k = r[1], v = r[2] * args.f } end",
  "    return { columns = { 'k', 'v' }, rows = out }",
}

local function board(url, sql)
  local lines = {
    ("database: { url: %q }"):format(url),
    "query:",
    "  args: [{ name: f, type: int, default: 2 }]",
    ("  sql: %q"):format(sql),
  }
  vim.list_extend(lines, TRANSFORM)
  lines[#lines + 1] = "show: { type: table }"
  return lines
end

T["sqlite: the transform's rows replace the result"] = function()
  local p = run("sqlite", board("sqlite:///:memory:", "SELECT 'a' AS name, 21 AS n"))
  eq(p.error, nil)
  eq({ p.rs.columns[1].name, p.rs.columns[2].name, p.rs.rows }, { "k", "v", { { "a", 42 } } })
end

T["template in the transform; errors point at the YAML line"] = function()
  local p = run("tpl", {
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  args: [{ name: f, type: int, default: 3 }]",
    "  sql: SELECT 5 AS n",
    "  transform: |",
    "    return { { n = rs.rows[1][1] * {{ f }} } }",
  })
  eq(p.rs.rows, { { 15 } })
  p = run("bad", {
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  sql: SELECT 5 AS n",
    "  transform: |",
    "    local x = nil",
    "    return x.y",
  })
  eq(p.error.phase, "transform")
  eq(p.error.message:find("bad.yaml:6: attempt to index local 'x'", 1, true) ~= nil, true)
end

T["rs gives names, types and rows with nil for NULL"] = function()
  local p = run("shape", {
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  sql: SELECT 1 AS a, NULL AS b",
    "  transform: |",
    "    return { { cols = table.concat(rs.columns, ','), t = rs.types[1], b_is_nil = rs.rows[1][2] == nil } }",
  })
  eq(p.rs.rows, { { true, "a,b", "integer" } })
end

local DATABASES = {
  { "postgres", "postgres://dbdash:dbdash_pw@127.0.0.1:15432/dbdash_test", "SELECT 'a' AS name, 21 AS n" },
  { "mysql", "mysql://dbdash:dbdash_pw@127.0.0.1:13306/dbdash_test", "SELECT 'a' AS name, 21 AS n" },
  { "mssql", "mssql://sa:Dbdash_pw1@127.0.0.1:11433/master", "SELECT 'a' AS name, 21 AS n" },
  { "cassandra", "cassandra://cassandra:cassandra@127.0.0.1:19042/system", "SELECT cluster_name, native_protocol_version FROM system.local" },
  { "redis", "redis://:dbdash_pw@127.0.0.1:16379/0", "INFO server" },
  { "mongodb", "mongodb://dbdash:dbdash_pw@127.0.0.1:17017/admin?authSource=admin", '{"operation":"aggregate","pipeline":[{"$documents":[{"name":"a","n":21}]}]}' },
}

for _, db in ipairs(DATABASES) do
  T["it: transform works on " .. db[1]] = function()
    h.require_it()
    local p = run(db[1], {
      ("database: { url: %q }"):format(db[2]),
      "query:",
      ("  sql: %q"):format(db[3]),
      "  transform: |",
      "    return { { columns = #rs.columns, rows = #rs.rows, first = rs.columns[1] } }",
    })
    eq(p.error, nil)
    eq(p.rs.columns[1].name, "columns")
    eq(p.rs.rows[1][1] >= 1 and p.rs.rows[1][3] >= 1, true)
  end
end

return T
