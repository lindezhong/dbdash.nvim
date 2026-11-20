-- Signature verification against signatures made by Python's cryptography package
-- (tests/fixtures: ec.key / ec_cert.pem, rsa2048.pem / rsa_cert.pem).
local u = require("dbdash.crypto.util")
local asn1 = require("dbdash.net.tls.asn1")
local x509 = require("dbdash.net.tls.x509")
local ecdsa = require("dbdash.crypto.ecdsa_p256")
local rsa = require("dbdash.crypto.rsa")
local sha256 = require("dbdash.crypto.sha256")
local sha384 = require("dbdash.crypto.sha512").sha384
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function read(p)
  local f = assert(io.open(p, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local MSG = "dbdash signature test"
local EC_SIG = u.unhex("304402204fc2eaec10de14fc657cf98af82de9c09b21001375ba3f56cec332bc94799c4c0220631bb3af6f463dbcb1de8dd4da6da34db52fadc133772d66242ceb940b587fb8")
local PSS256 = u.unhex("851cb97f0ac5a341efccee0d04d5439ad59c97d5222195dac8db6cfa5bb9d60b2ec7d22d72c4c1a3807eeeb244402807cd44db926900ac55233828f1bcd827d0f2a056170c7a8d692129321f037104398a3b689d6aadc0eb8d0dfe0e360bf1cc93178aecbf48a9e31307591f45d706434e1edf54ac8a6f1790567068ae21d00eb959884a12ddebdc8560d75c360a502e465b7d147243f7ce7a95dfdcc1423d4c0782f156286a3ce2c4d06ce9a1fed2cae7368f7546a81ba7093cf3cf8eacc46a9f610a71bc0aa11415ab228b5028f832e66cb77b49de41c64ca79b11754a5dcd4bf61f73c6d3a2169d6b64a285d5a74e32e5fd0569b40f805281284f57615d00")
local PSS384 = u.unhex("341c56ee94af2a2fdb33b226a54affe15e5161a5cd2b2ae010eca9a0ca2136a1909e14811d43c723217aaba803e8ba8eeb8a5203827a1bdd46be9d34e7e7a04fd0db44539a7de4a2448ccb578f601d886959950093463e1fb9b78081dd7b8597e3130d592f5304b19ce8934c6fa94fbd788d906caaefbc00eb03db2dade9a8f530880cf6df2d32a862b1dbd7db1ddf2fb2cad7f55826a6437a23dc40efcbfa5df19a9093724c60d3b701cc3f567f15b09f88ede5bbd92ab9c7a3e56cf78357a5d0cf20f40a657d53df9ae09311c95e0f79c7ece492d92b90086b2ade826f70f7ec6bad4cf1f3d9f5afacba27fba83df7d0512cd8b701fdce7f8c795443ab5487")

T["sha384"] = function()
  eq(u.hex(sha384.digest("abc")), "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")
end

T["x509 parses EC and RSA certificates"] = function()
  local ec = x509.parse(asn1.pem(read("tests/fixtures/ec_cert.pem"), "CERTIFICATE"))
  eq({ ec.key_type, ec.subject }, { "ec", "dbdash-test-ec" })
  local r = x509.parse(asn1.pem(read("tests/fixtures/rsa_cert.pem"), "CERTIFICATE"))
  eq({ r.key_type, r.subject, r.rsa.size }, { "rsa", "dbdash-test-rsa", 256 })
  eq(x509.fingerprint("x"):match("^sha256:2D:71:16:42"), "sha256:2D:71:16:42")
end

T["ECDSA P-256 verify"] = function()
  local cert = x509.parse(asn1.pem(read("tests/fixtures/ec_cert.pem"), "CERTIFICATE"))
  local t0 = vim.uv.hrtime()
  eq(ecdsa.verify(cert.ec, sha256.digest(MSG), EC_SIG), true)
  MiniTest.add_note(("ECDSA P-256 verify: %.0f ms"):format((vim.uv.hrtime() - t0) / 1e6))
  eq(ecdsa.verify(cert.ec, sha256.digest(MSG .. "!"), EC_SIG), false)
  local bad = EC_SIG:sub(1, -2) .. string.char((EC_SIG:byte(-1) + 1) % 256)
  eq(ecdsa.verify(cert.ec, sha256.digest(MSG), bad), false)
  eq(ecdsa.verify(cert.ec, sha256.digest(MSG), "garbage"), false)
  eq(select(2, ecdsa.public_key("\4" .. string.rep("\1", 64))), "public key is not on the P-256 curve")
end

T["RSA-PSS verify (SHA-256 and SHA-384)"] = function()
  local cert = x509.parse(asn1.pem(read("tests/fixtures/rsa_cert.pem"), "CERTIFICATE"))
  eq(rsa.pss_verify(cert.rsa, sha256, MSG, PSS256), true)
  eq(rsa.pss_verify(cert.rsa, sha384, MSG, PSS384), true)
  eq(rsa.pss_verify(cert.rsa, sha256, MSG .. "!", PSS256), false)
  eq(rsa.pss_verify(cert.rsa, sha384, MSG, PSS256), false)
  eq(rsa.pss_verify(cert.rsa, sha256, MSG, PSS256:sub(2) .. "\0"), false)
end

return T
