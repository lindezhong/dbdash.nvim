-- RSA public-key operations: OAEP encryption (MySQL caching_sha2 full authentication)
-- and signature verification helpers used by TLS (M4).
local asn1 = require("dbdash.net.tls.asn1")
local bn = require("dbdash.crypto.bignum")
local util = require("dbdash.crypto.util")

local M = {}

---@class dbdash.rsa.PublicKey
---@field n table bignum modulus
---@field e table bignum exponent
---@field size integer modulus length in bytes

local function key_from(n_bytes, e_bytes)
  local n = bn.from_bytes(n_bytes)
  return { n = n, e = bn.from_bytes(e_bytes), size = math.ceil(bn.bitlen(n) / 8) }
end

---From a PKCS#1 RSAPublicKey (SEQUENCE { n, e }) DER.
function M.from_pkcs1(der)
  local seq = asn1.parse(der)
  return key_from(asn1.unsigned(seq.children[1]), asn1.unsigned(seq.children[2]))
end

---From a SubjectPublicKeyInfo DER (rsaEncryption).
function M.from_spki(der)
  local spki = type(der) == "table" and der or asn1.parse(der)
  local alg = asn1.oid(spki.children[1].children[1])
  if alg ~= "1.2.840.113549.1.1.1" then
    error({ phase = "auth", message = "not an RSA public key (algorithm " .. alg .. ")" }, 0)
  end
  return M.from_pkcs1(asn1.bits(spki.children[2]))
end

---From PEM text ("PUBLIC KEY" or "RSA PUBLIC KEY").
function M.from_pem(pem)
  if pem:find("BEGIN RSA PUBLIC KEY", 1, true) then
    return M.from_pkcs1(asn1.pem(pem, "RSA PUBLIC KEY"))
  end
  return M.from_spki(asn1.pem(pem, "PUBLIC KEY"))
end

---Raw RSA public operation m^e mod n on a `size`-byte block.
function M.public(key, block)
  return bn.to_bytes(bn.modexp(bn.from_bytes(block), key.e, key.n), key.size)
end

---MGF1 mask generation.
function M.mgf1(hash, seed, len)
  local out, counter = {}, 0
  local have = 0
  while have < len do
    local c = hash.digest(seed .. util.be32(counter))
    out[#out + 1] = c
    have = have + #c
    counter = counter + 1
  end
  return table.concat(out):sub(1, len)
end

---RSAES-OAEP encryption (RFC 8017 §7.1.1) with an empty label.
---@param key dbdash.rsa.PublicKey
---@param msg string
---@param hash table? hash module (default SHA-1, as OpenSSL's RSA_PKCS1_OAEP_PADDING)
---@param seed string? fixed seed (tests only)
function M.oaep_encrypt(key, msg, hash, seed)
  hash = hash or require("dbdash.crypto.sha1")
  local k, h = key.size, hash.size
  if #msg > k - 2 * h - 2 then
    error({ phase = "auth", message = "message too long for RSA-OAEP" }, 0)
  end
  local db = hash.digest("") .. string.rep("\0", k - #msg - 2 * h - 2) .. "\1" .. msg
  seed = seed or require("dbdash.crypto.random").bytes(h)
  local masked_db = util.xor(db, M.mgf1(hash, seed, k - h - 1))
  local masked_seed = util.xor(seed, M.mgf1(hash, masked_db, h))
  return M.public(key, "\0" .. masked_seed .. masked_db)
end

return M
