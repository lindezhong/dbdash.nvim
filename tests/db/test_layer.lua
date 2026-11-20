local db = require("dbdash.db")
local url = require("dbdash.db.url")
local dialect = require("dbdash.db.dialect")
local resultset = require("dbdash.db.resultset")
local async = require("dbdash.util.async")
local map = require("dbdash.util.map")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function url_err(raw)
  local ok, e = pcall(url.parse, raw)
  eq(ok, false)
  return e.message
end

T["url: full form with percent-decoding"] = function()
  local u = url.parse("postgres://us%40er:p%3Ass@db.example.com:6543/my%20db?tls=require&timeout=5s&sslrootcert=x")
  eq({ u.scheme, u.user, u.password, u.host, u.port, u.database }, { "postgres", "us@er", "p:ss", "db.example.com", 6543, "my db" })
  eq({ u.tls, u.timeout, u.connect_timeout, u.application_name }, { "require", 5000, 10000, "dbdash.nvim" })
  eq(u.params.sslrootcert, "x")
end

T["url: minimal forms"] = function()
  local u = url.parse("redis://localhost")
  eq({ u.host, u.port, u.user, u.database }, { "localhost", nil, nil, nil })
  u = url.parse("mysql://root@[::1]:3306/app")
  eq({ u.user, u.password, u.host, u.port }, { "root", nil, "::1", 3306 })
  u = url.parse("redis://:secret@h")
  eq({ u.user, u.password }, { "", "secret" })
end

T["url: sqlite paths"] = function()
  eq(url.parse("sqlite:///:memory:").database, ":memory:")
  eq(url.parse("sqlite:///abs/path.db").database, "/abs/path.db")
  eq(url.parse("sqlite://rel/x.db").database, "rel/x.db")
end

T["url: tls pin requires a valid fingerprint"] = function()
  local fp = "sha256:" .. ("AB:"):rep(31) .. "AB"
  local u = url.parse("postgres://h/db?tls=pin&fingerprint=" .. fp)
  eq(#u.fingerprint, 32)
  eq(u.fingerprint:byte(1), 0xAB)
  eq(url_err("postgres://h?tls=pin"):find("requires fingerprint") ~= nil, true)
  eq(url_err("postgres://h?tls=pin&fingerprint=sha256:AB"):find("32 bytes") ~= nil, true)
  eq(url_err("postgres://h?tls=verify-full"):find("not supported yet") ~= nil, true)
  eq(url_err("postgres://h?tls=maybe"):find("disable, require or pin") ~= nil, true)
end

T["url: invalid input"] = function()
  eq(url_err("not a url"):find("expected scheme") ~= nil, true)
  eq(url_err("pg://h:99999"):find("port out of range") ~= nil, true)
  eq(url_err("pg://h?timeout=soon"):find("timeout") ~= nil, true)
  eq(url.redact("postgres://u:secret@h/db"), "postgres://u:***@h/db")
end

T["dialect: strings and identifiers"] = function()
  local pg, my, ms = dialect.get("postgres"), dialect.get("mysql"), dialect.get("mssql")
  eq(pg.quote_string("it's \\ ok"), "'it''s \\ ok'")
  eq(my.quote_string("it's \\ ok\n"), "'it''s \\\\ ok\\n'")
  eq(ms.quote_string("中文"), "N'中文'")
  eq(pg.quote_ident("public.users"), '"public"."users"')
  eq(my.quote_ident("users"), "`users`")
  eq(ms.quote_ident("dbo.t"), "[dbo].[t]")
  eq(pcall(pg.quote_ident, "bad name"), false)
  eq(pcall(pg.quote_ident, 'x"; DROP'), false)
end

T["dialect: literals"] = function()
  local pg, ms, mongo = dialect.get("postgres"), dialect.get("mssql"), dialect.get("mongodb")
  eq(pg.literal(vim.NIL), "NULL")
  eq(pg.literal(true), "TRUE")
  eq(ms.literal(false), "0")
  eq(pg.literal(1.5), "1.5")
  eq(pg.literal({ 1, "a", vim.NIL }), "(1, 'a', NULL)")
  eq(pg.literal({}), "(NULL)")
  eq(mongo.literal("x\"y"), '"x\\"y"')
  eq(mongo.literal(map.from_pairs({ { "a", 1 } })), '{"a": 1}')
  eq(pcall(pg.literal, map.new()), false)
end

T["resultset helpers"] = function()
  local rs = resultset.new({ { name = "id", type = "integer" }, { name = "name", type = "string" } }, {
    { 1, "Alice" },
    { 2, db.NULL },
  })
  eq(rs.row_count, 2)
  eq(rs:col_index("name"), 2)
  eq(rs:get(1, "name"), "Alice")
  eq(rs:column("id"), { 1, 2 })
  local recs = rs:records()
  eq(map.keys(recs[1]), { "id", "name" })
  eq(recs[2].name, vim.NIL)
  eq(resultset.integer("123"), 123)
  eq(resultset.integer("9007199254740993"), "9007199254740993")
  eq(resultset.integer("-9007199254740992"), -9007199254740992)
end

-- Fake driver to exercise the DriverManager contract.
local log = {}
db.register({
  name = "fake",
  schemes = { "fake" },
  connect = function(info)
    log[#log + 1] = "connect " .. (info.host or "")
    if info.host == "down" then
      require("dbdash.db.error").raise("connect", "connection refused")
    end
    return {
      execute = function(_, q, opts)
        log[#log + 1] = "execute " .. q
        if q == "boom" then
          require("dbdash.db.error").raise("query", "syntax error", { code = "42601" })
        elseif q == "slow" then
          async.sleep(500)
        elseif q == "crash" then
          local t = nil
          return t.x
        end
        return resultset.new({ { name = "max_rows", type = "integer" } }, { { opts.max_rows } })
      end,
      close = function()
        log[#log + 1] = "close"
      end,
    }
  end,
})

local function run(raw, q, opts)
  local res
  db.query(raw, q, opts, function(err, rs)
    res = { err = err, rs = rs }
  end)
  vim.wait(2000, function()
    return res ~= nil
  end, 5)
  return res
end

T["manager: success closes the connection"] = function()
  log = {}
  local r = run("fake://h", "select", { max_rows = 7 })
  eq(r.err, nil)
  eq(r.rs.rows, { { 7 } })
  eq(r.rs.elapsed_ms >= 0, true)
  eq(log, { "connect h", "execute select", "close" })
end

T["manager: query errors still close and carry the driver name"] = function()
  log = {}
  local r = run("fake://h", "boom")
  eq({ r.err.driver, r.err.phase, r.err.code }, { "fake", "query", "42601" })
  eq(log[#log], "close")
  eq(tostring(r.err), "fake query error: syntax error [42601]")
end

T["manager: connect errors and internal errors"] = function()
  eq(run("fake://down", "x").err.phase, "connect")
  local e = run("fake://h", "crash").err
  eq(e.phase, "internal")
end

T["manager: timeout fires and closes"] = function()
  log = {}
  local r = run("fake://h?timeout=50ms&connect_timeout=50ms", "slow")
  eq(r.err.phase, "timeout")
  vim.wait(600, function()
    return log[#log] == "close"
  end)
  eq(log[#log], "close")
end

T["manager: url and scheme errors"] = function()
  eq(run("oracle://h/x", "q").err.message:find("Oracle") ~= nil, true)
  eq(run("nosuch://h", "q").err.message:find("no driver") ~= nil, true)
  eq(run("mongodb+srv://cluster.example.com/db", "{}").err.message:find("mongodb+srv URLs are not supported yet", 1, true) ~= nil, true)
  eq(run("garbage", "q").err.phase, "config")
end

T["manager: query_async inside a task"] = function()
  local got
  async.run(function()
    return db.query_async("fake://h", "select", { max_rows = 3 })
  end, function(err, rs)
    got = { err, rs and rs.rows[1][1] }
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq(got, { nil, 3 })
end

return T
