-- X.509 certificate parsing (design §9.2): public key, names, validity, signature and the
-- extensions needed for chain validation (basicConstraints, keyUsage, extKeyUsage,
-- subjectAltName, key identifiers). Unknown critical extensions are recorded so the
-- verifier can reject them.
local asn1 = require("dbdash.net.tls.asn1")
local bit = require("bit")

local M = {}

local OID = {
  rsa = "1.2.840.113549.1.1.1",
  rsa_pss = "1.2.840.113549.1.1.10",
  ec = "1.2.840.10045.2.1",
  cn = "2.5.4.3",
  basic_constraints = "2.5.29.19",
  key_usage = "2.5.29.15",
  ext_key_usage = "2.5.29.37",
  san = "2.5.29.17",
  ski = "2.5.29.14",
  aki = "2.5.29.35",
  server_auth = "1.3.6.1.5.5.7.3.1",
  any_eku = "2.5.29.37.0",
}
M.OID = OID

-- Signature algorithms: OID -> { kind, hash name }.
local SIG_ALGS = {
  ["1.2.840.113549.1.1.5"] = { "rsa_pkcs1", "sha1" },
  ["1.2.840.113549.1.1.11"] = { "rsa_pkcs1", "sha256" },
  ["1.2.840.113549.1.1.12"] = { "rsa_pkcs1", "sha384" },
  ["1.2.840.113549.1.1.13"] = { "rsa_pkcs1", "sha512" },
  ["1.2.840.10045.4.3.2"] = { "ecdsa", "sha256" },
  ["1.2.840.10045.4.3.3"] = { "ecdsa", "sha384" },
  ["1.2.840.10045.4.3.4"] = { "ecdsa", "sha512" },
}
local HASH_OIDS = {
  ["1.3.14.3.2.26"] = "sha1",
  ["2.16.840.1.101.3.4.2.1"] = "sha256",
  ["2.16.840.1.101.3.4.2.2"] = "sha384",
  ["2.16.840.1.101.3.4.2.3"] = "sha512",
}

-- Extensions we understand (critical or not).
local KNOWN = {
  [OID.basic_constraints] = true,
  [OID.key_usage] = true,
  [OID.ext_key_usage] = true,
  [OID.san] = true,
  [OID.ski] = true,
  [OID.aki] = true,
  ["2.5.29.32"] = true, -- certificatePolicies
  ["2.5.29.31"] = true, -- CRL distribution points
  ["1.3.6.1.5.5.7.1.1"] = true, -- authority information access
  ["1.3.6.1.4.1.11129.2.4.2"] = true, -- embedded SCTs
}

local function fail(msg)
  error({ phase = "tls", message = "certificate: " .. msg }, 0)
end

---Seconds since the epoch from UTCTime / GeneralizedTime.
function M.parse_time(node)
  local v = node.value
  local y, rest
  if node.tag == 0x17 then
    y, rest = tonumber(v:sub(1, 2)), v:sub(3)
    y = y < 50 and 2000 + y or 1900 + y
  elseif node.tag == 0x18 then
    y, rest = tonumber(v:sub(1, 4)), v:sub(5)
  else
    fail("unexpected time encoding")
  end
  local mo, d, h, mi, s = rest:match("^(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)")
  if not mo then
    fail("unsupported time format " .. v)
  end
  local iso = ("%04d-%s-%sT%s:%s:%sZ"):format(y, mo, d, h, mi, s)
  return math.floor(require("dbdash.db.bson").iso_to_ms(iso) / 1000)
end

---Common name from a Name, or nil.
local function common_name(name)
  local cn
  for _, rdn in ipairs(name.children or {}) do
    for _, atv in ipairs(rdn.children or {}) do
      if atv.children and asn1.oid(atv.children[1]) == OID.cn then
        cn = atv.children[2].value
      end
    end
  end
  return cn
end

local function parse_key(spki)
  local alg = asn1.oid(spki.children[1].children[1])
  if alg == OID.rsa then
    return "rsa", require("dbdash.crypto.rsa").from_spki(spki)
  elseif alg == OID.ec then
    local param = spki.children[1].children[2]
    local curve = param and param.tag == asn1.TAG.OID and require("dbdash.crypto.ecdsa").by_oid[asn1.oid(param)]
    if not curve then
      return "unsupported", nil, "only P-256 and P-384 EC keys are supported"
    end
    local key, err = curve:public_key(asn1.bits(spki.children[2]))
    if not key then
      fail(err)
    end
    return "ec", key
  end
  return "unsupported", nil, "unsupported public key algorithm " .. alg
end

local function parse_sig_alg(node)
  local oid = asn1.oid(node.children[1])
  if oid == OID.rsa_pss then
    -- RSASSA-PSS-params: [0] hashAlgorithm (default SHA-1)
    local hash = "sha1"
    local params = node.children[2]
    for _, c in ipairs(params and params.children or {}) do
      if c.tag == 0xa0 then
        hash = HASH_OIDS[asn1.oid(c.children[1].children[1])] or "unknown"
      end
    end
    return { kind = "rsa_pss", hash = hash, oid = oid }
  end
  local a = SIG_ALGS[oid]
  if not a then
    return { kind = "unsupported", oid = oid }
  end
  return { kind = a[1], hash = a[2], oid = oid }
end

local function parse_extensions(cert, node)
  for _, ext in ipairs(node.children[1].children or {}) do
    local oid = asn1.oid(ext.children[1])
    local critical, value = false, nil
    for k = 2, #ext.children do
      local c = ext.children[k]
      if c.tag == 0x01 then
        critical = c.value:byte(1) ~= 0
      elseif c.tag == asn1.TAG.OCTET_STRING then
        value = c.value
      end
    end
    if critical and not KNOWN[oid] then
      cert.unknown_critical[#cert.unknown_critical + 1] = oid
    end
    if value then
      local inner = asn1.parse(value)
      if oid == OID.basic_constraints then
        for _, c in ipairs(inner.children or {}) do
          if c.tag == 0x01 then
            cert.ca = c.value:byte(1) ~= 0
          elseif c.tag == asn1.TAG.INTEGER then
            local n = 0
            for k = 1, #c.value do
              n = n * 256 + c.value:byte(k)
            end
            cert.path_len = n
          end
        end
      elseif oid == OID.key_usage then
        local bits = inner.value:sub(2)
        local b0 = bits:byte(1) or 0
        cert.key_usage = {
          digital_signature = bit.band(b0, 0x80) ~= 0,
          key_cert_sign = bit.band(b0, 0x04) ~= 0,
        }
      elseif oid == OID.ext_key_usage then
        cert.ext_key_usage = {}
        for _, c in ipairs(inner.children or {}) do
          cert.ext_key_usage[asn1.oid(c)] = true
        end
      elseif oid == OID.san then
        cert.san = { dns = {}, ip = {} }
        for _, g in ipairs(inner.children or {}) do
          if g.tag == 0x82 then
            table.insert(cert.san.dns, g.value)
          elseif g.tag == 0x87 then
            table.insert(cert.san.ip, g.value)
          end
        end
      elseif oid == OID.ski then
        cert.ski = inner.value
      elseif oid == OID.aki then
        for _, c in ipairs(inner.children or {}) do
          if c.tag == 0x80 then
            cert.aki = c.value
          end
        end
      end
    end
  end
end

---@class dbdash.x509.Cert
---@field der string
---@field tbs string DER of tbsCertificate (the signed bytes)
---@field subject string common name (for messages)
---@field subject_der string
---@field issuer_der string
---@field not_before integer epoch seconds
---@field not_after integer
---@field sig_alg { kind: string, hash: string? }
---@field signature string
---@field key_type "rsa"|"ec"|"unsupported"
---@field rsa dbdash.rsa.PublicKey?
---@field ec table?
---@field ca boolean
---@field path_len integer?
---@field key_usage table?
---@field ext_key_usage table<string, boolean>?
---@field san { dns: string[], ip: string[] }?
---@field ski string?
---@field aki string?
---@field unknown_critical string[]

---@param der string
---@return dbdash.x509.Cert
function M.parse(der)
  local ok, cert = pcall(asn1.parse, der)
  if not ok or not cert.children or #cert.children < 3 then
    fail("malformed DER")
  end
  local tbs = cert.children[1]
  local i = (tbs.children[1].tag == 0xa0) and 2 or 1
  local issuer, validity, subject, spki = tbs.children[i + 2], tbs.children[i + 3], tbs.children[i + 4], tbs.children[i + 5]
  if not spki or not spki.children then
    fail("missing subject public key")
  end
  local out = {
    der = der,
    tbs = tbs.raw,
    subject = common_name(subject) or "?",
    subject_cn = common_name(subject),
    subject_der = subject.raw,
    issuer_der = issuer.raw,
    not_before = M.parse_time(validity.children[1]),
    not_after = M.parse_time(validity.children[2]),
    sig_alg = parse_sig_alg(cert.children[2]),
    signature = asn1.bits(cert.children[3]),
    ca = false,
    unknown_critical = {},
  }
  local kt, key, kerr = parse_key(spki)
  out.key_type, out.key_error = kt, kerr
  if kt == "rsa" then
    out.rsa = key
  elseif kt == "ec" then
    out.ec = key
  end
  for k = i + 6, #tbs.children do
    if tbs.children[k].tag == 0xa3 then
      parse_extensions(out, tbs.children[k])
    end
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
