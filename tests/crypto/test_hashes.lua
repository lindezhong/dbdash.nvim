-- Official test vectors (FIPS 180-4 examples, RFC 1321, RFC 4231, RFC 6070, RFC 7914,
-- RFC 5869, RFC 8448).
local u = require("dbdash.crypto.util")
local sha1 = require("dbdash.crypto.sha1")
local sha256 = require("dbdash.crypto.sha256")
local sha512 = require("dbdash.crypto.sha512")
local md5 = require("dbdash.crypto.md5")
local hmac = require("dbdash.crypto.hmac")
local pbkdf2 = require("dbdash.crypto.pbkdf2")
local hkdf = require("dbdash.crypto.hkdf")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local ABC448 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
local ABC896 = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"

T["sha1"] = function()
  eq(u.hex(sha1.digest("")), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
  eq(u.hex(sha1.digest("abc")), "a9993e364706816aba3e25717850c26c9cd0d89d")
  eq(u.hex(sha1.digest(ABC448)), "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
end

T["sha256"] = function()
  eq(u.hex(sha256.digest("")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  eq(u.hex(sha256.digest("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  eq(u.hex(sha256.digest(ABC448)), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  eq(u.hex(sha256.digest(string.rep("a", 1000000))), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
end

T["sha512"] = function()
  eq(u.hex(sha512.digest("abc")), "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
  eq(u.hex(sha512.digest("")), "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
  eq(u.hex(sha512.digest(ABC896)), "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
end

T["md5"] = function()
  eq(u.hex(md5.digest("")), "d41d8cd98f00b204e9800998ecf8427e")
  eq(u.hex(md5.digest("abc")), "900150983cd24fb0d6963f7d28e17f72")
  eq(u.hex(md5.digest("12345678901234567890123456789012345678901234567890123456789012345678901234567890")), "57edf4a22be3c955ac49da2e2107b67a")
end

T["incremental updates match one-shot digests"] = function()
  local h = sha256.new()
  for i = 1, 130 do
    h:update(string.char(i % 256))
  end
  local s = {}
  for i = 1, 130 do
    s[i] = string.char(i % 256)
  end
  eq(h:final(), sha256.digest(table.concat(s)))
  local a = sha256.new():update("ab")
  local b = a:copy():update("c")
  eq(u.hex(b:final()), u.hex(sha256.digest("abc")))
  eq(u.hex(a:update("x"):final()), u.hex(sha256.digest("abx")))
end

T["hmac (RFC 4231)"] = function()
  local key = string.rep("\11", 20)
  eq(u.hex(hmac.hmac(sha256, key, "Hi There")), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
  eq(u.hex(hmac.hmac(sha512, key, "Hi There")), "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854")
  eq(u.hex(hmac.hmac(sha256, "Jefe", "what do ya want for nothing?")), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
  local long = string.rep("\170", 131)
  eq(u.hex(hmac.hmac(sha256, long, "Test Using Larger Than Block-Size Key - Hash Key First")), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
  eq(u.hex(hmac.hmac(sha1, key, "Hi There")), "b617318655057264e28bc0b6fb378c8ef146be00")
end

T["pbkdf2 (RFC 6070, RFC 7914)"] = function()
  eq(u.hex(pbkdf2.derive(sha1, "password", "salt", 1, 20)), "0c60c80f961f0e71f3a9b524af6012062fe037a6")
  eq(u.hex(pbkdf2.derive(sha1, "password", "salt", 4096, 20)), "4b007901b765489abead49d926f721d065a429c1")
  eq(u.hex(pbkdf2.derive(sha256, "passwd", "salt", 1, 64)), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
end

T["hkdf (RFC 5869 case 1)"] = function()
  local ikm = string.rep("\11", 22)
  local salt = u.unhex("000102030405060708090a0b0c")
  local info = u.unhex("f0f1f2f3f4f5f6f7f8f9")
  local prk = hkdf.extract(sha256, salt, ikm)
  eq(u.hex(prk), "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
  eq(u.hex(hkdf.expand(sha256, prk, info, 42)), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
end

T["hkdf expand_label (RFC 8448 early secret)"] = function()
  local early = hkdf.extract(sha256, "", string.rep("\0", 32))
  eq(u.hex(early), "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a")
  local derived = hkdf.expand_label(sha256, early, "derived", sha256.digest(""), 32)
  eq(u.hex(derived), "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba")
end

T["random bytes"] = function()
  local r = require("dbdash.crypto.random")
  local a, b = r.bytes(32), r.bytes(32)
  eq(#a, 32)
  eq(a ~= b, true)
end

T["pbkdf2 cost at SCRAM iteration counts"] = function()
  local t0 = vim.uv.hrtime()
  pbkdf2.derive(sha256, "pencil", "salt", 4096)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  MiniTest.add_note(("pbkdf2-sha256 x4096: %.1f ms"):format(ms))
  eq(ms < 2000, true)
end

return T
