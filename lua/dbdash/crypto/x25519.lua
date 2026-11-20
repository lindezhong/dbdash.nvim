-- X25519 (RFC 7748), after TweetNaCl: field elements are 16 limbs of 16 bits held in Lua
-- numbers (all intermediate sums stay below 2^53).
local M = {}

local floor = math.floor

local function gf(init)
  local o = {}
  for i = 1, 16 do
    o[i] = init and init[i] or 0
  end
  return o
end

local function car(o)
  for i = 1, 16 do
    local c = floor(o[i] / 65536)
    o[i] = o[i] - c * 65536
    if i < 16 then
      o[i + 1] = o[i + 1] + c
    else
      o[1] = o[1] + 38 * c
    end
  end
end

local function sel(p, q, b)
  if b == 1 then
    for i = 1, 16 do
      p[i], q[i] = q[i], p[i]
    end
  end
end

local function A(o, a, b)
  for i = 1, 16 do
    o[i] = a[i] + b[i]
  end
end

local function Z(o, a, b)
  for i = 1, 16 do
    o[i] = a[i] - b[i]
  end
end

local t = {}
local function Mul(o, a, b)
  for i = 1, 31 do
    t[i] = 0
  end
  for i = 1, 16 do
    local ai = a[i]
    for j = 1, 16 do
      t[i + j - 1] = t[i + j - 1] + ai * b[j]
    end
  end
  for i = 1, 15 do
    t[i] = t[i] + 38 * t[i + 16]
  end
  for i = 1, 16 do
    o[i] = t[i]
  end
  car(o)
  car(o)
end

local function S(o, a)
  Mul(o, a, a)
end

local function inv(o, i)
  local c = gf(i)
  for a = 253, 0, -1 do
    S(c, c)
    if a ~= 2 and a ~= 4 then
      Mul(c, c, i)
    end
  end
  for k = 1, 16 do
    o[k] = c[k]
  end
end

local function pack(n)
  local tt = gf(n)
  car(tt)
  car(tt)
  car(tt)
  local m = gf()
  for _ = 1, 2 do
    m[1] = tt[1] - 0xffed
    for i = 2, 15 do
      local borrow = m[i - 1] < 0 and 1 or 0
      m[i] = tt[i] - 0xffff - borrow
      m[i - 1] = m[i - 1] % 65536
    end
    local borrow = m[15] < 0 and 1 or 0
    m[16] = tt[16] - 0x7fff - borrow
    local b = m[16] < 0 and 1 or 0
    m[15] = m[15] % 65536
    sel(tt, m, 1 - b)
  end
  local out = {}
  for i = 1, 16 do
    out[2 * i - 1] = string.char(tt[i] % 256)
    out[2 * i] = string.char(floor(tt[i] / 256) % 256)
  end
  return table.concat(out)
end

local function unpack(s)
  local o = gf()
  for i = 1, 16 do
    o[i] = s:byte(2 * i - 1) + s:byte(2 * i) * 256
  end
  o[16] = o[16] % 32768
  return o
end

local _121665 = gf({ 0xdb41, 1 })

---X25519(k, u): scalar multiplication on Curve25519 (both 32-byte strings).
function M.scalarmult(k, u)
  assert(#k == 32 and #u == 32, "x25519 inputs must be 32 bytes")
  local z = { k:byte(1, 32) }
  z[32] = z[32] % 64 + 64 -- clear bit 7, set bit 6
  z[1] = z[1] - z[1] % 8
  local x = unpack(u)
  local a, b, c, d, e, f = gf(), gf(x), gf(), gf(), gf(), gf()
  a[1], d[1] = 1, 1
  for i = 254, 0, -1 do
    local r = floor(z[floor(i / 8) + 1] / 2 ^ (i % 8)) % 2
    sel(a, b, r)
    sel(c, d, r)
    A(e, a, c)
    Z(a, a, c)
    A(c, b, d)
    Z(b, b, d)
    S(d, e)
    S(f, a)
    Mul(a, c, a)
    Mul(c, b, e)
    A(e, a, c)
    Z(a, a, c)
    S(b, a)
    Z(c, d, f)
    Mul(a, c, _121665)
    A(a, a, d)
    Mul(c, c, a)
    Mul(a, d, f)
    Mul(d, b, x)
    S(b, e)
    sel(a, b, r)
    sel(c, d, r)
  end
  inv(c, c)
  Mul(a, a, c)
  return pack(a)
end

local BASE = "\9" .. string.rep("\0", 31)

---Public key for a private scalar.
function M.public(k)
  return M.scalarmult(k, BASE)
end

---New key pair: private, public.
function M.keypair()
  local k = require("dbdash.crypto.random").bytes(32)
  return k, M.public(k)
end

return M
