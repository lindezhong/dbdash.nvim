-- NIST curves P-256 and P-384 (FIPS 186-4, a = -3): ECDSA verification for TLS and
-- certificates, and ECDH for key shares. Jacobian coordinates over a Montgomery field;
-- u1*G + u2*Q with Shamir's trick. Not constant-time (accepted risk, see :h dbdash-tls).
local checkpoint = require("dbdash.util.async").checkpoint -- yields inside tasks only
local bn = require("dbdash.crypto.bignum")
local asn1 = require("dbdash.crypto.asn1")

local M = {}

---@class dbdash.ecdsa.Curve
---@field name string
---@field size integer field element size in bytes
---@field bits integer order size in bits
---@field P integer[] the field's prime
---@field N integer[] the group's order
---@field F dbdash.bignum.Field arithmetic modulo P
---@field FN dbdash.bignum.Field arithmetic modulo N
---@field GX integer[] the generator
---@field GY integer[]
local Curve = {}
Curve.__index = Curve

local function curve(name, size, p, n, b, gx, gy)
  local P, N = bn.from_hex(p), bn.from_hex(n)
  return setmetatable({
    name = name,
    size = size,
    bits = size * 8,
    P = P,
    N = N,
    B = bn.from_hex(b),
    GX = bn.from_hex(gx),
    GY = bn.from_hex(gy),
    F = bn.field(P),
    FN = bn.field(N),
  }, Curve)
end

M.curves = {
  p256 = curve(
    "P-256",
    32,
    "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
    "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
    "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b",
    "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296",
    "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
  ),
  p384 = curve(
    "P-384",
    48,
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff",
    "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973",
    "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
    "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7",
    "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f"
  ),
}

-- Curve OIDs used in certificates.
M.by_oid = {
  ["1.2.840.10045.3.1.7"] = M.curves.p256,
  ["1.3.132.0.34"] = M.curves.p384,
}

local function dbl(F, pt)
  local X, Y, Z = pt[1], pt[2], pt[3]
  if bn.is_zero(Z) then
    return pt
  end
  local delta = F:mul(Z, Z)
  local gamma = F:mul(Y, Y)
  local beta = F:mul(X, gamma)
  local t = F:mul(F:sub(X, delta), F:add(X, delta))
  local alpha = F:add(F:add(t, t), t)
  local beta4 = F:add(F:add(beta, beta), F:add(beta, beta))
  local beta8 = F:add(beta4, beta4)
  local X3 = F:sub(F:mul(alpha, alpha), beta8)
  local yz = F:add(Y, Z)
  local Z3 = F:sub(F:sub(F:mul(yz, yz), gamma), delta)
  local g2 = F:mul(gamma, gamma)
  local g8 = F:add(F:add(F:add(g2, g2), F:add(g2, g2)), F:add(F:add(g2, g2), F:add(g2, g2)))
  local Y3 = F:sub(F:mul(alpha, F:sub(beta4, X3)), g8)
  return { X3, Y3, Z3 }
end

local function add(F, p1, p2)
  if bn.is_zero(p1[3]) then
    return p2
  elseif bn.is_zero(p2[3]) then
    return p1
  end
  local X1, Y1, Z1, X2, Y2, Z2 = p1[1], p1[2], p1[3], p2[1], p2[2], p2[3]
  local Z1Z1 = F:mul(Z1, Z1)
  local Z2Z2 = F:mul(Z2, Z2)
  local U1 = F:mul(X1, Z2Z2)
  local U2 = F:mul(X2, Z1Z1)
  local S1 = F:mul(F:mul(Y1, Z2), Z2Z2)
  local S2 = F:mul(F:mul(Y2, Z1), Z1Z1)
  local H = F:sub(U2, U1)
  local r = F:sub(S2, S1)
  if bn.is_zero(H) then
    if bn.is_zero(r) then
      return dbl(F, p1)
    end
    return { F.one, F.one, F.zero } -- point at infinity
  end
  r = F:add(r, r)
  local H2 = F:add(H, H)
  local I = F:mul(H2, H2)
  local J = F:mul(H, I)
  local V = F:mul(U1, I)
  local X3 = F:sub(F:sub(F:mul(r, r), J), F:add(V, V))
  local S1J = F:mul(S1, J)
  local Y3 = F:sub(F:mul(r, F:sub(V, X3)), F:add(S1J, S1J))
  local z = F:add(Z1, Z2)
  local Z3 = F:mul(F:sub(F:sub(F:mul(z, z), Z1Z1), Z2Z2), H)
  return { X3, Y3, Z3 }
end

local function bit_of(k, i)
  return math.floor(k[math.floor(i / 24) + 1] / 2 ^ (i % 24)) % 2
end

---Is (x, y) (plain bignums) on the curve y^2 = x^3 - 3x + b?
local function on_curve(C, x, y)
  local F = C.F
  local X, Y = F:to(x), F:to(y)
  local lhs = F:mul(Y, Y)
  local x3 = F:mul(F:mul(X, X), X)
  local three_x = F:add(F:add(X, X), X)
  local rhs = F:add(F:sub(x3, three_x), F:to(C.B))
  return bn.cmp(lhs, rhs) == 0
end

---Parse an uncompressed public point (04 || X || Y).
---@return { x: integer[], y: integer[], curve: string }? key, string? err
function Curve:public_key(point)
  local n = self.size
  if #point ~= 2 * n + 1 or point:byte(1) ~= 4 then
    return nil, ("only uncompressed %s points are supported"):format(self.name)
  end
  local x, y = bn.from_bytes(point:sub(2, n + 1)), bn.from_bytes(point:sub(n + 2, 2 * n + 1))
  if bn.cmp(x, self.P) >= 0 or bn.cmp(y, self.P) >= 0 or not on_curve(self, x, y) then
    return nil, ("public key is not on the %s curve"):format(self.name)
  end
  return { x = x, y = y, curve = self.name }
end

---Verify a DER-encoded ECDSA signature over a message digest.
---@param key { x: table, y: table }
---@param digest string hash of the message (truncated to the curve size if longer)
---@param sig_der string
---@return boolean
function Curve:verify(key, digest, sig_der)
  local F, FN, N = self.F, self.FN, self.N
  local ok, seq = pcall(asn1.parse, sig_der)
  if not ok or not seq.children or #seq.children ~= 2 then
    return false
  end
  local r = bn.from_bytes(asn1.unsigned(seq.children[1]))
  local s = bn.from_bytes(asn1.unsigned(seq.children[2]))
  if bn.is_zero(r) or bn.is_zero(s) or bn.cmp(r, N) >= 0 or bn.cmp(s, N) >= 0 then
    return false
  end
  local e = bn.from_bytes(digest:sub(1, self.size))
  local w = FN:inv(FN:to(s))
  local u1 = FN:from(FN:mul(FN:to(e), w))
  local u2 = FN:from(FN:mul(FN:to(r), w))
  local G = { F:to(self.GX), F:to(self.GY), F.one }
  local Q = { F:to(key.x), F:to(key.y), F.one }
  local GQ = add(F, G, Q)
  local acc = { F.one, F.one, F.zero }
  for i = self.bits - 1, 0, -1 do
    checkpoint()
    acc = dbl(F, acc)
    local a, b = bit_of(u1, i), bit_of(u2, i)
    if a == 1 and b == 1 then
      acc = add(F, acc, GQ)
    elseif a == 1 then
      acc = add(F, acc, G)
    elseif b == 1 then
      acc = add(F, acc, Q)
    end
  end
  if bn.is_zero(acc[3]) then
    return false
  end
  local zinv = F:inv(acc[3])
  local x = F:from(F:mul(acc[1], F:mul(zinv, zinv)))
  if bn.cmp(x, N) >= 0 then
    x = bn.sub(x, N)
  end
  return bn.cmp(x, r) == 0
end

---k * point (point in Jacobian Montgomery form, k a plain bignum).
local function scalar_mul(F, k, pt)
  local acc = { F.one, F.one, F.zero }
  for i = bn.bitlen(k) - 1, 0, -1 do
    checkpoint()
    acc = dbl(F, acc)
    if bit_of(k, i) == 1 then
      acc = add(F, acc, pt)
    end
  end
  return acc
end

local function affine(F, pt)
  local zinv = F:inv(pt[3])
  local z2 = F:mul(zinv, zinv)
  return F:from(F:mul(pt[1], z2)), F:from(F:mul(pt[2], F:mul(z2, zinv)))
end

---New ECDH key pair: private scalar and uncompressed public point.
function Curve:ecdh_keypair()
  local F, n = self.F, self.size
  local rand = require("dbdash.crypto.random")
  local d
  repeat
    d = bn.from_bytes(rand.bytes(n))
  until not bn.is_zero(d) and bn.cmp(d, self.N) < 0
  local x, y = affine(F, scalar_mul(F, d, { F:to(self.GX), F:to(self.GY), F.one }))
  return bn.to_bytes(d, n), "\4" .. bn.to_bytes(x, n) .. bn.to_bytes(y, n)
end

---Shared secret: x coordinate of priv * peer. Validates the peer point.
function Curve:ecdh(priv, peer)
  local F = self.F
  local key, err = self:public_key(peer)
  key = key
    or require("dbdash.util.error").raise(
      "tls",
      ("invalid %s key share: %s"):format(self.name, err)
    )
  local pt = scalar_mul(F, bn.from_bytes(priv), { F:to(key.x), F:to(key.y), F.one })
  if bn.is_zero(pt[3]) then
    require("dbdash.util.error").raise("tls", ("invalid %s shared secret"):format(self.name))
  end
  local x = affine(F, pt)
  return bn.to_bytes(x, self.size)
end

return M
