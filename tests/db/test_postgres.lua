local pg = require("dbdash.db.drivers.postgres")
local h = require("tests.helpers")
local map = require("dbdash.util.map")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["md5 password"] = function()
  eq(pg.md5_password("joe", "secret", "\1\2\3\4"), "md5850be429f1fe77df3f603ac424abb440")
end

T["SCRAM-SHA-256 (RFC 7677 example)"] = function()
  local sent = {}
  local replies = {
    {
      11,
      "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
    },
    { 12, "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=" },
  }
  pg.scram("pencil", function(mech, data)
    sent[#sent + 1] = mech .. " " .. data
  end, function(data)
    sent[#sent + 1] = data
  end, function()
    return unpack(table.remove(replies, 1))
  end, "rOprNGfwEbeRWgbNEkqO", "user")
  eq(sent, {
    "SCRAM-SHA-256 n,,n=user,r=rOprNGfwEbeRWgbNEkqO",
    "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
  })
end

T["SCRAM rejects a wrong server signature"] = function()
  local replies = {
    {
      11,
      "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
    },
    { 12, "v=AAAATRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=" },
  }
  local ok, err = pcall(pg.scram, "pencil", function() end, function() end, function()
    return unpack(table.remove(replies, 1))
  end, "rOprNGfwEbeRWgbNEkqO", "user")
  eq({ ok, err.phase, err.message:find("signature mismatch") ~= nil }, { false, "auth", true })
end

T["array literals"] = function()
  eq(pg.parse_array("{1,2,NULL}", 23), { 1, 2, vim.NIL })
  eq(pg.parse_array('{"a b","c\\"d",e,"NULL"}', 25), { "a b", 'c"d', "e", "NULL" })
  eq(pg.parse_array("{{1,2},{3,4}}", 23), { { 1, 2 }, { 3, 4 } })
  eq(pg.parse_array("{}", 23), {})
  eq(pg.parse_array("[0:1]={7,8}", 23), { 7, 8 })
  eq(pg.parse_array("{t,f}", 16), { true, false })
end

T["text values by OID"] = function()
  eq(pg.decode_value("9223372036854775807", 20), "9223372036854775807")
  eq(pg.decode_value("42", 23), 42)
  eq(pg.decode_value("NaN", 701) ~= pg.decode_value("NaN", 701), true)
  eq(pg.decode_value("\\x00ff", 17), "\0\255")
  eq(pg.decode_value("t", 16), true)
  eq(pg.decode_value("123.4500", 1700), "123.4500")
  local j = pg.decode_value('{"b": [1, 2], "a": null}', 3802)
  eq({ map.keys(j), j.b }, { { "a", "b" }, { 1, 2 } })
end

T["error responses"] = function()
  local f = pg.parse_error('SERROR\0C42601\0Msyntax error at or near "SELEC"\0P1\0\0')
  eq(f, { S = "ERROR", C = "42601", M = 'syntax error at or near "SELEC"', P = "1" })
end

-- Integration (make it) ---------------------------------------------------------------------

local URL = "postgres://dbdash:dbdash_pw@127.0.0.1:15432/dbdash_test"

local function types(rs)
  local out = {}
  for i, c in ipairs(rs.columns) do
    out[i] = c.type
  end
  return out
end

T["it: SCRAM login and type mapping"] = function()
  h.require_it()
  local rs = h.ok(
    URL,
    [[
    SELECT 1::int2 AS a, 2::int4 AS b, 9223372036854775807::int8 AS c, 1.5::float8 AS d,
           12.30::numeric(6,2) AS e, true AS f, 'héllo'::text AS g, '\x00ff'::bytea AS h,
           '2026-11-20'::date AS i, '2026-11-20 10:00:00+00'::timestamptz AS j,
           '{"k": [1, 2]}'::jsonb AS k, ARRAY[1, NULL, 3] AS l, ARRAY['x y', 'z'] AS m,
           'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS n, NULL::text AS o
  ]]
  )
  eq(types(rs), {
    "integer",
    "integer",
    "integer",
    "number",
    "decimal",
    "boolean",
    "string",
    "bytes",
    "date",
    "datetime",
    "json",
    "array",
    "array",
    "uuid",
    "string",
  })
  local r = rs.rows[1]
  eq(
    { r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9] },
    { 1, 2, "9223372036854775807", 1.5, "12.30", true, "héllo", "\0\255", "2026-11-20" }
  )
  eq(r[10]:match("^2026%-11%-20 10:00:00") ~= nil, true)
  eq(
    { r[11].k, r[12], r[13], r[14], r[15] },
    { { 1, 2 }, { 1, vim.NIL, 3 }, { "x y", "z" }, "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", vim.NIL }
  )
  eq(rs.columns[11].db_type, "jsonb")
end

T["it: md5 login"] = function()
  h.require_it()
  local rs = h.ok("postgres://md5_user:md5_pw@127.0.0.1:15432/dbdash_test", "SELECT current_user")
  eq(rs.rows[1][1], "md5_user")
end

T["it: multiple statements, max_rows and notices"] = function()
  h.require_it()
  local rs = h.ok(
    URL,
    [[
    CREATE TEMP TABLE t (n int);
    INSERT INTO t SELECT generate_series(1, 100);
    SELECT n FROM t ORDER BY n;
  ]],
    { max_rows = 10 }
  )
  eq({ rs.row_count, rs.truncated, rs.rows[10][1] }, { 10, true, 10 })
  rs = h.ok(URL, "DO $$ BEGIN RAISE NOTICE 'hi there'; END $$; SELECT 1")
  eq(rs.warnings, { "NOTICE: hi there" })
end

T["it: errors carry code and position"] = function()
  h.require_it()
  local r = h.query(URL, "SELECT 1 FROM nope")
  eq(
    { r.err.phase, r.err.code, r.err.position, r.err.driver },
    { "query", "42P01", 15, "postgres" }
  )
  r = h.query("postgres://dbdash:wrong@127.0.0.1:15432/dbdash_test", "SELECT 1")
  eq({ r.err.phase, r.err.code }, { "auth", "28P01" })
  r = h.query("postgres://dbdash@127.0.0.1:15432/dbdash_test", "SELECT 1")
  eq(r.err.phase, "auth")
  r = h.query("postgres://dbdash:dbdash_pw@127.0.0.1:15432/missing_db", "SELECT 1")
  eq({ r.err.phase, r.err.code }, { "connect", "3D000" })
  r = h.query(URL .. "?timeout=300ms", "SELECT pg_sleep(2)")
  eq(r.err.phase, "timeout")
end

T["it: connection still usable after an error inside a multi-statement query"] = function()
  h.require_it()
  local r = h.query(URL, "SELECT 1; SELECT 1/0; SELECT 3")
  eq(r.err.code, "22012")
  eq(h.ok(URL, "SELECT 2").rows[1][1], 2)
end

return T
