-- AES-128/192/256 block cipher (FIPS 197) with T-tables for encryption and decryption,
-- plus CBC mode (used by the TLS 1.2 CBC cipher suites). AES-GCM builds on M.encrypt_words.
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

-- Decryption ----------------------------------------------------------------------------------

local INV_SBOX = {}
for x = 0, 255 do
  INV_SBOX[SBOX[x]] = x
end

local function gmul8(a, b)
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

local TD0, TD1, TD2, TD3 = {}, {}, {}, {}
for x = 0, 255 do
  local s = INV_SBOX[x]
  local w = tobit(bor(lshift(gmul8(s, 14), 24), lshift(gmul8(s, 9), 16), lshift(gmul8(s, 13), 8), gmul8(s, 11)))
  TD0[x], TD1[x], TD2[x], TD3[x] = w, ror(w, 8), ror(w, 16), ror(w, 24)
end

---InvMixColumns of one round-key word.
local function inv_mix(w)
  return bxor(
    TD0[SBOX[band(rshift(w, 24), 255)]],
    TD1[SBOX[band(rshift(w, 16), 255)]],
    TD2[SBOX[band(rshift(w, 8), 255)]],
    TD3[SBOX[band(w, 255)]]
  )
end

---Decryption round keys for the equivalent inverse cipher.
local function inverse(ks)
  if ks.dk then
    return ks.dk
  end
  local w, r = ks.w, ks.rounds
  local dk = {}
  for c = 0, 3 do
    dk[c] = w[4 * r + c]
    dk[4 * r + c] = w[c]
  end
  for round = 1, r - 1 do
    for c = 0, 3 do
      dk[4 * round + c] = inv_mix(w[4 * (r - round) + c])
    end
  end
  ks.dk = dk
  return dk
end

---Decrypt one block given as four words; returns four words.
function M.decrypt_words(ks, s0, s1, s2, s3)
  local w = inverse(ks)
  s0, s1, s2, s3 = bxor(s0, w[0]), bxor(s1, w[1]), bxor(s2, w[2]), bxor(s3, w[3])
  local k = 4
  for _ = 1, ks.rounds - 1 do
    local t0 = bxor(TD0[rshift(s0, 24)], TD1[band(rshift(s3, 16), 255)], TD2[band(rshift(s2, 8), 255)], TD3[band(s1, 255)], w[k])
    local t1 = bxor(TD0[rshift(s1, 24)], TD1[band(rshift(s0, 16), 255)], TD2[band(rshift(s3, 8), 255)], TD3[band(s2, 255)], w[k + 1])
    local t2 = bxor(TD0[rshift(s2, 24)], TD1[band(rshift(s1, 16), 255)], TD2[band(rshift(s0, 8), 255)], TD3[band(s3, 255)], w[k + 2])
    local t3 = bxor(TD0[rshift(s3, 24)], TD1[band(rshift(s2, 16), 255)], TD2[band(rshift(s1, 8), 255)], TD3[band(s0, 255)], w[k + 3])
    s0, s1, s2, s3 = t0, t1, t2, t3
    k = k + 4
  end
  local function last(a, b, c, d, rk)
    return tobit(bxor(bor(lshift(INV_SBOX[rshift(a, 24)], 24), lshift(INV_SBOX[band(rshift(b, 16), 255)], 16), lshift(INV_SBOX[band(rshift(c, 8), 255)], 8), INV_SBOX[band(d, 255)]), rk))
  end
  return last(s0, s3, s2, s1, w[k]), last(s1, s0, s3, s2, w[k + 1]), last(s2, s1, s0, s3, w[k + 2]), last(s3, s2, s1, s0, w[k + 3])
end

---AES block decryption (16-byte string).
function M.decrypt_block(key, block)
  local ks = type(key) == "table" and key or expand(key)
  local a, b, c, d = M.decrypt_words(ks, word(block, 1), word(block, 5), word(block, 9), word(block, 13))
  return util.be32(a) .. util.be32(b) .. util.be32(c) .. util.be32(d)
end

-- CBC ---------------------------------------------------------------------------------------

---CBC encryption of data whose length is a multiple of 16 (no padding added).
function M.cbc_encrypt(key, iv, data)
  local ks = type(key) == "table" and key or expand(key)
  local p0, p1, p2, p3 = word(iv, 1), word(iv, 5), word(iv, 9), word(iv, 13)
  local out = {}
  for off = 1, #data, 16 do
    p0, p1, p2, p3 = encrypt_words(ks, bxor(p0, word(data, off)), bxor(p1, word(data, off + 4)), bxor(p2, word(data, off + 8)), bxor(p3, word(data, off + 12)))
    out[#out + 1] = util.be32(p0) .. util.be32(p1) .. util.be32(p2) .. util.be32(p3)
  end
  return table.concat(out)
end

---CBC decryption of data whose length is a multiple of 16 (padding left in place).
function M.cbc_decrypt(key, iv, data)
  local ks = type(key) == "table" and key or expand(key)
  local c0, c1, c2, c3 = word(iv, 1), word(iv, 5), word(iv, 9), word(iv, 13)
  local out = {}
  for off = 1, #data, 16 do
    local n0, n1, n2, n3 = word(data, off), word(data, off + 4), word(data, off + 8), word(data, off + 12)
    local a, b, c, d = M.decrypt_words(ks, n0, n1, n2, n3)
    out[#out + 1] = util.be32(bxor(a, c0)) .. util.be32(bxor(b, c1)) .. util.be32(bxor(c, c2)) .. util.be32(bxor(d, c3))
    c0, c1, c2, c3 = n0, n1, n2, n3
  end
  return table.concat(out)
end

M.expand = expand
M.encrypt_words = encrypt_words
M.word = word

return M
