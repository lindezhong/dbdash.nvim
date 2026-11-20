-- AES-128/256-GCM (FIPS 197, NIST SP 800-38D). Encryption-only AES with T-tables; GHASH
-- multiplies bit by bit over four 32-bit words.
local bit = require("bit")
local util = require("dbdash.crypto.util")

local band, bor, bxor, lshift, rshift, ror, tobit = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.ror, bit.tobit

local M = {}

-- S-box and tables ----------------------------------------------------------------------------

local SBOX = {}
do
  -- Generate the S-box from the multiplicative inverse in GF(2^8) and the affine transform.
  local function mul(a, b)
    local p = 0
    for _ = 1, 8 do
      if band(b, 1) ~= 0 then
        p = bxor(p, a)
      end
      local hi = band(a, 0x80)
      a = band(lshift(a, 1), 0xff)
      if hi ~= 0 then
        a = bxor(a, 0x1b)
      end
      b = rshift(b, 1)
    end
    return p
  end
  for x = 0, 255 do
    local inv = 0
    if x ~= 0 then
      for y = 1, 255 do
        if mul(x, y) == 1 then
          inv = y
          break
        end
      end
    end
    local s = inv
    for k = 1, 4 do
      s = bxor(s, band(bor(lshift(inv, k), rshift(inv, 8 - k)), 0xff))
    end
    SBOX[x] = bxor(s, 0x63)
  end
end

local function xtime(a)
  a = lshift(a, 1)
  if band(a, 0x100) ~= 0 then
    a = bxor(a, 0x11b)
  end
  return a
end

local TE0, TE1, TE2, TE3 = {}, {}, {}, {}
for x = 0, 255 do
  local s = SBOX[x]
  local s2 = xtime(s)
  local s3 = bxor(s2, s)
  local w = tobit(bor(lshift(s2, 24), lshift(s, 16), lshift(s, 8), s3))
  TE0[x], TE1[x], TE2[x], TE3[x] = w, ror(w, 8), ror(w, 16), ror(w, 24)
end

local function word(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return tobit(bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d))
end

---Expand a 16- or 32-byte key into round keys.
local function expand(key)
  local nk = #key / 4
  local rounds = nk + 6
  local w = {}
  for i = 0, nk - 1 do
    w[i] = word(key, i * 4 + 1)
  end
  local rcon = 1
  for i = nk, 4 * (rounds + 1) - 1 do
    local t = w[i - 1]
    if i % nk == 0 then
      t = bor(lshift(SBOX[band(rshift(t, 16), 255)], 24), lshift(SBOX[band(rshift(t, 8), 255)], 16), lshift(SBOX[band(t, 255)], 8), SBOX[band(rshift(t, 24), 255)])
      t = bxor(t, lshift(rcon, 24))
      rcon = xtime(rcon)
    elseif nk > 6 and i % nk == 4 then
      t = bor(lshift(SBOX[band(rshift(t, 24), 255)], 24), lshift(SBOX[band(rshift(t, 16), 255)], 16), lshift(SBOX[band(rshift(t, 8), 255)], 8), SBOX[band(t, 255)])
    end
    w[i] = tobit(bxor(w[i - nk], t))
  end
  return { w = w, rounds = rounds }
end

---Encrypt one block given as four words; returns four words.
local function encrypt_words(ks, s0, s1, s2, s3)
  local w = ks.w
  s0, s1, s2, s3 = bxor(s0, w[0]), bxor(s1, w[1]), bxor(s2, w[2]), bxor(s3, w[3])
  local k = 4
  for _ = 1, ks.rounds - 1 do
    local t0 = bxor(TE0[rshift(s0, 24)], TE1[band(rshift(s1, 16), 255)], TE2[band(rshift(s2, 8), 255)], TE3[band(s3, 255)], w[k])
    local t1 = bxor(TE0[rshift(s1, 24)], TE1[band(rshift(s2, 16), 255)], TE2[band(rshift(s3, 8), 255)], TE3[band(s0, 255)], w[k + 1])
    local t2 = bxor(TE0[rshift(s2, 24)], TE1[band(rshift(s3, 16), 255)], TE2[band(rshift(s0, 8), 255)], TE3[band(s1, 255)], w[k + 2])
    local t3 = bxor(TE0[rshift(s3, 24)], TE1[band(rshift(s0, 16), 255)], TE2[band(rshift(s1, 8), 255)], TE3[band(s2, 255)], w[k + 3])
    s0, s1, s2, s3 = t0, t1, t2, t3
    k = k + 4
  end
  local function last(a, b, c, d, rk)
    return tobit(bxor(bor(lshift(SBOX[rshift(a, 24)], 24), lshift(SBOX[band(rshift(b, 16), 255)], 16), lshift(SBOX[band(rshift(c, 8), 255)], 8), SBOX[band(d, 255)]), rk))
  end
  return last(s0, s1, s2, s3, w[k]), last(s1, s2, s3, s0, w[k + 1]), last(s2, s3, s0, s1, w[k + 2]), last(s3, s0, s1, s2, w[k + 3])
end

---AES block encryption (16-byte string).
function M.encrypt_block(key, block)
  local ks = type(key) == "table" and key or expand(key)
  local a, b, c, d = encrypt_words(ks, word(block, 1), word(block, 5), word(block, 9), word(block, 13))
  return util.be32(a) .. util.be32(b) .. util.be32(c) .. util.be32(d)
end

-- GHASH -------------------------------------------------------------------------------------

local R = tobit(0xe1000000)

---X * H in GF(2^128) (both as four big-endian words).
local function gmul(x0, x1, x2, x3, h0, h1, h2, h3)
  local z0, z1, z2, z3 = 0, 0, 0, 0
  local v0, v1, v2, v3 = h0, h1, h2, h3
  local xs = { x0, x1, x2, x3 }
  for wi = 1, 4 do
    local xw = xs[wi]
    for b = 31, 0, -1 do
      if band(rshift(xw, b), 1) == 1 then
        z0, z1, z2, z3 = bxor(z0, v0), bxor(z1, v1), bxor(z2, v2), bxor(z3, v3)
      end
      local lsb = band(v3, 1)
      v3 = bor(rshift(v3, 1), lshift(band(v2, 1), 31))
      v2 = bor(rshift(v2, 1), lshift(band(v1, 1), 31))
      v1 = bor(rshift(v1, 1), lshift(band(v0, 1), 31))
      v0 = rshift(v0, 1)
      if lsb == 1 then
        v0 = bxor(v0, R)
      end
    end
  end
  return z0, z1, z2, z3
end

local function ghash(h, aad, ct)
  local h0, h1, h2, h3 = h[1], h[2], h[3], h[4]
  local y0, y1, y2, y3 = 0, 0, 0, 0
  local function absorb(data)
    for off = 1, #data, 16 do
      local blk = data:sub(off, off + 15)
      if #blk < 16 then
        blk = blk .. string.rep("\0", 16 - #blk)
      end
      y0, y1, y2, y3 = gmul(bxor(y0, word(blk, 1)), bxor(y1, word(blk, 5)), bxor(y2, word(blk, 9)), bxor(y3, word(blk, 13)), h0, h1, h2, h3)
    end
  end
  absorb(aad)
  absorb(ct)
  local la, lc = #aad * 8, #ct * 8
  y0, y1, y2, y3 = gmul(
    bxor(y0, tobit(math.floor(la / 4294967296))),
    bxor(y1, tobit(la % 4294967296)),
    bxor(y2, tobit(math.floor(lc / 4294967296))),
    bxor(y3, tobit(lc % 4294967296)),
    h0, h1, h2, h3
  )
  return util.be32(y0) .. util.be32(y1) .. util.be32(y2) .. util.be32(y3)
end

-- AEAD --------------------------------------------------------------------------------------

---@class dbdash.crypto.Aead
---@field key_size integer
---@field nonce_size integer
---@field tag_size integer
---@field seal fun(self, nonce: string, plaintext: string, aad: string): string ciphertext..tag
---@field open fun(self, nonce: string, ciphertext: string, aad: string): string? plaintext or nil

local Aead = {}
Aead.__index = Aead

---CTR keystream XOR starting at counter `ctr` (32-bit) for 12-byte nonce.
function Aead:ctr(nonce, ctr, data)
  local n0, n1, n2 = word(nonce, 1), word(nonce, 5), word(nonce, 9)
  local out = {}
  for off = 1, #data, 16 do
    local a, b, c, d = encrypt_words(self.ks, n0, n1, n2, tobit(ctr))
    local ks = util.be32(a) .. util.be32(b) .. util.be32(c) .. util.be32(d)
    local chunk = data:sub(off, off + 15)
    out[#out + 1] = util.xor(chunk, ks:sub(1, #chunk))
    ctr = ctr + 1
  end
  return table.concat(out)
end

function Aead:tag(nonce, aad, ct)
  local j0 = self:ctr(nonce, 1, string.rep("\0", 16))
  return util.xor(ghash(self.h, aad, ct), j0)
end

function Aead:seal(nonce, plaintext, aad)
  local ct = self:ctr(nonce, 2, plaintext)
  return ct .. self:tag(nonce, aad or "", ct)
end

function Aead:open(nonce, data, aad)
  if #data < 16 then
    return nil
  end
  local ct, tag = data:sub(1, -17), data:sub(-16)
  if not util.equal(self:tag(nonce, aad or "", ct), tag) then
    return nil
  end
  return self:ctr(nonce, 2, ct)
end

---@param key string 16 or 32 bytes
---@return dbdash.crypto.Aead
function M.new(key)
  assert(#key == 16 or #key == 32, "AES-GCM key must be 16 or 32 bytes")
  local ks = expand(key)
  local hb = M.encrypt_block(ks, string.rep("\0", 16))
  return setmetatable({
    ks = ks,
    h = { word(hb, 1), word(hb, 5), word(hb, 9), word(hb, 13) },
    key_size = #key,
    nonce_size = 12,
    tag_size = 16,
  }, Aead)
end

return M
