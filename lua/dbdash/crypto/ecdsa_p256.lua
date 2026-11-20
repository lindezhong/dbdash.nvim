-- ECDSA signature verification on NIST P-256 (FIPS 186-4), for TLS CertificateVerify.
-- Jacobian coordinates over a Montgomery field; u1*G + u2*Q with Shamir's trick.
local bn = require("dbdash.crypto.bignum")
local asn1 = require("dbdash.net.tls.asn1")

local M = {}

local P = bn.from_hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")
local N = bn.from_hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
local B = bn.from_hex("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b")
local GX = bn.from_hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")
local GY = bn.from_hex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")

local F = bn.field(P)
local FN = bn.field(N)

local function dbl(pt)
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

local function add(p1, p2)
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
      return dbl(p1)
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
local function on_curve(x, y)
  local X, Y = F:to(x), F:to(y)
  local lhs = F:mul(Y, Y)
  local x3 = F:mul(F:mul(X, X), X)
  local three_x = F:add(F:add(X, X), X)
  local rhs = F:add(F:sub(x3, three_x), F:to(B))
  return bn.cmp(lhs, rhs) == 0
end

---Parse an uncompressed public point (04 || X || Y).
function M.public_key(point)
  if #point ~= 65 or point:byte(1) ~= 4 then
    return nil, "only uncompressed P-256 points are supported"
  end
  local x, y = bn.from_bytes(point:sub(2, 33)), bn.from_bytes(point:sub(34, 65))
  if bn.cmp(x, P) >= 0 or bn.cmp(y, P) >= 0 or not on_curve(x, y) then
    return nil, "public key is not on the P-256 curve"
  end
  return { x = x, y = y }
end

---Verify a DER-encoded ECDSA signature over a message digest.
---@param key { x: table, y: table }
---@param digest string hash of the message (truncated to 256 bits if longer)
---@param sig_der string
---@return boolean
function M.verify(key, digest, sig_der)
  local ok, seq = pcall(asn1.parse, sig_der)
  if not ok or not seq.children or #seq.children ~= 2 then
    return false
  end
  local r = bn.from_bytes(asn1.unsigned(seq.children[1]))
  local s = bn.from_bytes(asn1.unsigned(seq.children[2]))
  if bn.is_zero(r) or bn.is_zero(s) or bn.cmp(r, N) >= 0 or bn.cmp(s, N) >= 0 then
    return false
  end
  local e = bn.from_bytes(digest:sub(1, 32))
  local w = FN:inv(FN:to(s))
  local u1 = FN:from(FN:mul(FN:to(e), w))
  local u2 = FN:from(FN:mul(FN:to(r), w))
  local G = { F:to(GX), F:to(GY), F.one }
  local Q = { F:to(key.x), F:to(key.y), F.one }
  local GQ = add(G, Q)
  local acc = { F.one, F.one, F.zero }
  for i = 255, 0, -1 do
    acc = dbl(acc)
    local a, b = bit_of(u1, i), bit_of(u2, i)
    if a == 1 and b == 1 then
      acc = add(acc, GQ)
    elseif a == 1 then
      acc = add(acc, G)
    elseif b == 1 then
      acc = add(acc, Q)
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

return M
