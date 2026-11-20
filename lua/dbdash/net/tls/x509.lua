-- Minimal X.509 parsing: the subject public key and a readable subject (design §9.2).
-- Certificate chains are not validated (tls=pin compares the leaf fingerprint).
local asn1 = require("dbdash.net.tls.asn1")

local M = {}

local OID = {
  rsa = "1.2.840.113549.1.1.1",
  ec = "1.2.840.10045.2.1",
  p256 = "1.2.840.10045.3.1.7",
  cn = "2.5.4.3",
}

local function fail(msg)
  error({ phase = "tls", message = "certificate: " .. msg }, 0)
end

---@class dbdash.x509.Cert
---@field der string
---@field subject string
---@field key_type "rsa"|"ec"
---@field rsa dbdash.rsa.PublicKey?
---@field ec { x: table, y: table }?

---@param der string
---@return dbdash.x509.Cert
function M.parse(der)
  local ok, cert = pcall(asn1.parse, der)
  if not ok or not cert.children or #cert.children < 3 then
    fail("malformed DER")
  end
  local tbs = cert.children[1]
  local i = (tbs.children[1].tag == 0xa0) and 2 or 1
  local subject_node = tbs.children[i + 4]
  local spki = tbs.children[i + 5]
  if not spki or not spki.children then
    fail("missing subject public key")
  end
  local subject = "?"
  for _, rdn in ipairs(subject_node.children or {}) do
    for _, atv in ipairs(rdn.children or {}) do
      if atv.children and asn1.oid(atv.children[1]) == OID.cn then
        subject = atv.children[2].value
      end
    end
  end
  local alg = asn1.oid(spki.children[1].children[1])
  local out = { der = der, subject = subject }
  if alg == OID.rsa then
    out.key_type = "rsa"
    out.rsa = require("dbdash.crypto.rsa").from_spki(spki)
  elseif alg == OID.ec then
    local curve = spki.children[1].children[2]
    if not curve or asn1.oid(curve) ~= OID.p256 then
      fail("only P-256 EC keys are supported")
    end
    out.key_type = "ec"
    local key, err = require("dbdash.crypto.ecdsa_p256").public_key(asn1.bits(spki.children[2]))
    if not key then
      fail(err)
    end
    out.ec = key
  else
    fail("unsupported public key algorithm " .. alg)
  end
  return out
end

---SHA-256 fingerprint as "sha256:AB:CD:...".
function M.fingerprint(der)
  local h = require("dbdash.crypto.sha256").digest(der)
  local parts = {}
  for k = 1, #h do
    parts[k] = ("%02X"):format(h:byte(k))
  end
  return "sha256:" .. table.concat(parts, ":")
end

return M
