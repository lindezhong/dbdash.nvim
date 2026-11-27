-- RSA public-key operations: OAEP encryption (MySQL caching_sha2 full authentication)
-- and signature verification helpers used by TLS (M4).
local asn1 = require("dbdash.crypto.asn1")
local bit = require("bit")
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
    require("dbdash.util.error").raise("auth", "not an RSA public key (algorithm " .. alg .. ")")
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
    require("dbdash.util.error").raise("auth", "message too long for RSA-OAEP")
  end
  local db = hash.digest("") .. string.rep("\0", k - #msg - 2 * h - 2) .. "\1" .. msg
  seed = seed or require("dbdash.crypto.random").bytes(h)
  local masked_db = util.xor(db, M.mgf1(hash, seed, k - h - 1))
  local masked_seed = util.xor(seed, M.mgf1(hash, masked_db, h))
  return M.public(key, "\0" .. masked_seed .. masked_db)
end

-- DigestInfo prefixes (RFC 8017 §9.2 note 1).
local DIGEST_INFO = {
  sha1 = "3021300906052b0e03021a05000414",
  sha256 = "3031300d060960864801650304020105000420",
  sha384 = "3041300d060960864801650304020205000430",
  sha512 = "3051300d060960864801650304020305000440",
}

---RSASSA-PKCS1-v1_5 verification (RFC 8017 §8.2.2).
---@param key dbdash.rsa.PublicKey
---@param hash table hash module (name: sha1/sha256/sha384/sha512)
---@param msg string the signed message (hashed here)
---@param sig string
---@return boolean
function M.pkcs1_verify(key, hash, msg, sig)
  if #sig ~= key.size then
    return false
  end
  local s = bn.from_bytes(sig)
  if bn.cmp(s, key.n) >= 0 then
    return false
  end
  local prefix = DIGEST_INFO[hash.name]
  if not prefix then
    return false
  end
  local t = util.unhex(prefix) .. hash.digest(msg)
  if key.size < #t + 11 then
    return false
  end
  local expected = "\0\1" .. string.rep("\255", key.size - #t - 3) .. "\0" .. t
  local em = bn.to_bytes(bn.modexp(s, key.e, key.n), key.size)
  return util.equal(em, expected)
end

---RSAES-PKCS1-v1_5 encryption (RFC 8017 §7.2.1), for the TLS 1.2 RSA key exchange.
function M.pkcs1_encrypt(key, msg)
  local k = key.size
  if #msg > k - 11 then
    require("dbdash.util.error").raise("tls", "message too long for RSA PKCS#1 v1.5")
  end
  local rand = require("dbdash.crypto.random")
  local ps = {}
  while #ps < k - #msg - 3 do
    for c in rand.bytes(k):gmatch(".") do
      if c ~= "\0" and #ps < k - #msg - 3 then
        ps[#ps + 1] = c
      end
    end
  end
  return M.public(key, "\0\2" .. table.concat(ps) .. "\0" .. msg)
end

---RSASSA-PSS verification (RFC 8017 §8.1.2) with MGF1 over the same hash and a salt as
---long as the hash, as TLS 1.3 requires.
---@param key dbdash.rsa.PublicKey
---@param hash table hash module
---@param msg string the signed message (hashed here)
---@param sig string
---@return boolean
function M.pss_verify(key, hash, msg, sig)
  if #sig ~= key.size then
    return false
  end
  local s = bn.from_bytes(sig)
  if bn.cmp(s, key.n) >= 0 then
    return false
  end
  local mod_bits = bn.bitlen(key.n)
  local em_bits = mod_bits - 1
  local em_len = math.ceil(em_bits / 8)
  local em = bn.to_bytes(bn.modexp(s, key.e, key.n), key.size):sub(-em_len)
  local h_len = hash.size
  if em_len < 2 * h_len + 2 or em:byte(-1) ~= 0xbc then
    return false
  end
  local masked_db = em:sub(1, em_len - h_len - 1)
  local h = em:sub(em_len - h_len, em_len - 1)
  local top_bits = 8 * em_len - em_bits
  local top_mask = 256 - 2 ^ (8 - top_bits)
  if top_bits > 0 and bit.band(masked_db:byte(1), top_mask) ~= 0 then
    return false
  end
  local db = util.xor(masked_db, M.mgf1(hash, h, #masked_db))
  if top_bits > 0 then
    db = string.char(bit.band(db:byte(1), 255 - top_mask)) .. db:sub(2)
  end
  local ps_len = em_len - 2 * h_len - 2
  if db:sub(1, ps_len) ~= string.rep("\0", ps_len) or db:byte(ps_len + 1) ~= 1 then
    return false
  end
  local salt = db:sub(ps_len + 2)
  local h2 = hash.digest(string.rep("\0", 8) .. hash.digest(msg) .. salt)
  return util.equal(h, h2)
end

return M
