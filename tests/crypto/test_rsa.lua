local bn = require("dbdash.crypto.bignum")
local rsa = require("dbdash.crypto.rsa")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["bignum round trips and modexp (checked with Python pow)"] = function()
  local a = bn.from_hex("d3b5e1f00b1c2a99887766554433221100ffeeddccbbaa99")
  eq(bn.to_hex(a), "d3b5e1f00b1c2a99887766554433221100ffeeddccbbaa99")
  eq(bn.to_bytes(bn.from_bytes("\0\0\1\2"), 4), "\0\0\1\2")
  local n = bn.from_hex(string.rep("f", 60) .. "1")
  eq(
    bn.to_hex(bn.modexp(a, bn.from_int(65537), n)),
    "540c2baa991f6150a2cb0899b5c71e22fb92b918fedcdf9646c43ac1814e"
  )
  eq(bn.to_hex(bn.modexp(a, a, n)), "d6b20b4d87db8a940805241b8f4f5bbc5b4c137ec4a6dd421bb03f331190")
  eq(bn.to_hex(bn.modexp(bn.from_int(4), bn.from_int(13), bn.from_int(497))), ("%x"):format(445))
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

T["public keys from SPKI and PKCS#1 PEM agree"] = function()
  local a = rsa.from_pem(read("tests/fixtures/rsa2048.pub.pem"))
  local b = rsa.from_pem(read("tests/fixtures/rsa2048.pkcs1.pem"))
  eq(a.size, 256)
  eq(bn.to_hex(a.n), bn.to_hex(b.n))
  eq(bn.to_hex(a.e), "10001")
end

T["OAEP ciphertext decrypts with openssl"] = function()
  if vim.fn.executable("openssl") == 0 then
    MiniTest.skip("openssl not installed")
  end
  local key = rsa.from_pem(read("tests/fixtures/rsa2048.pub.pem"))
  local msg = "secret password\0"
  local t0 = vim.uv.hrtime()
  local ct = rsa.oaep_encrypt(key, msg)
  MiniTest.add_note(("RSA-2048 public op: %.1f ms"):format((vim.uv.hrtime() - t0) / 1e6))
  eq(#ct, 256)
  local ctfile = vim.fn.tempname()
  local f = assert(io.open(ctfile, "wb"))
  f:write(ct)
  f:close()
  local out = vim
    .system({
      "openssl",
      "pkeyutl",
      "-decrypt",
      "-inkey",
      "tests/fixtures/rsa2048.pem",
      "-pkeyopt",
      "rsa_padding_mode:oaep",
      "-in",
      ctfile,
    })
    :wait()
  eq(out.code, 0)
  eq(out.stdout, msg)
end

return T
