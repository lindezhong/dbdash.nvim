-- Certificate chain and host name verification for tls=verify-full (design §9.2).
--
-- The chain is built from the leaf through the certificates the server sent and the
-- trust store, checking signatures, validity periods, CA constraints and unknown critical
-- extensions. Host names match subjectAltName (DNS names with a left-most wildcard label,
-- IP addresses); certificates without a subjectAltName fall back to the common name.
-- Revocation (CRL/OCSP) is not checked.
local x509 = require("dbdash.net.tls.x509")

local M = {}

M.MAX_DEPTH = 8

local HASHES = {
  sha1 = function()
    return require("dbdash.crypto.sha1")
  end,
  sha256 = function()
    return require("dbdash.crypto.sha256")
  end,
  sha384 = function()
    return require("dbdash.crypto.sha512").sha384
  end,
  sha512 = function()
    return require("dbdash.crypto.sha512")
  end,
}

---Does `issuer` sign `cert`? Returns ok, reason.
function M.check_signature(cert, issuer)
  local alg = cert.sig_alg
  local hf = alg.hash and HASHES[alg.hash]
  if alg.kind == "unsupported" or not hf then
    return false, "unsupported signature algorithm " .. tostring(alg.oid)
  end
  if alg.hash == "sha1" and cert.der ~= issuer.der then
    return false, "SHA-1 certificate signatures are not accepted"
  end
  local hash = hf()
  if alg.kind == "rsa_pkcs1" or alg.kind == "rsa_pss" then
    if issuer.key_type ~= "rsa" then
      return false, "issuer key type does not match the signature"
    end
    local rsa = require("dbdash.crypto.rsa")
    local f = alg.kind == "rsa_pkcs1" and rsa.pkcs1_verify or rsa.pss_verify
    return f(issuer.rsa, hash, cert.tbs, cert.signature), "bad signature"
  elseif alg.kind == "ecdsa" then
    if issuer.key_type ~= "ec" then
      return false, "issuer key type does not match the signature"
    end
    local curve = require("dbdash.crypto.ecdsa").curves[issuer.ec.curve == "P-384" and "p384" or "p256"]
    return curve:verify(issuer.ec, hash.digest(cert.tbs), cert.signature), "bad signature"
  end
  return false, "unsupported signature algorithm"
end

local function describe(cert)
  return ("%q"):format(cert.subject)
end

local function check_validity(cert, now)
  if now < cert.not_before then
    return false, ("certificate %s is not valid yet (from %s)"):format(describe(cert), os.date("!%Y-%m-%d", cert.not_before))
  elseif now > cert.not_after then
    return false, ("certificate %s has expired (on %s)"):format(describe(cert), os.date("!%Y-%m-%d", cert.not_after))
  end
  return true
end

local function check_critical(cert)
  if #cert.unknown_critical > 0 then
    return false, ("certificate %s has unsupported critical extension(s): %s"):format(describe(cert), table.concat(cert.unknown_critical, ", "))
  end
  return true
end

---Candidate issuers of `cert` from a subject index, preferring matching key identifiers.
local function issuers(index, cert)
  local list = index[cert.issuer_der] or {}
  if not cert.aki then
    return list
  end
  local first, rest = {}, {}
  for _, c in ipairs(list) do
    if c.ski == cert.aki then
      first[#first + 1] = c
    else
      rest[#rest + 1] = c
    end
  end
  return vim.list_extend(first, rest)
end

---Verify a chain. Returns true or false plus a reason.
---@param leaf dbdash.x509.Cert
---@param intermediates dbdash.x509.Cert[]
---@param store dbdash.tls.TrustStore
---@param now integer? epoch seconds (default: current time)
function M.chain(leaf, intermediates, store, now)
  now = now or os.time()
  if store.by_der[leaf.der] then
    return true -- the leaf itself is trusted (e.g. a self-signed certificate in ?ca=)
  end
  local ok, why = check_validity(leaf, now)
  if not ok then
    return false, why
  end
  ok, why = check_critical(leaf)
  if not ok then
    return false, why
  end
  if leaf.ext_key_usage and not (leaf.ext_key_usage[x509.OID.server_auth] or leaf.ext_key_usage[x509.OID.any_eku]) then
    return false, ("certificate %s is not valid for server authentication"):format(describe(leaf))
  end
  local inter_index = {}
  for _, c in ipairs(intermediates) do
    inter_index[c.subject_der] = inter_index[c.subject_der] or {}
    table.insert(inter_index[c.subject_der], c)
  end

  local last_reason
  local function walk(cert, depth, visited, below)
    if depth > M.MAX_DEPTH then
      last_reason = "certificate chain is too long"
      return false
    end
    -- A trust anchor that signed `cert` ends the chain.
    for _, anchor in ipairs(issuers(store.by_subject, cert)) do
      local sig_ok, reason = M.check_signature(cert, anchor)
      if sig_ok then
        if anchor.path_len and below > anchor.path_len then
          last_reason = ("path length constraint of %s exceeded"):format(describe(anchor))
        else
          return true
        end
      else
        last_reason = ("signature of %s by %s: %s"):format(describe(cert), describe(anchor), reason)
      end
    end
    for _, ca in ipairs(issuers(inter_index, cert)) do
      if not visited[ca.der] then
        local sig_ok, reason = M.check_signature(cert, ca)
        if not sig_ok then
          last_reason = ("signature of %s by %s: %s"):format(describe(cert), describe(ca), reason)
        else
          local v_ok, v_why = check_validity(ca, now)
          local c_ok, c_why = check_critical(ca)
          if not v_ok then
            last_reason = v_why
          elseif not c_ok then
            last_reason = c_why
          elseif not ca.ca or (ca.key_usage and not ca.key_usage.key_cert_sign) then
            last_reason = ("certificate %s is not a CA"):format(describe(ca))
          elseif ca.path_len and below > ca.path_len then
            last_reason = ("path length constraint of %s exceeded"):format(describe(ca))
          else
            visited[ca.der] = true
            if walk(ca, depth + 1, visited, below + 1) then
              return true
            end
            visited[ca.der] = nil
          end
        end
      end
    end
    last_reason = last_reason or ("unable to find a trusted issuer for %s (trust store: %s)"):format(describe(cert), store.source)
    return false
  end

  if walk(leaf, 1, { [leaf.der] = true }, 0) then
    return true
  end
  return false, last_reason
end

---IPv4/IPv6 text -> packed bytes, or nil for names.
local function ip_bytes(host)
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a then
    return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
  end
  if host:find(":", 1, true) then
    local head, tail = host:match("^(.-)::(.*)$")
    local function groups(s)
      local out = {}
      for g in s:gmatch("[^:]+") do
        out[#out + 1] = tonumber(g, 16)
      end
      return out
    end
    local parts
    if head then
      local h, t = groups(head), groups(tail)
      parts = h
      for _ = 1, 8 - #h - #t do
        parts[#parts + 1] = 0
      end
      vim.list_extend(parts, t)
    else
      parts = groups(host)
    end
    if #parts ~= 8 then
      return nil
    end
    local out = {}
    for _, g in ipairs(parts) do
      out[#out + 1] = string.char(math.floor(g / 256), g % 256)
    end
    return table.concat(out)
  end
end
M.ip_bytes = ip_bytes

---Does a certificate DNS name (maybe "*.example.com") match `host`?
function M.dns_match(pattern, host)
  pattern, host = pattern:lower():gsub("%.$", ""), host:lower():gsub("%.$", "")
  if pattern == host then
    return true
  end
  local rest = pattern:match("^%*%.(.+)$")
  if not rest or not rest:find(".", 1, true) then
    return false -- only "*.<at least two labels>" wildcards
  end
  local first, host_rest = host:match("^([^.]+)%.(.+)$")
  return first ~= nil and host_rest == rest
end

---Check that the certificate is valid for `host`. Returns true or false plus a reason.
function M.host(cert, host)
  local ip = ip_bytes(host)
  local names = {}
  if cert.san and (#cert.san.dns > 0 or #cert.san.ip > 0) then
    if ip then
      for _, b in ipairs(cert.san.ip) do
        if b == ip then
          return true
        end
      end
    else
      for _, n in ipairs(cert.san.dns) do
        if M.dns_match(n, host) then
          return true
        end
      end
    end
    names = vim.deepcopy(cert.san.dns)
    for _, b in ipairs(cert.san.ip) do
      names[#names + 1] = #b == 4 and table.concat({ b:byte(1, 4) }, ".") or "IPv6 address"
    end
  elseif cert.subject_cn then
    -- No subjectAltName: fall back to the common name.
    if (ip and cert.subject_cn == host) or (not ip and M.dns_match(cert.subject_cn, host)) then
      return true
    end
    names = { cert.subject_cn .. " (common name)" }
  end
  return false, ("host name mismatch: the certificate is for %s, not %s"):format(
    #names > 0 and table.concat(names, ", ") or "no names",
    host
  )
end

return M
