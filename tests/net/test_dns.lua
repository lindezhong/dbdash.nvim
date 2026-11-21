local dns = require("dbdash.net.dns")
local async = require("dbdash.util.async")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local h = require("tests.helpers")
local respond, fake_dns = h.dns_respond, h.fake_dns

local function run(fn)
  local res
  async.run(fn, function(err, ...)
    res = { err = err, ... }
  end)
  vim.wait(5000, function()
    return res ~= nil
  end, 5)
  return res
end

T["query encoding and response parsing"] = function()
  local q = dns.build_query(0x1234, "_mongodb._tcp.example.com", 33)
  eq(q:sub(1, 4), "\18\52\1\0")
  eq(q:find("\8_mongodb\4_tcp\7example\3com\0\0\33\0\1", 1, true) ~= nil, true)
  local r = dns.parse_response(respond(q, {
    { type = 33, priority = 1, weight = 5, port = 27017, target = "db1.example.com" },
    { type = 16, parts = { "authSource=admin" } },
  }))
  eq(#r.answers, 1)
  eq(r.answers[1].srv, { priority = 1, weight = 5, port = 27017, target = "db1.example.com" })
end

T["queries over UDP against a local server"] = function()
  local udp, port = fake_dns({
    { type = 33, priority = 2, weight = 0, port = 2, target = "b.example.com" },
    { type = 33, priority = 1, weight = 0, port = 1, target = "a.example.com" },
    { type = 16, parts = { "authSource=", "admin&replicaSet=rs0" } },
  })
  local r = run(function()
    return dns.srv("_mongodb._tcp.example.com", { server = "127.0.0.1:" .. port }), dns.txt("example.com", { server = "127.0.0.1:" .. port })
  end)
  udp:close()
  eq(r.err, nil)
  eq(vim.tbl_map(function(x)
    return x.target
  end, r[1]), { "a.example.com", "b.example.com" })
  eq(r[2], { "authSource=admin&replicaSet=rs0" })
end

T["timeouts and resolv.conf"] = function()
  local r = run(function()
    dns.query("example.com", 33, { server = "127.0.0.1:9", timeout = 200 })
  end)
  eq(r.err.message:find("DNS: lookup of example.com failed") ~= nil, true)
  eq(dns.parse_server("[::1]:5353"), { host = "::1", port = 5353 })
  eq(dns.parse_server("10.0.0.1"), { host = "10.0.0.1", port = 53 })
  eq(type(dns.nameservers()), "table")
end

return T
