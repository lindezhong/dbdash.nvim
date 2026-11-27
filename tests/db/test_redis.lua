local redis = require("dbdash.db.drivers.redis")
local h = require("tests.helpers")
local map = require("dbdash.util.map")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function parse(bytes)
  return redis.read_reply(h.fake_socket(bytes))
end

T["RESP2 and RESP3 replies"] = function()
  eq(parse("+OK\r\n"), "OK")
  eq(parse(":42\r\n"), 42)
  eq(parse(":9007199254740993\r\n"), "9007199254740993")
  eq(parse("$5\r\nhe\r\nl\r\n"), "he\r\nl")
  eq(parse("$-1\r\n"), vim.NIL)
  eq(parse("*3\r\n:1\r\n$1\r\na\r\n*-1\r\n"), { 1, "a", vim.NIL })
  eq(parse("_\r\n"), vim.NIL)
  eq(parse(",3.5\r\n"), 3.5)
  eq(parse("#t\r\n"), true)
  eq(parse("=8\r\ntxt:abcd\r\n"), "abcd")
  eq(parse("(123456789012345678901\r\n"), "123456789012345678901")
  local m = parse("%2\r\n+b\r\n:1\r\n+a\r\n:2\r\n")
  eq(map.keys(m), { "b", "a" })
  eq(parse("~2\r\n+x\r\n+y\r\n"), { "x", "y" })
  eq(parse("|1\r\n+meta\r\n+v\r\n:7\r\n"), 7)
  eq(parse("-ERR bad\r\n").redis_error, "ERR bad")
end

T["encode"] = function()
  eq(redis.encode({ "SET", "k", "a b" }), "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\na b\r\n")
end

T["tokenize like redis-cli"] = function()
  eq(redis.tokenize([[HGETALL "user:1001"]]), { "HGETALL", "user:1001" })
  eq(redis.tokenize([[SET k "a\nb\x41" 'it\'s' x\ y]]), { "SET", "k", "a\nbA", "it's", "x y" })
  eq(redis.tokenize("  GET   k  "), { "GET", "k" })
  eq(redis.tokenize('SET k ""'), { "SET", "k", "" })
  eq(pcall(redis.tokenize, 'GET "open'), false)
end

T["mappers"] = function()
  local rs = redis.mappers.HGETALL({ "f1", "v1", "f2", "v2" }, { "HGETALL", "h" }, 100)
  eq({ rs:column_names(), rs.rows }, { { "field", "value" }, { { "f1", "v1" }, { "f2", "v2" } } })
  rs = redis.mappers.ZRANGE(
    { "a", "1.5", "b", "2" },
    { "ZRANGE", "z", "0", "-1", "WITHSCORES" },
    100
  )
  eq({ rs.rows, rs.columns[2].type }, { { { "a", 1.5 }, { "b", 2 } }, "number" })
  rs = redis.mappers.INFO(
    "# Server\r\nredis_version:7.4.1\r\nuptime_in_seconds:12\r\n# Clients\r\nconnected_clients:1\r\n",
    { "INFO" },
    100
  )
  eq(rs.rows[1], { "server", "redis_version", "7.4.1" })
  eq(rs.rows[3], { "clients", "connected_clients", 1 })
  rs = redis.mappers.XRANGE(
    { { "1-0", { "temp", "20", "hum", "40" } }, { "2-0", { "temp", "21", "wind", "3" } } },
    { "XRANGE", "s", "-", "+" },
    100
  )
  eq(rs:column_names(), { "id", "temp", "hum", "wind" })
  eq(rs.rows[2], { "2-0", "21", vim.NIL, "3" })
  rs = redis.mappers.LRANGE({ "a", "b", "c" }, { "LRANGE", "l", "0", "-1" }, 2)
  eq({ rs.rows, rs.truncated }, { { { 0, "a" }, { 1, "b" } }, true })
end

-- Integration (make it) ---------------------------------------------------------------------

local URL = "redis://:dbdash_pw@127.0.0.1:16379/0"

T["it: commands map to tables"] = function()
  h.require_it()
  h.ok(URL, "DEL user:1 visits list set z stream")
  h.ok(URL, 'HSET user:1 name "Ann Lee" age 30')
  h.ok(URL, "SET visits 42")
  h.ok(URL, "RPUSH list a b c")
  h.ok(URL, "SADD set x")
  h.ok(URL, "ZADD z 1.5 a 2 b")
  h.ok(URL, "XADD stream 1-0 temp 20")
  local rs = h.ok(URL, "HGETALL user:1")
  eq(rs.rows, { { "name", "Ann Lee" }, { "age", "30" } })
  eq(h.ok(URL, "GET visits").rows, { { "visits", "42" } })
  eq(h.ok(URL, "MGET visits nope").rows, { { "visits", "42" }, { "nope", vim.NIL } })
  eq(h.ok(URL, "LRANGE list 1 -1").rows, { { 1, "b" }, { 2, "c" } })
  eq(h.ok(URL, "ZRANGE z 0 -1 WITHSCORES").rows, { { "a", 1.5 }, { "b", 2 } })
  eq(h.ok(URL, "SMEMBERS set").rows, { { "x" } })
  eq(h.ok(URL, "XRANGE stream - +").rows, { { "1-0", "20" } })
  eq(h.ok(URL, "INCR visits").rows, { { 43 } })
  local info = h.ok(URL, "INFO server")
  eq(info:column_names(), { "section", "key", "value" })
end

T["it: SCAN iterates to the end and respects max_rows"] = function()
  h.require_it()
  local args = {}
  for i = 1, 250 do
    args[#args + 1] = "scan:" .. i
    args[#args + 1] = "v"
  end
  h.ok(URL, "MSET " .. table.concat(args, " "))
  local rs = h.ok(URL, "SCAN 0 MATCH scan:* COUNT 50")
  eq(rs.row_count, 250)
  rs = h.ok(URL, "SCAN 0 MATCH scan:* COUNT 50", { max_rows = 30 })
  eq({ rs.row_count, rs.truncated }, { 30, true })
end

T["it: errors"] = function()
  h.require_it()
  local r = h.query("redis://:wrong@127.0.0.1:16379", "PING")
  eq({ r.err.phase, r.err.code }, { "auth", "WRONGPASS" })
  r = h.query(URL, "HGETALL visits")
  eq({ r.err.phase, r.err.code }, { "query", "WRONGTYPE" })
  r = h.query(URL, "NOSUCHCOMMAND x")
  eq(r.err.phase, "query")
  r = h.query("redis://127.0.0.1:1", "PING")
  eq(r.err.phase, "connect")
end

return T
