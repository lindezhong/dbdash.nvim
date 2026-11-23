-- query.transform: Lua that reshapes the result of any database. Every source goes
-- query -> transform -> rows check.
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
      h.close_http_servers()
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

T["lua:// and http(s):// give the transform their raw value; rows are checked after it"] = function()
  -- lua://: the script's value as is (not rows), reshaped by the transform
  local p = run("raw_lua", {
    "database: { url: 'lua://' }",
    "query:",
    "  sql: 'return { data = { 3, 4 } }'",
    "  transform: |",
    "    local out = {}",
    "    for _, n in ipairs(rs.data) do out[#out + 1] = { n = n * 2 } end",
    "    return out",
  })
  eq(p.error, nil)
  eq(p.rs.rows, { { 6 }, { 8 } })
  -- http: rs is the decoded body, response the status/headers/body
  local base = h.http_server(function()
    local body = '{"items":[{"name":"a","count":2}]}'
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Page: 1\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
  end)
  p = run("http", {
    ("database: { url: %q }"):format(base .. "/v1"),
    "query:",
    "  sql: '{\"path\": \"items\"}'",
    "  transform: |",
    "    local out = {}",
    "    for _, it in ipairs(rs.items) do",
    "      out[#out + 1] = { name = it.name, n = it.count, page = response.headers['x-page'], status = response.status }",
    "    end",
    "    return { columns = { 'name', 'n', 'page', 'status' }, rows = out }",
  })
  eq(p.error, nil)
  eq(p.rs.rows, { { "a", 2, "1", 200 } })
  -- the transform's value is checked as rows too
  p = run("http_bad", {
    ("database: { url: %q }"):format(base),
    "query:",
    "  transform: 'return rs.items[1].name'",
  })
  eq(p.error.phase, "transform")
  eq(p.error.message, "the result is not rows (got string)")
  -- without a transform the response itself is checked, with a hint
  p = run("http_plain", { ("database: { url: %q }"):format(base) })
  eq(p.error.phase, "query")
  eq(p.error.message:find("the result is an object (items), not rows; add query.transform", 1, true) ~= nil, true)
end

T["http: cookies set by the server are sent on the next refresh, the config is unchanged"] = function()
  local base, seen = h.http_server(function(_, n)
    local set = n == 1 and "Set-Cookie: token=fresh; Path=/\r\n" or ""
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" .. set .. "Content-Length: 2\r\n\r\n[]"
  end)
  local lines = {
    ("database: { url: %q }"):format(base),
    "query:",
    "  sql: '{\"cookies\": \"token=initial; user=me\"}'",
  }
  local p = run("cookies", lines)
  eq(p.error, nil)
  p.rs, p.error = nil, nil
  p:refresh()
  vim.wait(5000, function()
    return #seen >= 2 and not p.running
  end, 10)
  eq(seen[1].headers.cookie, "token=initial; user=me")
  eq(seen[2].headers.cookie, "token=fresh; user=me")
  eq(vim.fn.readfile(dir .. "/cookies.yaml"), lines)
  -- a new start begins with an empty jar
  sched.stop(sched.normalize(dir .. "/cookies.yaml"))
  run("cookies", lines)
  eq(seen[3].headers.cookie, "token=initial; user=me")
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
