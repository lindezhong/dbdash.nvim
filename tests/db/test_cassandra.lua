local cql = require("dbdash.db.drivers.cassandra")
local u = require("dbdash.crypto.util")
local h = require("tests.helpers")
local map = require("dbdash.util.map")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["varint"] = function()
  eq(cql.varint("\0"), "0")
  eq(cql.varint("\127"), "127")
  eq(cql.varint("\255"), "-1")
  eq(cql.varint("\128"), "-128")
  eq(cql.varint(u.unhex("00ffffffffffffffffff")), "4722366482869645213695")
end

T["scalar values"] = function()
  local function d(id, hex)
    return cql.decode({ id = id }, u.unhex(hex))
  end
  eq(d(0x02, "7fffffffffffffff"), "9223372036854775807")
  eq(d(0x09, "ffffffff"), -1)
  eq(d(0x07, "3ff8000000000000"), 1.5)
  eq(d(0x06, "00000002" .. "04d2"), "12.34")
  eq(d(0x06, "00000003" .. "fb2e"), "-1.234")
  eq(d(0x0B, "0000000000000000"), "1970-01-01T00:00:00.000Z")
  eq(d(0x11, "80000000"), "1970-01-01")
  eq(d(0x12, "0000034630b8a000"), "01:00:00.000000000")
  eq(d(0x0C, "123e4567e89b12d3a456426614174000"), "123e4567-e89b-12d3-a456-426614174000")
  eq(d(0x10, "7f000001"), "127.0.0.1")
end

T["collections"] = function()
  local list = cql.decode({ id = 0x20, sub = { { id = 0x09 } } }, u.unhex("00000002" .. "00000004" .. "00000001" .. "ffffffff"))
  eq(list, { 1, vim.NIL })
  local m = cql.decode({ id = 0x21, sub = { { id = 0x0D }, { id = 0x09 } } }, u.unhex("00000001" .. "00000001" .. "61" .. "00000004" .. "00000007"))
  eq({ map.keys(m), m.a }, { { "a" }, 7 })
  eq(cql.type_name({ id = 0x21, sub = { { id = 0x0D }, { id = 0x20, sub = { { id = 0x09 } } } } }), "map<varchar, list<int>>")
end

-- Integration (make it) ---------------------------------------------------------------------

local BASE = "cassandra://cassandra:cassandra@127.0.0.1:19042"

T["it: types, paging and errors"] = function()
  h.require_it()
  h.ok(BASE, "CREATE KEYSPACE IF NOT EXISTS dbdash_it WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}")
  local URL = BASE .. "/dbdash_it"
  h.ok(URL, [[CREATE TABLE IF NOT EXISTS t (id int PRIMARY KEY, name text, big bigint, ratio double,
    price decimal, ok boolean, at timestamp, day date, tags list<text>, attrs map<text, int>,
    u uuid, addr inet, vi varint)]])
  h.ok(URL, [[INSERT INTO t (id, name, big, ratio, price, ok, at, day, tags, attrs, u, addr, vi)
    VALUES (1, 'héllo', 9223372036854775807, 0.25, 12.34, true, '2026-11-20 10:00:00+0000',
    '2026-11-20', ['a', 'b'], {'x': 1}, 123e4567-e89b-12d3-a456-426614174000, '10.0.0.1', 123456789012345678901234)]])
  local rs = h.ok(URL, "SELECT id, name, big, ratio, price, ok, at, day, tags, attrs, u, addr, vi FROM t WHERE id = 1")
  local types = {}
  for i, c in ipairs(rs.columns) do
    types[i] = c.type
  end
  eq(types, { "integer", "string", "integer", "number", "decimal", "boolean", "datetime", "date", "array", "json", "uuid", "string", "integer" })
  eq(rs.rows[1], { 1, "héllo", "9223372036854775807", 0.25, "12.34", true, "2026-11-20T10:00:00.000Z", "2026-11-20", { "a", "b" }, rs.rows[1][10], "123e4567-e89b-12d3-a456-426614174000", "10.0.0.1", "123456789012345678901234" })
  eq(rs.rows[1][10].x, 1)
  eq(rs.columns[10].db_type, "map<varchar, int>")

  -- Paging: more rows than one page.
  h.ok(URL, "CREATE TABLE IF NOT EXISTS p (k int, c int, PRIMARY KEY (k, c))")
  for i = 0, 11 do
    local vals = {}
    for c = i * 100, i * 100 + 99 do
      vals[#vals + 1] = ("INSERT INTO p (k, c) VALUES (1, %d)"):format(c)
    end
    h.ok(URL, "BEGIN UNLOGGED BATCH " .. table.concat(vals, "; ") .. "; APPLY BATCH")
  end
  rs = h.ok(URL, "SELECT c FROM p WHERE k = 1")
  eq(rs.row_count, 1200)
  rs = h.ok(URL, "SELECT c FROM p WHERE k = 1", { max_rows = 10 })
  eq({ rs.row_count, rs.truncated }, { 10, true })

  local r = h.query(URL, "SELECT * FROM nope")
  eq({ r.err.phase, r.err.code }, { "query", "0x2200" })
  r = h.query("cassandra://cassandra:wrong@127.0.0.1:19042", "SELECT now() FROM system.local")
  eq(r.err.phase, "auth")
end

return T
