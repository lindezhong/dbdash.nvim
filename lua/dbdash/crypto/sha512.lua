-- SHA-512 (FIPS 180-4) using LuaJIT 64-bit integer cdata.
local bit = require("bit")
local ffi = require("ffi")
local md = require("dbdash.crypto.md")

local band, bxor, bnot, rshift, bor, lshift, ror =
  bit.band, bit.bxor, bit.bnot, bit.rshift, bit.bor, bit.lshift, bit.ror

local U64 = ffi.typeof("uint64_t") --[[@as fun(v: any): any]] -- uint64_t values

local K = {
  0x428a2f98d728ae22ULL,
  0x7137449123ef65cdULL,
  0xb5c0fbcfec4d3b2fULL,
  0xe9b5dba58189dbbcULL,
  0x3956c25bf348b538ULL,
  0x59f111f1b605d019ULL,
  0x923f82a4af194f9bULL,
  0xab1c5ed5da6d8118ULL,
  0xd807aa98a3030242ULL,
  0x12835b0145706fbeULL,
  0x243185be4ee4b28cULL,
  0x550c7dc3d5ffb4e2ULL,
  0x72be5d74f27b896fULL,
  0x80deb1fe3b1696b1ULL,
  0x9bdc06a725c71235ULL,
  0xc19bf174cf692694ULL,
  0xe49b69c19ef14ad2ULL,
  0xefbe4786384f25e3ULL,
  0x0fc19dc68b8cd5b5ULL,
  0x240ca1cc77ac9c65ULL,
  0x2de92c6f592b0275ULL,
  0x4a7484aa6ea6e483ULL,
  0x5cb0a9dcbd41fbd4ULL,
  0x76f988da831153b5ULL,
  0x983e5152ee66dfabULL,
  0xa831c66d2db43210ULL,
  0xb00327c898fb213fULL,
  0xbf597fc7beef0ee4ULL,
  0xc6e00bf33da88fc2ULL,
  0xd5a79147930aa725ULL,
  0x06ca6351e003826fULL,
  0x142929670a0e6e70ULL,
  0x27b70a8546d22ffcULL,
  0x2e1b21385c26c926ULL,
  0x4d2c6dfc5ac42aedULL,
  0x53380d139d95b3dfULL,
  0x650a73548baf63deULL,
  0x766a0abb3c77b2a8ULL,
  0x81c2c92e47edaee6ULL,
  0x92722c851482353bULL,
  0xa2bfe8a14cf10364ULL,
  0xa81a664bbc423001ULL,
  0xc24b8b70d0f89791ULL,
  0xc76c51a30654be30ULL,
  0xd192e819d6ef5218ULL,
  0xd69906245565a910ULL,
  0xf40e35855771202aULL,
  0x106aa07032bbd1b8ULL,
  0x19a4c116b8d2d0c8ULL,
  0x1e376c085141ab53ULL,
  0x2748774cdf8eeb99ULL,
  0x34b0bcb5e19b48a8ULL,
  0x391c0cb3c5c95a63ULL,
  0x4ed8aa4ae3418acbULL,
  0x5b9cca4f7763e373ULL,
  0x682e6ff3d6b2b8a3ULL,
  0x748f82ee5defb2fcULL,
  0x78a5636f43172f60ULL,
  0x84c87814a1f0ab72ULL,
  0x8cc702081a6439ecULL,
  0x90befffa23631e28ULL,
  0xa4506cebde82bde9ULL,
  0xbef9a3f7b2c67915ULL,
  0xc67178f2e372532bULL,
  0xca273eceea26619cULL,
  0xd186b8c721c0c207ULL,
  0xeada7dd6cde0eb1eULL,
  0xf57d4f7fee6ed178ULL,
  0x06f067aa72176fbaULL,
  0x0a637dc5a2c898a6ULL,
  0x113f9804bef90daeULL,
  0x1b710b35131c471bULL,
  0x28db77f523047d84ULL,
  0x32caab7b40c72493ULL,
  0x3c9ebe0a15c9bebcULL,
  0x431d67c49c100d4cULL,
  0x4cc5d4becb3e42b6ULL,
  0x597f299cfc657e2aULL,
  0x5fcb6fab3ad6faecULL,
  0x6c44198c4a475817ULL,
}

local W = {}

local function compress(H, s, off)
  for i = 0, 15 do
    local w = U64(0) ---@type any (a uint64_t cdata)
    for k = 0, 7 do
      w = bor(lshift(w, 8), U64(s:byte(off + i * 8 + k)))
    end
    W[i] = w
  end
  for i = 16, 79 do
    local w15, w2 = W[i - 15], W[i - 2]
    local s0 = bxor(ror(w15, 1), ror(w15, 8), rshift(w15, 7))
    local s1 = bxor(ror(w2, 19), ror(w2, 61), rshift(w2, 6))
    W[i] = W[i - 16] + s0 + W[i - 7] + s1
  end
  local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
  for i = 0, 79 do
    local S1 = bxor(ror(e, 14), ror(e, 18), ror(e, 41))
    local ch = bxor(band(e, f), band(bnot(e), g))
    local t1 = h + S1 + ch + K[i + 1] + W[i]
    local S0 = bxor(ror(a, 28), ror(a, 34), ror(a, 39))
    local maj = bxor(band(a, b), band(a, c), band(b, c))
    h, g, f, e, d, c, b, a = g, f, e, d + t1, c, b, a, t1 + S0 + maj
  end
  H[1], H[2], H[3], H[4] = H[1] + a, H[2] + b, H[3] + c, H[4] + d
  H[5], H[6], H[7], H[8] = H[5] + e, H[6] + f, H[7] + g, H[8] + h
end

local function be64(w)
  local out = {}
  for k = 7, 0, -1 do
    out[#out + 1] = string.char(tonumber(band(rshift(w, k * 8), 0xff)) or 0)
  end
  return table.concat(out)
end

local function define(init, size, name)
  local H = md.define({
    block = 128,
    init = init,
    compress = compress,
    digest = function(st)
      local out = {}
      for i = 1, 8 do
        out[i] = be64(st[i])
      end
      return table.concat(out):sub(1, size)
    end,
    length = function(bits)
      return string.rep("\0", 8) .. md.be64(bits)
    end,
  })
  H.name, H.size = name, size
  return H
end

local M = md.define({
  block = 128,
  init = function()
    return {
      0x6a09e667f3bcc908ULL,
      0xbb67ae8584caa73bULL,
      0x3c6ef372fe94f82bULL,
      0xa54ff53a5f1d36f1ULL,
      0x510e527fade682d1ULL,
      0x9b05688c2b3e6c1fULL,
      0x1f83d9abfb41bd6bULL,
      0x5be0cd19137e2179ULL,
    }
  end,
  compress = compress,
  digest = function(H)
    local out = {}
    for i = 1, 8 do
      out[i] = be64(H[i])
    end
    return table.concat(out)
  end,
  length = function(bits)
    return string.rep("\0", 8) .. md.be64(bits)
  end,
})
M.name = "sha512"
M.size = 64

---SHA-384: SHA-512 with other initial values, truncated to 48 bytes.
M.sha384 = define(function()
  return {
    0xcbbb9d5dc1059ed8ULL,
    0x629a292a367cd507ULL,
    0x9159015a3070dd17ULL,
    0x152fecd8f70e5939ULL,
    0x67332667ffc00b31ULL,
    0x8eb44a8768581511ULL,
    0xdb0c2e0d64f98fa7ULL,
    0x47b5481dbefa4fa4ULL,
  }
end, 48, "sha384")

return M
