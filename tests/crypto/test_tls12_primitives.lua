-- AES decryption / CBC and the TLS 1.2 PRF; expectations from Python's cryptography and hmac.
local aes = require("dbdash.crypto.aes")
local prf = require("dbdash.crypto.prf12")
local u = require("dbdash.crypto.util")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function range(a, b)
  local t = {}
  for i = a, b do
    t[#t + 1] = string.char(i)
  end
  return table.concat(t)
end

T["AES decryption inverts encryption (FIPS 197)"] = function()
  local pt = u.unhex("00112233445566778899aabbccddeeff")
  for _, k in ipairs({ range(0, 15), range(0, 23), range(0, 31) }) do
    eq(aes.decrypt_block(k, aes.encrypt_block(k, pt)), pt)
  end
  eq(
    u.hex(aes.decrypt_block(range(0, 15), u.unhex("69c4e0d86a7b0430d8cdb78070b4c55a"))),
    "00112233445566778899aabbccddeeff"
  )
end

T["CBC (checked with Python cryptography)"] = function()
  local iv, pt = range(16, 31), range(0, 47)
  local c128 =
    "954f64f2e4e86e9eee82d20216684899a93b9ddb22e8ab104c61e728831d6d5a1f51afc19343249ef3b4495be12dc4f3"
  local c256 =
    "9f3b7504926f8bd36e3118e903a4cd4a25c183f70fdb4812cc2453fa00b3d390fbd621f919e2d9a0cb10aa5647bee3a7"
  eq(u.hex(aes.cbc_encrypt(range(0, 15), iv, pt)), c128)
  eq(u.hex(aes.cbc_encrypt(range(0, 31), iv, pt)), c256)
  eq(aes.cbc_decrypt(range(0, 15), iv, u.unhex(c128)), pt)
  eq(aes.cbc_decrypt(range(0, 31), iv, u.unhex(c256)), pt)
end

T["TLS 1.2 PRF"] = function()
  local sha256 = require("dbdash.crypto.sha256")
  local sha384 = require("dbdash.crypto.sha512").sha384
  eq(#prf.prf(sha256, "secret", "test label", "seed", 100), 100)
  eq(
    u.hex(prf.prf(sha256, "secret", "test label", "seed", 100)),
    "bfc72aea54e12f176b7549dc7d0082fecd2be093284636015f9149017f433669e453c27d2993bfb7cd5abd8c655edc7a7ab65b8e3f9f5272de648904d9fdc2474b294e1428cd414c44924ed42bfae63a0f7e36be33d7ded665b7da06df18f98b7b99124f"
  )
  eq(
    u.hex(prf.prf(sha384, "secret", "test label", "seed", 48)),
    "cdd47dc0124953e293a71e0f3fcc02ab44f08334cb2ca2136fafc00d82a403080ec07bb017728d8d7e2ad075878bed7a"
  )
end

return T
