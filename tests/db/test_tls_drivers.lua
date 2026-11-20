-- Drivers over TLS 1.3 against the compose databases (make it).
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function fingerprint(cert)
  local out = vim.system({ "openssl", "x509", "-in", "tests/fixtures/" .. cert, "-noout", "-fingerprint", "-sha256" }, { text = true }):wait()
  return "sha256:" .. out.stdout:match("=(%S+)")
end

local WRONG = "sha256:" .. string.rep("00:", 31) .. "00"

T["it: postgres with tls=require and tls=pin"] = function()
  h.require_it()
  local base = "postgres://dbdash:dbdash_pw@127.0.0.1:15432/dbdash_test"
  eq(h.ok(base .. "?tls=require", "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()").rows[1][1], true)
  eq(h.ok(base .. "?tls=require", "SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()").rows[1][1], "TLSv1.3")
  eq(h.ok(base .. "?tls=pin&fingerprint=" .. fingerprint("ec_cert.pem"), "SELECT 1").rows[1][1], 1)
  local r = h.query(base .. "?tls=pin&fingerprint=" .. WRONG, "SELECT 1")
  eq(r.err.phase, "tls")
  eq(r.err.message:find(fingerprint("ec_cert.pem"), 1, true) ~= nil, true)
  -- md5 user over TLS
  eq(h.ok("postgres://md5_user:md5_pw@127.0.0.1:15432/dbdash_test?tls=require", "SELECT current_user").rows[1][1], "md5_user")
end

T["it: mysql with TLS (auto-generated RSA certificate)"] = function()
  h.require_it()
  local base = "mysql://dbdash:dbdash_pw@127.0.0.1:13306/dbdash_test"
  local rs = h.ok(base .. "?tls=require", "SHOW SESSION STATUS LIKE 'Ssl_version'")
  eq(rs.rows[1][2], "TLSv1.3")
  -- Learn the server's fingerprint from a pin mismatch, then pin it.
  local r = h.query(base .. "?tls=pin&fingerprint=" .. WRONG, "SELECT 1")
  eq(r.err.phase, "tls")
  local fp = r.err.message:match("presented (sha256:[%x:]+)")
  eq(fp ~= nil, true)
  eq(h.ok(base .. "?tls=pin&fingerprint=" .. fp, "SELECT 1").rows[1][1], 1)
  -- caching_sha2 full authentication over TLS sends the password in clear (inside TLS).
  h.ok("mysql://root:root_pw@127.0.0.1:13306/", "FLUSH PRIVILEGES")
  eq(h.ok(base .. "?tls=require", "SELECT CURRENT_USER()").rows[1][1], "dbdash@%")
  eq(h.ok("mysql://native_user:native_pw@127.0.0.1:13306/dbdash_test?tls=require", "SELECT 1").rows[1][1], 1)
end

T["it: redis over TLS"] = function()
  h.require_it()
  local url = "redis://:dbdash_pw@127.0.0.1:16380/0?tls=pin&fingerprint=" .. fingerprint("ec_cert.pem")
  h.ok(url, "SET tls_key hello")
  eq(h.ok(url, "GET tls_key").rows, { { "tls_key", "hello" } })
  eq(h.ok("rediss://:dbdash_pw@127.0.0.1:16380/0", "PING").rows[1][1], "PONG")
  local r = h.query("redis://:dbdash_pw@127.0.0.1:16379/0?tls=require&timeout=1s", "PING")
  eq(r.err ~= nil, true) -- plain-text port: no TLS server
end

return T
