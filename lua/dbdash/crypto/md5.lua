-- MD5 (RFC 1321). Only for PostgreSQL md5 authentication.
local bit = require("bit")
local md = require("dbdash.crypto.md")

local band, bor, bxor, bnot, rol, tobit, lshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol, bit.tobit, bit.lshift

local S = {
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}
local K = {}
for i = 0, 63 do
  K[i] = tobit(math.floor(math.abs(math.sin(i + 1)) * 4294967296))
end

local X = {}

local function compress(H, s, off)
  for i = 0, 15 do
    local a, b, c, d = s:byte(off + i * 4, off + i * 4 + 3)
    X[i] = bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24))
  end
  local a, b, c, d = H[1], H[2], H[3], H[4]
  for i = 0, 63 do
    local f, g
    if i < 16 then
      f, g = bor(band(b, c), band(bnot(b), d)), i
    elseif i < 32 then
      f, g = bor(band(d, b), band(bnot(d), c)), (5 * i + 1) % 16
    elseif i < 48 then
      f, g = bxor(b, c, d), (3 * i + 5) % 16
    else
      f, g = bxor(c, bor(b, bnot(d))), (7 * i) % 16
    end
    local t = d
    d = c
    c = b
    b = tobit(b + rol(tobit(a + f + K[i] + X[g]), S[i + 1]))
    a = t
  end
  H[1], H[2], H[3], H[4] = tobit(H[1] + a), tobit(H[2] + b), tobit(H[3] + c), tobit(H[4] + d)
end

local function le32(n)
  return string.char(band(n, 255), band(bit.rshift(n, 8), 255), band(bit.rshift(n, 16), 255), band(bit.rshift(n, 24), 255))
end

local M = md.define({
  block = 64,
  init = function()
    return { tobit(0x67452301), tobit(0xefcdab89), tobit(0x98badcfe), tobit(0x10325476) }
  end,
  compress = compress,
  digest = function(H)
    return le32(H[1]) .. le32(H[2]) .. le32(H[3]) .. le32(H[4])
  end,
  length = md.le64,
})
M.name = "md5"
M.size = 16

return M
