-- Non-negative big integers for RSA public-key operations.
--
-- Little-endian arrays of 24-bit limbs (products stay exact in doubles). Modular
-- exponentiation uses Montgomery multiplication (CIOS); only public operations are
-- needed, so there is no constant-time requirement beyond what the design allows.
local checkpoint = require("dbdash.util.async").checkpoint -- yields inside tasks only
local M = {}

local BITS = 24
local BASE = 2 ^ BITS

local floor = math.floor

local function norm(a)
  local n = #a
  while n > 1 and a[n] == 0 do
    a[n] = nil
    n = n - 1
  end
  if n == 0 then
    a[1] = 0
  end
  return a
end

---From big-endian bytes.
function M.from_bytes(s)
  local a = {}
  local limb, shift, k = 0, 0, 1
  for i = #s, 1, -1 do
    limb = limb + s:byte(i) * 2 ^ shift
    shift = shift + 8
    if shift == BITS then
      a[k], k, limb, shift = limb, k + 1, 0, 0
    end
  end
  if shift > 0 then
    a[k] = limb
  end
  return norm(a)
end

---To big-endian bytes, left-padded to `len`.
function M.to_bytes(a, len)
  local bytes = {}
  for i = 1, #a do
    local v = a[i]
    for _ = 1, BITS / 8 do
      bytes[#bytes + 1] = v % 256
      v = floor(v / 256)
    end
  end
  while #bytes > 1 and bytes[#bytes] == 0 do
    bytes[#bytes] = nil
  end
  local out = {}
  for i = #bytes, 1, -1 do
    out[#out + 1] = string.char(bytes[i])
  end
  local s = table.concat(out)
  if len then
    if #s > len then
      error("bignum does not fit in " .. len .. " bytes")
    end
    s = string.rep("\0", len - #s) .. s
  end
  return s
end

function M.from_int(n)
  local a = {}
  repeat
    a[#a + 1] = n % BASE
    n = floor(n / BASE)
  until n == 0
  return a
end

function M.cmp(a, b)
  if #a ~= #b then
    return #a < #b and -1 or 1
  end
  for i = #a, 1, -1 do
    if a[i] ~= b[i] then
      return a[i] < b[i] and -1 or 1
    end
  end
  return 0
end

---a - b (requires a >= b).
function M.sub(a, b)
  local r, borrow = {}, 0
  for i = 1, #a do
    local v = a[i] - (b[i] or 0) - borrow
    if v < 0 then
      v, borrow = v + BASE, 1
    else
      borrow = 0
    end
    r[i] = v
  end
  return norm(r)
end

function M.bitlen(a)
  local top = a[#a]
  local bits = (#a - 1) * BITS
  while top > 0 do
    bits = bits + 1
    top = floor(top / 2)
  end
  return bits
end

---a mod n by binary long division (used once per key for R^2 mod n).
local function mod_slow(a, n)
  local r = { 0 }
  for bit_i = M.bitlen(a) - 1, 0, -1 do
    -- r = 2r + bit
    local carry = floor(a[floor(bit_i / BITS) + 1] / 2 ^ (bit_i % BITS)) % 2
    for i = 1, #r do
      local v = r[i] * 2 + carry
      r[i] = v % BASE
      carry = floor(v / BASE)
    end
    if carry > 0 then
      r[#r + 1] = carry
    end
    if M.cmp(r, n) >= 0 then
      r = M.sub(r, n)
    end
  end
  return norm(r)
end
M.mod = mod_slow

---Montgomery context for an odd modulus.
local function context(n)
  local k = #n
  -- n0inv = -n^-1 mod 2^24 via Newton iteration on the lowest limb.
  local n0 = n[1]
  local inv = 1
  for _ = 1, 5 do
    inv = (inv * (2 - (n0 * inv) % BASE)) % BASE
  end
  local n0inv = (BASE - inv) % BASE
  -- R^2 mod n, R = BASE^k.
  local r2 = {}
  for i = 1, 2 * k do
    r2[i] = 0
  end
  r2[2 * k + 1] = 1
  return { n = n, k = k, n0inv = n0inv, r2 = mod_slow(r2, n) }
end

---Montgomery product a*b*R^-1 mod n (CIOS).
local function mont_mul(ctx, a, b)
  local n, k, n0inv = ctx.n, ctx.k, ctx.n0inv
  local t = {}
  for i = 1, k + 2 do
    t[i] = 0
  end
  for i = 1, k do
    local ai = a[i] or 0
    local carry = 0
    for j = 1, k do
      local v = t[j] + ai * (b[j] or 0) + carry
      carry = floor(v / BASE)
      t[j] = v - carry * BASE
    end
    local v = t[k + 1] + carry
    t[k + 1] = v % BASE
    t[k + 2] = floor(v / BASE)
    local m = (t[1] * n0inv) % BASE
    carry = floor((t[1] + m * n[1]) / BASE)
    for j = 2, k do
      local w = t[j] + m * n[j] + carry
      carry = floor(w / BASE)
      t[j - 1] = w - carry * BASE
    end
    v = t[k + 1] + carry
    t[k] = v % BASE
    t[k + 1] = t[k + 2] + floor(v / BASE)
    t[k + 2] = 0
  end
  t[k + 2] = nil
  norm(t)
  if M.cmp(t, n) >= 0 then
    t = M.sub(t, n)
  end
  return t
end

---base^exp mod n (n odd).
function M.modexp(base, exp, n)
  local ctx = context(n)
  if M.cmp(base, n) >= 0 then
    base = mod_slow(base, n)
  end
  local xm = mont_mul(ctx, base, ctx.r2)
  local acc = mont_mul(ctx, { 1 }, ctx.r2)
  for bit_i = M.bitlen(exp) - 1, 0, -1 do
    checkpoint()
    acc = mont_mul(ctx, acc, acc)
    if floor(exp[floor(bit_i / BITS) + 1] / 2 ^ (bit_i % BITS)) % 2 == 1 then
      acc = mont_mul(ctx, acc, xm)
    end
  end
  return mont_mul(ctx, acc, { 1 })
end

---a + b.
function M.add(a, b)
  local r, carry = {}, 0
  for i = 1, math.max(#a, #b) do
    local v = (a[i] or 0) + (b[i] or 0) + carry
    if v >= BASE then
      r[i], carry = v - BASE, 1
    else
      r[i], carry = v, 0
    end
  end
  if carry > 0 then
    r[#r + 1] = carry
  end
  return r
end

function M.is_zero(a)
  return #a == 1 and a[1] == 0
end

---Arithmetic modulo an odd prime in Montgomery form (used for elliptic curves).
---@class dbdash.bignum.Field
---@field p integer[] the modulus
---@field ctx table its Montgomery context
---@field one integer[] 1 in Montgomery form
---@field zero integer[]
local Field = {}
Field.__index = Field

function M.field(p)
  local f = setmetatable({ ctx = context(p), p = p }, Field)
  f.one = f:to({ 1 })
  f.zero = { 0 }
  return f
end

function Field:to(a)
  if M.cmp(a, self.p) >= 0 then
    a = mod_slow(a, self.p)
  end
  return mont_mul(self.ctx, a, self.ctx.r2)
end

function Field:from(a)
  return mont_mul(self.ctx, a, { 1 })
end

function Field:mul(a, b)
  return mont_mul(self.ctx, a, b)
end

function Field:add(a, b)
  local r = M.add(a, b)
  if M.cmp(r, self.p) >= 0 then
    r = M.sub(r, self.p)
  end
  return r
end

function Field:sub(a, b)
  if M.cmp(a, b) >= 0 then
    return M.sub(a, b)
  end
  return M.sub(M.add(a, self.p), b)
end

---a^e (a in Montgomery form, e a plain bignum).
function Field:pow(a, e)
  local acc = self.one
  for bit_i = M.bitlen(e) - 1, 0, -1 do
    checkpoint()
    acc = mont_mul(self.ctx, acc, acc)
    if floor(e[floor(bit_i / BITS) + 1] / 2 ^ (bit_i % BITS)) % 2 == 1 then
      acc = mont_mul(self.ctx, acc, a)
    end
  end
  return acc
end

---Inverse by Fermat's little theorem (p prime).
function Field:inv(a)
  return self:pow(a, M.sub(self.p, { 2 }))
end

---Hex string helpers for tests and debugging.
function M.from_hex(h)
  if #h % 2 == 1 then
    h = "0" .. h
  end
  return M.from_bytes((h:gsub("%x%x", function(x)
    return string.char(tonumber(x, 16))
  end)))
end

function M.to_hex(a)
  local s = M.to_bytes(a)
    :gsub(".", function(c)
      return ("%02x"):format(c:byte())
    end)
    :gsub("^0+", "")
  return s == "" and "0" or s
end

return M
