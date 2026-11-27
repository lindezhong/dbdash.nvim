local db = require("dbdash.db")
local map = require("dbdash.util.map")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function run(raw, q, opts)
  local res
  db.query(raw, q, opts or {}, function(err, rs)
    res = { err = err, rs = rs }
  end)
  vim.wait(5000, function()
    return res ~= nil
  end, 5)
  assert(res, "query did not complete")
  return res
end

local function ok(q, opts, raw)
  local r = run(raw or "sqlite:///:memory:", q, opts)
  if r.err then
    error(tostring(r.err))
  end
  return r.rs
end

local function types(rs)
  local out = {}
  for i, c in ipairs(rs.columns) do
    out[i] = c.type
  end
  return out
end

T["expressions infer types from storage classes"] = function()
  local rs =
    ok("SELECT 1 AS i, 'Alice' AS s, NULL AS n, 1.5 AS r, x'00ff' AS b, 9223372036854775807 AS big")
  eq(rs:column_names(), { "i", "s", "n", "r", "b", "big" })
  eq(types(rs), { "integer", "string", "null", "number", "bytes", "integer" })
  eq(rs.rows[1], { 1, "Alice", vim.NIL, 1.5, "\0\255", "9223372036854775807" })
end

T["declared types map to logical types"] = function()
  local rs = ok([[
    CREATE TABLE t (id INTEGER, name VARCHAR(10), price DECIMAL(10,2), ok BOOLEAN,
                    at DATETIME, d DATE, meta JSON, ratio REAL, raw BLOB);
    INSERT INTO t VALUES (1, '中文', 9.5, 1, '2026-11-20 10:00:00', '2026-11-20',
                          '{"b": [1, 2], "a": null}', 0.25, x'cafe');
    INSERT INTO t VALUES (2, NULL, 3, 0, NULL, NULL, '[]', NULL, NULL);
    SELECT * FROM t ORDER BY id;
  ]])
  eq(
    types(rs),
    { "integer", "string", "decimal", "boolean", "datetime", "date", "json", "number", "bytes" }
  )
  local r1, r2 = rs.rows[1], rs.rows[2]
  eq(
    { r1[1], r1[2], r1[3], r1[4], r1[5], r1[6], r1[8], r1[9] },
    { 1, "中文", "9.5", true, "2026-11-20 10:00:00", "2026-11-20", 0.25, "\202\254" }
  )
  eq(map.keys(r1[7]), { "a", "b" })
  eq(r1[7].b, { 1, 2 })
  eq(r1[7].a, vim.NIL)
  eq({ r2[2], r2[3], r2[4], r2[7] }, { vim.NIL, "3", false, {} })
  eq(rs.columns[3].db_type, "DECIMAL(10,2)")
end

T["max_rows truncates"] = function()
  local rs = ok(
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 50) SELECT x FROM c",
    { max_rows = 10 }
  )
  eq({ rs.row_count, rs.truncated, rs.rows[10][1] }, { 10, true, 10 })
  rs = ok("SELECT 1", { max_rows = 1 })
  eq(rs.truncated, false)
end

T["non-UTF-8 text survives as raw bytes"] = function()
  local rs = ok("SELECT CAST(x'ff41' AS TEXT) AS t")
  eq(rs.rows[1][1], "\255A")
end

T["errors carry phase and code"] = function()
  local r = run("sqlite:///:memory:", "SELEC 1")
  eq({ r.err.driver, r.err.phase }, { "sqlite", "query" })
  eq(r.err.message:find("syntax error") ~= nil, true)
  eq(r.err.code, "SQLITE_1")
  r = run("sqlite:///nonexistent/dir/x.db", "SELECT 1")
  eq(r.err.phase, "connect")
end

T["files: relative paths resolve against base_dir, readonly option"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/t.db"
  eq(run("sqlite://" .. file, "SELECT 1").err.phase, "connect") -- not created by default
  ok(
    "CREATE TABLE x(v); INSERT INTO x VALUES (42);",
    { options = { create = true } },
    "sqlite://" .. file
  )
  eq(ok("SELECT v FROM x", { base_dir = dir }, "sqlite://t.db").rows[1][1], 42)
  local r = run(
    "sqlite://t.db",
    "INSERT INTO x VALUES (1)",
    { base_dir = dir, options = { readonly = true } }
  )
  eq(r.err.message:find("readonly") ~= nil, true)
end

T["the query timeout interrupts long statements"] = function()
  local r = run(
    "sqlite:///:memory:?timeout=100ms",
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"
  )
  eq(r.err.phase, "timeout")
end

T["bad lib_path is reported"] = function()
  local r =
    run("sqlite:///:memory:", "SELECT 1", { options = { lib_path = "/nope/libsqlite3.so" } })
  eq({ r.err.phase, r.err.message:find("lib_path") ~= nil }, { "connect", true })
end

T["repeated queries that run the progress handler do not abort"] = function()
  -- Regression: once the worker's step loop was JIT-compiled, the progress callback made
  -- LuaJIT raise "bad callback" and Neovim abort. This sequence triggered it reliably.
  local q = {
    "WITH RECURSIVE h(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM h WHERE n < 23) SELECT printf('%02d', n) AS hour, 50 + abs(random() % 100) AS visits FROM h",
    "SELECT 'North' AS region, 120 AS sales UNION ALL SELECT 'South', 80 UNION ALL SELECT 'East', 95",
    "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 80) SELECT abs(random() % 100) AS score FROM n",
  }
  for _, i in ipairs({ 1, 1, 1, 2, 3, 2, 3, 1, 3, 1, 2, 3 }) do
    local rs = require("tests.helpers").ok("sqlite:///:memory:", q[i])
    eq(rs.row_count > 0, true)
  end
end

T["Windows: sqlite:///C:/... is the drive path, relative paths join base_dir"] = function()
  local drv = require("dbdash.db.drivers.sqlite")
  local function parse(raw)
    return require("dbdash.db.url").parse(raw) --[[@as dbdash.db.ConnInfo]]
  end
  local os_was = jit.os
  jit.os = "Windows" -- luacheck: ignore 122 (the driver reads jit.os; restored below)
  local passed, err = pcall(function()
    eq(drv.parse_url(parse("sqlite:///C:/data/app.db")).database, "C:/data/app.db")
    eq(drv.parse_url(parse("sqlite://C:/data/app.db")).database, "C:/data/app.db")
    local info = parse("sqlite://sub/app.db")
    info.base_dir = "D:/dash"
    eq(drv.parse_url(info).database, "D:/dash/sub/app.db")
  end)
  jit.os = os_was -- luacheck: ignore 122
  assert(passed, err)
  if os_was ~= "Windows" then -- elsewhere a leading slash stays
    eq(drv.parse_url(parse("sqlite:///C:/data/app.db")).database, "/C:/data/app.db")
  end
end

return T
