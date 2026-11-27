local mysql = require("dbdash.db.drivers.mysql")
local h = require("tests.helpers")
local u = require("dbdash.crypto.util")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local NONCE = ""
for i = 1, 20 do
  NONCE = NONCE .. string.char(i)
end

T["auth scrambles (checked with Python hashlib)"] = function()
  eq(u.hex(mysql.native_scramble("secret", NONCE)), "b32bb3a583e1340c0a1108d58b1be49781ad8c2f")
  eq(
    u.hex(mysql.sha2_scramble("secret", NONCE)),
    "746ebe205d56a0707acb3e796e834e0dd7b1d61743b26bd5202c7a623230c7c9"
  )
  eq(mysql.native_scramble("", NONCE), "")
end

T["handshake packet"] = function()
  local p = "\10"
    .. "8.4.0\0"
    .. "\1\0\0\0"
    .. NONCE:sub(1, 8)
    .. "\0"
    .. "\255\255"
    .. "\255"
    .. "\2\0"
    .. "\255\223"
    .. "\21"
    .. string.rep("\0", 10)
    .. NONCE:sub(9)
    .. "\0"
    .. "caching_sha2_password\0"
  local hs = mysql.parse_handshake(p)
  eq(
    { hs.version, hs.thread_id, hs.nonce, hs.plugin },
    { "8.4.0", 1, NONCE, "caching_sha2_password" }
  )
end

T["logical types"] = function()
  eq(mysql.logical(0x08, 0x20, 63), "integer")
  eq(mysql.logical(0xf6, 0, 63), "decimal")
  eq(mysql.logical(0xfd, 0, 255), "string")
  eq(mysql.logical(0xfc, 0x80, 63), "bytes")
  eq(mysql.logical(0xf5, 0, 63), "json")
end

-- Integration (make it) ---------------------------------------------------------------------

local URL = "mysql://dbdash:dbdash_pw@127.0.0.1:13306/dbdash_test"

local function types(rs)
  local out = {}
  for i, c in ipairs(rs.columns) do
    out[i] = c.type
  end
  return out
end

T["it: caching_sha2 full (RSA) then fast authentication"] = function()
  h.require_it()
  h.ok("mysql://root:root_pw@127.0.0.1:13306/", "FLUSH PRIVILEGES") -- empty the auth cache
  eq(h.ok(URL, "SELECT CURRENT_USER()").rows[1][1], "dbdash@%")
  eq(h.ok(URL, "SELECT 1").rows[1][1], 1)
end

T["it: mysql_native_password user"] = function()
  h.require_it()
  eq(
    h.ok("mysql://native_user:native_pw@127.0.0.1:13306/dbdash_test", "SELECT CURRENT_USER()").rows[1][1],
    "native_user@%"
  )
end

T["it: type mapping"] = function()
  h.require_it()
  local rs = h.ok(
    URL,
    [[
    SELECT CAST(1 AS SIGNED) AS a, CAST(18446744073709551615 AS UNSIGNED) AS b, 1.5e0 AS c,
           CAST(12.30 AS DECIMAL(6,2)) AS d, 'héllo' AS e, CAST('2026-11-20' AS DATE) AS f,
           CAST('2026-11-20 10:00:00' AS DATETIME) AS g, JSON_OBJECT('k', JSON_ARRAY(1, 2)) AS h,
           X'00FF' AS i, NULL AS j, CAST('10:30:00' AS TIME) AS k
  ]]
  )
  eq(types(rs), {
    "integer",
    "integer",
    "number",
    "decimal",
    "string",
    "date",
    "datetime",
    "json",
    "bytes",
    "null",
    "time",
  })
  local r = rs.rows[1]
  eq({ r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[9], r[10], r[11] }, {
    1,
    "18446744073709551615",
    1.5,
    "12.30",
    "héllo",
    "2026-11-20",
    "2026-11-20 10:00:00",
    "\0\255",
    vim.NIL,
    "10:30:00",
  })
  eq(r[8].k, { 1, 2 })
  eq(rs.columns[2].db_type, "BIGINT UNSIGNED")
end

T["it: multiple statements and max_rows"] = function()
  h.require_it()
  local rs = h.ok(
    URL,
    [[
    DROP TABLE IF EXISTS t_it;
    CREATE TABLE t_it (n INT);
    INSERT INTO t_it VALUES (1),(2),(3),(4),(5);
    SELECT n FROM t_it ORDER BY n;
    UPDATE t_it SET n = n;
  ]],
    { max_rows = 3 }
  )
  eq({ rs.row_count, rs.truncated, rs.rows[3][1] }, { 3, true, 3 })
  eq(h.ok(URL, "SELECT 'x'").rows[1][1], "x")
end

T["it: errors"] = function()
  h.require_it()
  local r = h.query(URL, "SELECT * FROM nope")
  eq({ r.err.phase, r.err.code, r.err.driver }, { "query", "1146 42S02", "mysql" })
  r = h.query("mysql://dbdash:wrong@127.0.0.1:13306/dbdash_test", "SELECT 1")
  eq({ r.err.phase, r.err.code }, { "auth", "1045 28000" })
  r = h.query(URL, "SELECT 1; SELEC 2; SELECT 3")
  eq(r.err.code, "1064 42000")
  r = h.query(URL .. "?timeout=300ms", "SELECT SLEEP(2)")
  eq(r.err.phase, "timeout")
end

return T
