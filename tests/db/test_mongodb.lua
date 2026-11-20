local bson = require("dbdash.db.bson")
local json = require("dbdash.db.json")
local mongo = require("dbdash.db.drivers.mongodb")
local map = require("dbdash.util.map")
local u = require("dbdash.crypto.util")
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["ordered JSON parse"] = function()
  local v = json.parse('{"b": 1, "a": [1.5, "x\\u00e9", null, true], "c": {"$oid": "x"}, "big": 9007199254740993}')
  eq(map.keys(v), { "b", "a", "c", "big" })
  eq(json.is_double(v.a[1]), true)
  eq(v.a[2], "xé")
  eq(v.a[3], vim.NIL)
  eq(json.is_int64(v.big), true)
  eq(pcall(json.parse, '{"a": }'), false)
end

T["BSON encoding matches a reference"] = function()
  local d = json.parse('{"find": "orders", "filter": {"status": "paid", "amt": 1.5}, "a": [1, true, null], "big": 9007199254740993}')
  eq(u.hex(bson.encode(d)), "640000000266696e6400070000006f7264657273000366696c7465720023000000027374617475730005000000706169640001616d7400000000000000f83f000461001300000010300001000000083100010a3200001262696700010000000000200000")
end

T["BSON round trip and extended JSON"] = function()
  local d = json.parse('{"id": {"$oid": "5f1d7a3b9c1e4a2b3c4d5e6f"}, "at": {"$date": "2026-11-20T10:00:00.250Z"}, "n": {"$numberLong": "42"}, "re": {"$regex": "^a", "$options": "i"}}')
  local back = bson.decode(bson.encode(d))
  eq(back.id.kind, "oid")
  eq(back.id.value, "5f1d7a3b9c1e4a2b3c4d5e6f")
  eq(back.at.value, "2026-11-20T10:00:00.250Z")
  eq(back.n, 42)
  eq(back.re.value, "/^a/i")
end

T["dates"] = function()
  eq(bson.ms_to_iso(0), "1970-01-01T00:00:00.000Z")
  eq(bson.ms_to_iso(951782400000), "2000-02-29T00:00:00.000Z")
  eq(bson.iso_to_ms("2000-02-29T08:00:00+08:00"), 951782400000)
  eq(bson.ms_to_iso(-86400000), "1969-12-31T00:00:00.000Z")
end

T["decimal128"] = function()
  eq(bson.decimal128(u.unhex("0f00000000000000" .. "0000000000003e30")), "1.5")
  eq(bson.decimal128(u.unhex("0100000000000000" .. "000000000000 3cb0")), "-0.01")
  eq(bson.decimal128(u.unhex("0000000000000000" .. "0000000000004030")), "0")
  eq(bson.decimal128(u.unhex("0000000000000000" .. "000000000000007c")), "NaN")
end

T["documents to a result set, with flattening"] = function()
  local docs = {
    json.parse('{"_id": 1, "customer": {"name": "Ann", "tier": {"level": 2}}, "amount": 9.5}'),
    json.parse('{"_id": 2, "amount": 3, "extra": "x"}'),
  }
  local rs = mongo.to_resultset(docs, 0, 100, false)
  eq(rs:column_names(), { "_id", "customer", "amount", "extra" })
  eq(rs.columns[2].type, "json")
  eq(rs.rows[2][2], vim.NIL)
  rs = mongo.to_resultset(docs, 1, 100, false)
  eq(rs:column_names(), { "_id", "customer.name", "customer.tier", "amount", "extra" })
  rs = mongo.to_resultset(docs, 2, 100, false)
  eq(rs:column_names(), { "_id", "customer.name", "customer.tier.level", "amount", "extra" })
end

-- Integration (make it) ---------------------------------------------------------------------

local URL = "mongodb://dbdash:dbdash_pw@127.0.0.1:17017/dbdash_test?authSource=admin"

local function q(t)
  return vim.json.encode(t)
end

T["it: aggregate, find, count, distinct"] = function()
  h.require_it()
  -- Seed with an aggregate $merge-free approach: $documents + $out.
  h.ok(URL, [[{"operation": "aggregate", "database": "dbdash_test", "pipeline": [
    {"$documents": [
      {"_id": 1, "region": "Asia", "amount": 10, "customer": {"name": "Ann"}},
      {"_id": 2, "region": "EU", "amount": 25.5, "customer": {"name": "Bob"}},
      {"_id": 3, "region": "Asia", "amount": 7, "customer": {"name": "Cy"}}
    ]},
    {"$out": "orders"}]}]])
  local rs = h.ok(URL, [[{"collection": "orders", "filter": {"region": "Asia"}, "sort": {"amount": -1}, "flatten": 1}]])
  eq(rs:column_names(), { "_id", "region", "amount", "customer.name" })
  eq(rs.rows, { { 1, "Asia", 10, "Ann" }, { 3, "Asia", 7, "Cy" } })
  eq(h.ok(URL, [[{"collection": "orders", "operation": "count", "filter": {"amount": {"$gt": 8}}}]]).rows, { { 2 } })
  local d = h.ok(URL, [[{"collection": "orders", "operation": "distinct", "field": "region"}]])
  eq({ d:column_names(), #d.rows }, { { "region" }, 2 })
  local agg = h.ok(URL, [[{"collection": "orders", "operation": "aggregate", "pipeline": [
    {"$group": {"_id": "$region", "total": {"$sum": "$amount"}}}, {"$sort": {"_id": 1}},
    {"$addFields": {"at": {"$toDate": {"$numberLong": "0"}}, "dec": {"$toDecimal": "123.45"}, "oid": {"$toObjectId": "5f1d7a3b9c1e4a2b3c4d5e6f"}}}]}]])
  eq(agg.rows[1][1], "Asia")
  eq(agg.rows[1][2], 17)
  eq(agg.rows[1][3], "1970-01-01T00:00:00.000Z")
  eq(agg.rows[1][4], "123.45")
  eq(agg.rows[1][5], "5f1d7a3b9c1e4a2b3c4d5e6f")
  eq({ agg.columns[3].type, agg.columns[4].type }, { "datetime", "decimal" })
end

T["it: cursors follow getMore and stop at max_rows"] = function()
  h.require_it()
  local docs = {}
  for i = 1, 250 do
    docs[i] = { _id = i }
  end
  h.ok(URL, q({ operation = "aggregate", pipeline = { { ["$documents"] = docs }, { ["$out"] = "many" } } }))
  local rs = h.ok(URL, [[{"collection": "many", "sort": {"_id": 1}}]])
  eq(rs.row_count, 250)
  rs = h.ok(URL, [[{"collection": "many", "sort": {"_id": 1}}]], { max_rows = 120 })
  eq({ rs.row_count, rs.truncated, rs.rows[120][1] }, { 120, true, 120 })
end

T["it: errors"] = function()
  h.require_it()
  local r = h.query("mongodb://dbdash:wrong@127.0.0.1:17017/x?authSource=admin", [[{"collection": "a"}]])
  eq({ r.err.phase, r.err.code }, { "auth", "AuthenticationFailed" })
  r = h.query(URL, [[{"collection": "orders", "filter": {"$bad": 1}}]])
  eq(r.err.phase, "query")
  r = h.query(URL, [[{"operation": "find"}]])
  eq(r.err.message:find('"collection"') ~= nil, true)
  r = h.query(URL, "not json")
  eq(r.err.message:find("invalid JSON") ~= nil, true)
end

return T
