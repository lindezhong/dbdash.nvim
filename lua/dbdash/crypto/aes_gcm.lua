-- AES-128/256-GCM (NIST SP 800-38D) on top of dbdash.crypto.aes; GHASH multiplies bit by
-- bit over four 32-bit words.
local bit = require("bit")
local util = require("dbdash.crypto.util")
local aes = require("dbdash.crypto.aes")

local band, bor, bxor, lshift, rshift, tobit =
  bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.tobit
local expand, encrypt_words, word = aes.expand, aes.encrypt_words, aes.word

local M = {}

M.encrypt_block = aes.encrypt_block

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
      y0, y1, y2, y3 = gmul(
        bxor(y0, word(blk, 1)),
        bxor(y1, word(blk, 5)),
        bxor(y2, word(blk, 9)),
        bxor(y3, word(blk, 13)),
        h0,
        h1,
        h2,
        h3
      )
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
    h0,
    h1,
    h2,
    h3
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
