-- AES-GCM (FIPS 197, GCM spec test case 4) and ChaCha20-Poly1305 (RFC 8439) vectors;
-- expected values double-checked with Python's cryptography package.
local aes = require("dbdash.crypto.aes_gcm")
local chacha = require("dbdash.crypto.chacha20_poly1305")
local u = require("dbdash.crypto.util")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["AES block (FIPS 197 C.1 and C.3)"] = function()
  local pt = u.unhex("00112233445566778899aabbccddeeff")
  eq(u.hex(aes.encrypt_block(u.unhex("000102030405060708090a0b0c0d0e0f"), pt)), "69c4e0d86a7b0430d8cdb78070b4c55a")
  eq(u.hex(aes.encrypt_block(u.unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"), pt)), "8ea2b7ca516745bfeafc49904b496089")
end

local K = u.unhex("feffe9928665731c6d6a8f9467308308")
local IV = u.unhex("cafebabefacedbaddecaf888")
local P = u.unhex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
local A = u.unhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
local CT = "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091" .. "5bc94fbc3221a5db94fae95ae7121a47"

T["AES-128-GCM test case 4"] = function()
  local g = aes.new(K)
  eq(u.hex(g:seal(IV, P, A)), CT)
  eq(g:open(IV, u.unhex(CT), A), P)
  local bad = u.unhex(CT):sub(1, -2) .. "\0"
  eq(g:open(IV, bad, A), nil)
  eq(g:open(IV, u.unhex(CT), "x"), nil)
end

T["AES-GCM empty input (test case 1)"] = function()
  local g = aes.new(string.rep("\0", 16))
  eq(u.hex(g:seal(string.rep("\0", 12), "", "")), "58e2fccefa7e3061367f1d57a4e7455a")
end

local CK = ""
for i = 0x80, 0x9f do
  CK = CK .. string.char(i)
end
local CN = u.unhex("070000004041424344454647")
local CA = u.unhex("50515253c0c1c2c3c4c5c6c7")
local CP = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
local CCT = "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116" .. "1ae10b594f09e26a7e902ecbd0600691"

T["ChaCha20 block (RFC 8439 2.3.2)"] = function()
  local key = ""
  for i = 0, 31 do
    key = key .. string.char(i)
  end
  local blk = chacha.block(key, 1, u.unhex("000000090000004a00000000"))
  eq(u.hex(blk):sub(1, 32), "10f1e7e4d13b5915500fdd1fa32071c4")
end

T["Poly1305 (RFC 8439 2.5.2)"] = function()
  local key = u.unhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
  eq(u.hex(chacha.poly1305("Cryptographic Forum Research Group", key)), "a8061dc1305136c6c22b8baf0c0127a9")
end

T["ChaCha20-Poly1305 AEAD (RFC 8439 2.8.2)"] = function()
  local c = chacha.new(CK)
  eq(u.hex(c:seal(CN, CP, CA)), CCT)
  eq(c:open(CN, u.unhex(CCT), CA), CP)
  eq(c:open(CN, u.unhex(CCT), "x"), nil)
end

T["throughput"] = function()
  local data = string.rep("x", 65536)
  local g = aes.new(K)
  local t0 = vim.uv.hrtime()
  g:seal(IV, data, "")
  local t1 = vim.uv.hrtime()
  chacha.new(CK):seal(CN, data, "")
  local t2 = vim.uv.hrtime()
  MiniTest.add_note(("64 KiB: AES-GCM %.0f ms, ChaCha20-Poly1305 %.0f ms"):format((t1 - t0) / 1e6, (t2 - t1) / 1e6))
end

return T
