-- SHA-1 (FIPS 180-4). Only for protocols that require it (mysql_native_password).
local bit = require("bit")
local md = require("dbdash.crypto.md")
local u = require("dbdash.crypto.util")

local band, bxor, bnot, bor, lshift, rol, tobit =
  bit.band, bit.bxor, bit.bnot, bit.bor, bit.lshift, bit.rol, bit.tobit

local W = {}

local function compress(H, s, off)
  for i = 0, 15 do
    local a, b, c, d = s:byte(off + i * 4, off + i * 4 + 3)
    W[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
  end
  for i = 16, 79 do
    W[i] = rol(bxor(W[i - 3], W[i - 8], W[i - 14], W[i - 16]), 1)
  end
  local a, b, c, d, e = H[1], H[2], H[3], H[4], H[5]
  for i = 0, 79 do
    local f, k
    if i < 20 then
      f, k = bor(band(b, c), band(bnot(b), d)), 0x5a827999
    elseif i < 40 then
      f, k = bxor(b, c, d), 0x6ed9eba1
    elseif i < 60 then
      f, k = bor(band(b, c), band(b, d), band(c, d)), -0x70e44324 -- 0x8f1bbcdc
    else
      f, k = bxor(b, c, d), -0x359d3e2a -- 0xca62c1d6
    end
    local t = tobit(rol(a, 5) + f + e + k + W[i])
    e, d, c, b, a = d, c, rol(b, 30), a, t
  end
  H[1], H[2], H[3], H[4], H[5] =
    tobit(H[1] + a), tobit(H[2] + b), tobit(H[3] + c), tobit(H[4] + d), tobit(H[5] + e)
end

local M = md.define({
  block = 64,
  init = function()
    return {
      tobit(0x67452301),
      tobit(0xefcdab89),
      tobit(0x98badcfe),
      tobit(0x10325476),
      tobit(0xc3d2e1f0),
    }
  end,
  compress = compress,
  digest = function(H)
    local out = {}
    for i = 1, 5 do
      out[i] = u.be32(H[i])
    end
    return table.concat(out)
  end,
  length = md.be64,
})
M.name = "sha1"
M.size = 20

return M
