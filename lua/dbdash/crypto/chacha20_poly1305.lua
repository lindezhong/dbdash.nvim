-- ChaCha20-Poly1305 AEAD (RFC 8439). Poly1305 follows TweetNaCl's 17 x 8-bit limbs.
local bit = require("bit")
local util = require("dbdash.crypto.util")

local band, bor, bxor, lshift, rshift, rol, tobit = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.rol, bit.tobit

local M = {}

local function le32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return tobit(bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24)))
end

local function le32s(n)
  return string.char(band(n, 255), band(rshift(n, 8), 255), band(rshift(n, 16), 255), band(rshift(n, 24), 255))
end

local x = {}

---One 64-byte ChaCha20 block.
function M.block(key, counter, nonce)
  local s = {
    tobit(0x61707865), tobit(0x3320646e), tobit(0x79622d32), tobit(0x6b206574),
    le32(key, 1), le32(key, 5), le32(key, 9), le32(key, 13),
    le32(key, 17), le32(key, 21), le32(key, 25), le32(key, 29),
    tobit(counter), le32(nonce, 1), le32(nonce, 5), le32(nonce, 9),
  }
  for i = 1, 16 do
    x[i] = s[i]
  end
  local function qr(a, b, c, d)
    x[a] = tobit(x[a] + x[b]); x[d] = rol(bxor(x[d], x[a]), 16)
    x[c] = tobit(x[c] + x[d]); x[b] = rol(bxor(x[b], x[c]), 12)
    x[a] = tobit(x[a] + x[b]); x[d] = rol(bxor(x[d], x[a]), 8)
    x[c] = tobit(x[c] + x[d]); x[b] = rol(bxor(x[b], x[c]), 7)
  end
  for _ = 1, 10 do
    qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15); qr(4, 8, 12, 16)
    qr(1, 6, 11, 16); qr(2, 7, 12, 13); qr(3, 8, 9, 14); qr(4, 5, 10, 15)
  end
  local out = {}
  for i = 1, 16 do
    out[i] = le32s(tobit(x[i] + s[i]))
  end
  return table.concat(out)
end

---XOR data with the keystream starting at block `counter`.
function M.xor_stream(key, counter, nonce, data)
  local out = {}
  for off = 1, #data, 64 do
    local chunk = data:sub(off, off + 63)
    out[#out + 1] = util.xor(chunk, M.block(key, counter, nonce):sub(1, #chunk))
    counter = counter + 1
  end
  return table.concat(out)
end

-- Poly1305 ----------------------------------------------------------------------------------

local function add1305(h, c)
  local u = 0
  for j = 1, 17 do
    u = u + h[j] + c[j]
    h[j] = u % 256
    u = math.floor(u / 256)
  end
end

local MINUSP = { 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 252 }

---Poly1305 MAC of `m` with a 32-byte one-time key.
function M.poly1305(m, key)
  local r, h, c, xx, g = {}, {}, {}, {}, {}
  for j = 1, 17 do
    r[j], h[j] = 0, 0
  end
  for j = 1, 16 do
    r[j] = key:byte(j)
  end
  r[4] = band(r[4], 15); r[5] = band(r[5], 252); r[8] = band(r[8], 15); r[9] = band(r[9], 252)
  r[12] = band(r[12], 15); r[13] = band(r[13], 252); r[16] = band(r[16], 15)
  local pos, n = 1, #m
  while n > 0 do
    local take = math.min(16, n)
    for j = 1, 17 do
      c[j] = 0
    end
    for j = 1, take do
      c[j] = m:byte(pos + j - 1)
    end
    c[take + 1] = 1
    pos, n = pos + take, n - take
    add1305(h, c)
    for i = 1, 17 do
      local s = 0
      for j = 1, 17 do
        if j <= i then
          s = s + h[j] * r[i - j + 1]
        else
          s = s + h[j] * 320 * r[i + 17 - j + 1]
        end
      end
      xx[i] = s
    end
    for i = 1, 17 do
      h[i] = xx[i]
    end
    local u = 0
    for j = 1, 16 do
      u = u + h[j]
      h[j] = u % 256
      u = math.floor(u / 256)
    end
    u = u + h[17]
    h[17] = u % 4
    u = 5 * math.floor(u / 4)
    for j = 1, 16 do
      u = u + h[j]
      h[j] = u % 256
      u = math.floor(u / 256)
    end
    h[17] = h[17] + u
  end
  for j = 1, 17 do
    g[j] = h[j]
  end
  add1305(h, MINUSP)
  if h[17] >= 128 then -- h < p: keep the unreduced value
    for j = 1, 17 do
      h[j] = g[j]
    end
  end
  for j = 1, 16 do
    c[j] = key:byte(j + 16)
  end
  c[17] = 0
  add1305(h, c)
  local out = {}
  for j = 1, 16 do
    out[j] = string.char(h[j])
  end
  return table.concat(out)
end

-- AEAD --------------------------------------------------------------------------------------

local function pad16(s)
  local r = #s % 16
  return r == 0 and "" or string.rep("\0", 16 - r)
end

local function le64(n)
  return le32s(tobit(n % 4294967296)) .. le32s(tobit(math.floor(n / 4294967296)))
end

local Aead = {}
Aead.__index = Aead

function Aead:tag(nonce, aad, ct)
  local otk = M.block(self.key, 0, nonce):sub(1, 32)
  return M.poly1305(aad .. pad16(aad) .. ct .. pad16(ct) .. le64(#aad) .. le64(#ct), otk)
end

function Aead:seal(nonce, plaintext, aad)
  aad = aad or ""
  local ct = M.xor_stream(self.key, 1, nonce, plaintext)
  return ct .. self:tag(nonce, aad, ct)
end

function Aead:open(nonce, data, aad)
  aad = aad or ""
  if #data < 16 then
    return nil
  end
  local ct, tag = data:sub(1, -17), data:sub(-16)
  if not util.equal(self:tag(nonce, aad, ct), tag) then
    return nil
  end
  return M.xor_stream(self.key, 1, nonce, ct)
end

---@param key string 32 bytes
---@return dbdash.crypto.Aead
function M.new(key)
  assert(#key == 32, "ChaCha20-Poly1305 key must be 32 bytes")
  return setmetatable({ key = key, key_size = 32, nonce_size = 12, tag_size = 16 }, Aead)
end

return M
