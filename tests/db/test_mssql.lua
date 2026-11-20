local ms = require("dbdash.db.drivers.mssql")
local u = require("dbdash.crypto.util")
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["UTF-16 round trip"] = function()
  for _, s in ipairs({ "abc", "héllo", "中文", "😀x" }) do
    eq(ms.utf8(ms.utf16(s)), s)
  end
  eq(u.hex(ms.utf16("A😀")), "41003dd800de")
end

T["password obfuscation (MS-TDS example)"] = function()
  -- Each byte: swap nibbles, XOR 0xA5. 'a' (0x61) -> 0x16 ^ 0xA5 = 0xB3; 0x00 -> 0xA5.
  eq(u.hex(ms.obfuscate(ms.utf16("a"))), "b3a5")
end

T["prelogin round trip"] = function()
  local p = ms.prelogin()
  eq(ms.parse_prelogin(p), 2)
end

-- Integration (make it) ---------------------------------------------------------------------

local URL = "mssql://sa:Dbdash_pw1@127.0.0.1:11433/master"

T["it: types"] = function()
  h.require_it()
  local rs = h.ok(URL, [[
    SELECT CAST(1 AS tinyint) AS a, CAST(-2 AS smallint) AS b, CAST(3 AS int) AS c,
           CAST(9223372036854775807 AS bigint) AS d, CAST(1.5 AS float) AS e, CAST(0.25 AS real) AS f,
           CAST(12.34 AS decimal(10,2)) AS g, CAST(-0.5 AS numeric(5,3)) AS h, CAST(1 AS bit) AS i,
           N'héllo 中文' AS j, 'plain' AS k, CAST('2026-11-20' AS date) AS l,
           CAST('2026-11-20 10:00:00.123' AS datetime2(3)) AS m,
           CAST('2026-11-20 10:00:00' AS datetime) AS n, CAST('10:30:15.5' AS time(1)) AS o,
           CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS p,
           CAST(12.3456 AS money) AS q, 0x00FF AS r, NULL AS s, CAST(N'x' AS nvarchar(max)) AS t,
           CAST('2026-11-20 10:00:00 +08:00' AS datetimeoffset(0)) AS v
  ]])
  local r = rs.rows[1]
  eq({ r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9] }, { 1, -2, 3, "9223372036854775807", 1.5, 0.25, "12.34", "-0.500", true })
  eq({ r[10], r[11], r[12], r[13], r[14], r[15], r[16], r[17], r[18], r[19], r[20], r[21] }, {
    "héllo 中文", "plain", "2026-11-20", "2026-11-20 10:00:00.123", "2026-11-20 10:00:00.000",
    "10:30:15.5", "6F9619FF-8B86-D011-B42D-00C04FC964FF", "12.3456", "\0\255", vim.NIL, "x",
    "2026-11-20 10:00:00 +08:00",
  })
  local types = {}
  for i, c in ipairs(rs.columns) do
    types[i] = c.type
  end
  eq(types, { "integer", "integer", "integer", "integer", "number", "number", "decimal", "decimal", "boolean", "string", "string", "date", "datetime", "datetime", "time", "uuid", "decimal", "bytes", "integer", "string", "datetime" })
end

T["it: batches, rows, max_rows, errors"] = function()
  h.require_it()
  local rs = h.ok(URL, [[
    SET NOCOUNT ON;
    DECLARE @t TABLE (n int);
    DECLARE @i int = 0;
    WHILE @i < 3000 BEGIN INSERT INTO @t VALUES (@i); SET @i = @i + 1; END;
    SELECT n, CASE WHEN n % 2 = 0 THEN NULL ELSE n END AS odd FROM @t ORDER BY n;
  ]], { max_rows = 2500 })
  eq({ rs.row_count, rs.truncated, rs.rows[2][2], rs.rows[1][2] }, { 2500, true, 1, vim.NIL })
  local r = h.query(URL, "SELECT * FROM nope")
  eq({ r.err.phase, r.err.code }, { "query", "208" })
  r = h.query("mssql://sa:wrong@127.0.0.1:11433/master", "SELECT 1")
  eq({ r.err.phase, r.err.code }, { "auth", "18456" })
  r = h.query(URL .. "?tls=require", "SELECT 1")
  eq(r.err.message:find("TLS 1.2") ~= nil, true)
end

return T
