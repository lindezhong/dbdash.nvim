-- verify-full building blocks against the test PKI (tests/fixtures/pki/gen.py).
local asn1 = require("dbdash.net.tls.asn1")
local x509 = require("dbdash.net.tls.x509")
local verify = require("dbdash.net.tls.verify")
local truststore = require("dbdash.net.tls.truststore")
local u = require("dbdash.crypto.util")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local DIR = "tests/fixtures/pki/"

local function read(name)
  local f = assert(io.open(DIR .. name, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function cert(name)
  return x509.parse(asn1.pem(read(name), "CERTIFICATE"))
end

local ROOT = truststore.from_file(DIR .. "root.pem")
local NOW = os.time({ year = 2027, month = 6, day = 1, hour = 0 })

T["signature vectors: PKCS#1 v1.5 and P-384"] = function()
  local v = vim.json.decode(read("vectors.json"))
  local root = cert("root.pem")
  local rsa = require("dbdash.crypto.rsa")
  eq(
    rsa.pkcs1_verify(root.rsa, require("dbdash.crypto.sha256"), v.msg, u.unhex(v.pkcs1_sha256)),
    true
  )
  eq(
    rsa.pkcs1_verify(
      root.rsa,
      require("dbdash.crypto.sha512").sha384,
      v.msg,
      u.unhex(v.pkcs1_sha384)
    ),
    true
  )
  eq(
    rsa.pkcs1_verify(root.rsa, require("dbdash.crypto.sha512"), v.msg, u.unhex(v.pkcs1_sha512)),
    true
  )
  eq(
    rsa.pkcs1_verify(
      root.rsa,
      require("dbdash.crypto.sha256"),
      v.msg .. "!",
      u.unhex(v.pkcs1_sha256)
    ),
    false
  )
  local inter = cert("inter.pem")
  eq(inter.ec.curve, "P-384")
  local p384 = require("dbdash.crypto.ecdsa").curves.p384
  local h = require("dbdash.crypto.sha512").sha384
  eq(p384:verify(inter.ec, h.digest(v.msg), u.unhex(v.ecdsa_p384_sha384)), true)
  eq(p384:verify(inter.ec, h.digest(v.msg .. "!"), u.unhex(v.ecdsa_p384_sha384)), false)
end

T["x509 fields"] = function()
  local leaf, inter, root = cert("leaf.pem"), cert("inter.pem"), cert("root.pem")
  eq(
    { leaf.subject, leaf.ca, leaf.sig_alg.kind, leaf.sig_alg.hash },
    { "dbdash leaf", false, "ecdsa", "sha384" }
  )
  eq(leaf.san.dns, { "localhost" })
  eq(leaf.san.ip, { "\127\0\0\1" })
  eq(leaf.ext_key_usage[x509.OID.server_auth], true)
  eq(leaf.issuer_der, inter.subject_der)
  eq({ inter.ca, inter.key_usage.key_cert_sign }, { true, true })
  eq(root.issuer_der, root.subject_der)
  eq(leaf.not_before, 1767225600) -- 2026-01-01T00:00:00Z, whatever the local time zone
  eq(
    cert("leaf_pss.pem").sig_alg,
    { kind = "rsa_pss", hash = "sha256", oid = "1.2.840.113549.1.1.10" }
  )
  eq(cert("leaf_critical.pem").unknown_critical, { "1.3.6.1.4.1.99999.1" })
end

T["chain: valid paths"] = function()
  eq(verify.chain(cert("leaf.pem"), { cert("inter.pem") }, ROOT, NOW), true)
  eq(verify.chain(cert("leaf_pss.pem"), {}, ROOT, NOW), true)
  -- trusting the leaf itself (self-signed style)
  local own = truststore.from_ders({ cert("leaf.pem").der }, "test")
  eq(verify.chain(cert("leaf.pem"), {}, own, NOW), true)
end

T["chain: failures explain themselves"] = function()
  local function why(leaf, inters, store, now)
    local ok, reason = verify.chain(cert(leaf), inters, store or ROOT, now or NOW)
    eq(ok, false)
    return reason
  end
  eq(why("leaf.pem", {}):find('unable to find a trusted issuer for "dbdash leaf"') ~= nil, true)
  eq(
    why("leaf.pem", { cert("inter.pem") }, truststore.from_file(DIR .. "other_root.pem")):find(
      "unable to find a trusted issuer"
    ) ~= nil,
    true
  )
  eq(
    why("leaf_expired.pem", { cert("inter.pem") }):find("has expired %(on 2020%-01%-01%)") ~= nil,
    true
  )
  eq(
    why("leaf.pem", { cert("inter.pem") }, ROOT, os.time({ year = 2025, month = 1, day = 1 })):find(
      "not valid yet"
    ) ~= nil,
    true
  )
  eq(
    why("leaf_critical.pem", { cert("inter.pem") }):find(
      "unsupported critical extension%(s%): 1%.3%.6%.1%.4%.1%.99999%.1"
    ) ~= nil,
    true
  )
  -- a leaf presented as an intermediate is not a CA
  eq(why("leaf.pem", { cert("leaf_cn.pem") }):find("unable to find") ~= nil, true)
  -- tampered signature
  local bad = cert("leaf.pem")
  bad.signature = bad.signature:sub(1, -2) .. string.char((bad.signature:byte(-1) + 1) % 256)
  local ok, reason = verify.chain(bad, { cert("inter.pem") }, ROOT, NOW)
  eq({ ok, reason:find("bad signature") ~= nil }, { false, true })
end

T["host names"] = function()
  local leaf = cert("leaf.pem")
  eq(verify.host(leaf, "localhost"), true)
  eq(verify.host(leaf, "LOCALHOST."), true)
  eq(verify.host(leaf, "127.0.0.1"), true)
  local ok, why = verify.host(leaf, "db.example.com")
  eq(
    { ok, why },
    { false, "host name mismatch: the certificate is for localhost, 127.0.0.1, not db.example.com" }
  )
  eq(verify.host(cert("leaf_cn.pem"), "localhost"), true) -- no SAN: common name fallback
  eq(verify.host(cert("leaf_wronghost.pem"), "localhost"), false)
  eq(verify.dns_match("*.example.com", "db.example.com"), true)
  eq(verify.dns_match("*.example.com", "a.b.example.com"), false)
  eq(verify.dns_match("*.example.com", "example.com"), false)
  eq(verify.dns_match("*.com", "example.com"), false)
  eq(verify.ip_bytes("::1"), string.rep("\0", 15) .. "\1")
end

T["intermediates of the system store complete chains but are not trust anchors"] = function()
  local leaf, inter, root = cert("leaf.pem"), cert("inter.pem"), cert("root.pem")
  -- root as anchor, the intermediate only known to the store (Windows "CA" store)
  local store = truststore.from_ders({ root.der }, "test")
  store.intermediates = { inter }
  eq(verify.chain(leaf, {}, store), true)
  -- an intermediate alone does not make a chain trusted
  local only_inter = truststore.from_ders({}, "test")
  only_inter.intermediates = { inter }
  local ok, why = verify.chain(leaf, {}, only_inter)
  eq(ok, false)
  eq(type(why), "string")
end

T["system trust store loads"] = function()
  local ok, store = pcall(truststore.system)
  if not ok then
    MiniTest.skip("no system CA bundle")
  end
  local t0 = vim.uv.hrtime()
  truststore.system()
  MiniTest.add_note(
    ("system store: %d certificates from %s (cached reload %.1f ms)"):format(
      #store.certs,
      store.source,
      (vim.uv.hrtime() - t0) / 1e6
    )
  )
  -- Windows downloads most roots on demand, so its local store can be small.
  eq(#store.certs > 0, true)
end

return T
