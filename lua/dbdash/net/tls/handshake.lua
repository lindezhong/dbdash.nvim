-- TLS 1.3 client handshake (RFC 8446): X25519 or secp256r1 key exchange, AES-128-GCM-SHA256 or
-- ChaCha20-Poly1305-SHA256, server authentication by CertificateVerify, Finished.
--
-- Modes (design §9.2):
--   require  encryption only; the certificate is not checked
--   pin      the leaf certificate's SHA-256 must equal the configured fingerprint and its
--            CertificateVerify signature must verify (otherwise a server could replay the
--            real certificate)
local record = require("dbdash.net.tls.record")
local sha256 = require("dbdash.crypto.sha256")
local hkdf = require("dbdash.crypto.hkdf")
local hmac = require("dbdash.crypto.hmac")
local util = require("dbdash.crypto.util")
local x25519 = require("dbdash.crypto.x25519")

local M = {}

local fail = record.fail
local TYPE = record.TYPE

local HS = {
  client_hello = 1,
  server_hello = 2,
  new_session_ticket = 4,
  encrypted_extensions = 8,
  certificate = 11,
  certificate_request = 13,
  certificate_verify = 15,
  finished = 20,
  key_update = 24,
}
M.HS = HS

local SUITES = {
  [0x1301] = { name = "TLS_AES_128_GCM_SHA256", key_len = 16, new = function(k)
    return require("dbdash.crypto.aes_gcm").new(k)
  end },
  [0x1303] = { name = "TLS_CHACHA20_POLY1305_SHA256", key_len = 32, new = function(k)
    return require("dbdash.crypto.chacha20_poly1305").new(k)
  end },
}

local SIG = {
  ecdsa_secp256r1_sha256 = 0x0403,
  ecdsa_secp384r1_sha384 = 0x0503,
  rsa_pss_rsae_sha256 = 0x0804,
  rsa_pss_rsae_sha384 = 0x0805,
}
-- What we can verify in CertificateVerify.
local SIG_ALGS = {
  SIG.ecdsa_secp256r1_sha256,
  SIG.ecdsa_secp384r1_sha384,
  SIG.rsa_pss_rsae_sha256,
  SIG.rsa_pss_rsae_sha384,
}
-- What certificates may be signed with (not checked, but servers pick certificates by it).
local SIG_ALGS_CERT = { 0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806, 0x0401, 0x0501, 0x0601 }

local HRR_RANDOM = util.unhex("cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c")
local GROUP_X25519 = 0x001d
local GROUP_P256 = 0x0017

local function u8(n)
  return string.char(n % 256)
end
local function u16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end
local function u24(n)
  return string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end
local function vec16(s)
  return u16(#s) .. s
end

local function rd16(s, p)
  return s:byte(p) * 256 + s:byte(p + 1), p + 2
end
local function rd24(s, p)
  return s:byte(p) * 65536 + s:byte(p + 1) * 256 + s:byte(p + 2), p + 3
end

local function ext(typ, body)
  return u16(typ) .. vec16(body)
end

local function list16(values)
  local parts = {}
  for i, v in ipairs(values) do
    parts[i] = u16(v)
  end
  return table.concat(parts)
end

---Is `host` a DNS name (SNI is not sent for IP addresses)?
local function is_dns_name(host)
  return host and not host:match("^[%d%.]+$") and not host:find(":", 1, true)
end

---Build the ClientHello handshake message. Key shares for both groups are sent up front
---(some servers, e.g. PostgreSQL by default, only accept secp256r1), so no
---HelloRetryRequest is needed.
---@param shares { x25519: string, p256: string }
function M.client_hello(host, shares, random, session_id)
  local key_shares = u16(GROUP_X25519) .. vec16(shares.x25519) .. u16(GROUP_P256) .. vec16(shares.p256)
  local exts = {
    ext(43, u8(2) .. u16(0x0304)), -- supported_versions: TLS 1.3
    ext(10, vec16(list16({ GROUP_X25519, GROUP_P256 }))), -- supported_groups
    ext(51, vec16(key_shares)), -- key_share
    ext(13, vec16(list16(SIG_ALGS))), -- signature_algorithms
    ext(50, vec16(list16(SIG_ALGS_CERT))), -- signature_algorithms_cert
  }
  if is_dns_name(host) then
    local name = u8(0) .. vec16(host)
    table.insert(exts, 1, ext(0, vec16(name))) -- server_name
  end
  local body = u16(0x0303)
    .. random
    .. u8(#session_id) .. session_id
    .. vec16(list16({ 0x1301, 0x1303 }))
    .. u8(1) .. u8(0)
    .. vec16(table.concat(exts))
  return u8(HS.client_hello) .. u24(#body) .. body
end

---Parse ServerHello: suite, group, server key share.
function M.parse_server_hello(body)
  local p = 3 -- legacy_version
  local random = body:sub(p, p + 31)
  if random == HRR_RANDOM then
    fail("the server asked for a different key exchange group (HelloRetryRequest); only x25519 and secp256r1 are supported")
  end
  p = p + 32
  local sid_len = body:byte(p)
  p = p + 1 + sid_len
  local suite
  suite, p = rd16(body, p)
  p = p + 1 -- compression
  local ext_len
  ext_len, p = rd16(body, p)
  local stop = p + ext_len
  local version, share, group
  while p < stop do
    local typ, len
    typ, p = rd16(body, p)
    len, p = rd16(body, p)
    local data = body:sub(p, p + len - 1)
    p = p + len
    if typ == 43 then
      version = rd16(data, 1)
    elseif typ == 51 then
      group = rd16(data, 1)
      local klen = rd16(data, 3)
      if group ~= GROUP_X25519 and group ~= GROUP_P256 then
        fail("server chose an unsupported key exchange group 0x%04x", group)
      end
      share = data:sub(5, 4 + klen)
    end
  end
  if version ~= 0x0304 then
    fail("the server does not support TLS 1.3 (TLS 1.2 is not available yet)")
  end
  if not SUITES[suite] then
    fail("server chose an unsupported cipher suite 0x%04x", suite)
  end
  if not share or (group == GROUP_X25519 and #share ~= 32) or (group == GROUP_P256 and #share ~= 65) then
    fail("missing or invalid key share")
  end
  return suite, share, group
end

---Content signed by the server in CertificateVerify.
function M.verify_content(transcript_hash)
  return string.rep(" ", 64) .. "TLS 1.3, server CertificateVerify\0" .. transcript_hash
end

-- Modes that require the server to prove possession of its certificate key.
M.STRICT = { pin = true, ["verify-ca"] = true, ["verify-full"] = true }

---Authenticate the server's certificate list (DER strings, leaf first) for the mode:
---pin compares the leaf fingerprint; verify-ca / verify-full validate the chain against
---the trust store, and verify-full also the host name. Returns the parsed leaf.
---@param ders string[]
---@param opts { host: string, mode: string, fingerprint: string?, ca: string?, base_dir: string? }
---@return dbdash.x509.Cert
function M.authenticate(ders, opts)
  local x509 = require("dbdash.net.tls.x509")
  local der = ders[1]
  if not der then
    fail("the server sent no certificate")
  end
  local fp = x509.fingerprint(der)
  if opts.mode == "pin" and not util.equal(sha256.digest(der), opts.fingerprint) then
    fail("certificate fingerprint mismatch: the server presented %s", fp)
  end
  local ok, cert = pcall(x509.parse, der)
  if not ok then
    if M.STRICT[opts.mode] then
      error(cert, 0)
    end
    cert = { der = der }
  end
  cert.fingerprint = fp
  if opts.mode == "verify-ca" or opts.mode == "verify-full" then
    local verify = require("dbdash.net.tls.verify")
    local inters = {}
    for k = 2, #ders do
      local iok, ic = pcall(x509.parse, ders[k])
      if iok then
        inters[#inters + 1] = ic
      end
    end
    local store = require("dbdash.net.tls.truststore").for_info(opts.ca, opts.base_dir)
    local vok, why = verify.chain(cert, inters, store)
    if not vok then
      fail("certificate verification failed: %s (presented %s)", why, fp)
    end
    if opts.mode == "verify-full" then
      local hok, hwhy = verify.host(cert, opts.host)
      if not hok then
        fail("certificate verification failed: %s", hwhy)
      end
    end
  end
  return cert
end

---Check a CertificateVerify signature with the leaf certificate's key.
---@return boolean ok, string? err
function M.check_signature(cert, alg, sig, transcript_hash)
  local content = M.verify_content(transcript_hash)
  if alg == SIG.ecdsa_secp256r1_sha256 or alg == SIG.ecdsa_secp384r1_sha384 then
    local p384 = alg == SIG.ecdsa_secp384r1_sha384
    if cert.key_type ~= "ec" or cert.ec.curve ~= (p384 and "P-384" or "P-256") then
      return false, "signature algorithm does not match the certificate key"
    end
    local curves = require("dbdash.crypto.ecdsa").curves
    local hash = p384 and require("dbdash.crypto.sha512").sha384 or sha256
    return (p384 and curves.p384 or curves.p256):verify(cert.ec, hash.digest(content), sig)
  elseif alg == SIG.rsa_pss_rsae_sha256 or alg == SIG.rsa_pss_rsae_sha384 then
    if cert.key_type ~= "rsa" then
      return false, "signature algorithm does not match the certificate key"
    end
    local hash = alg == SIG.rsa_pss_rsae_sha256 and sha256 or require("dbdash.crypto.sha512").sha384
    return require("dbdash.crypto.rsa").pss_verify(cert.rsa, hash, content, sig)
  end
  return false, ("unsupported signature algorithm 0x%04x"):format(alg)
end

local function derive_secret(secret, label, transcript)
  return hkdf.expand_label(sha256, secret, label, sha256.digest(transcript), 32)
end

local function traffic(suite, secret)
  local s = SUITES[suite]
  local key = hkdf.expand_label(sha256, secret, "key", "", s.key_len)
  local iv = hkdf.expand_label(sha256, secret, "iv", "", 12)
  return record.cipher(s.new(key), iv)
end
M.traffic = traffic

local function finished_mac(secret, transcript)
  local fk = hkdf.expand_label(sha256, secret, "finished", "", 32)
  return hmac.hmac(sha256, fk, sha256.digest(transcript))
end

---@class dbdash.tls.Session
---@field suite integer
---@field read dbdash.tls.Cipher
---@field write dbdash.tls.Cipher
---@field s_secret string current server application traffic secret
---@field c_secret string
---@field cert dbdash.x509.Cert
---@field fingerprint string

---Run the handshake on a connected socket (raw I/O). Returns the session.
---@param sock dbdash.net.Socket
---@param opts { host: string, mode: "require"|"pin"|"verify-ca"|"verify-full", fingerprint: string?, ca: string?, base_dir: string? }
---@return dbdash.tls.Session
function M.run(sock, opts)
  local priv, pub = x25519.keypair()
  local p256 = require("dbdash.crypto.ecdsa_p256")
  local ppriv, ppub = p256.ecdh_keypair()
  local rand = require("dbdash.crypto.random")
  local ch = M.client_hello(opts.host, { x25519 = pub, p256 = ppub }, rand.bytes(32), rand.bytes(32))
  sock:raw_write(record.header(TYPE.handshake, #ch) .. ch)
  local transcript = ch

  -- ServerHello (plaintext; may be preceded by nothing else).
  local hbuf = ""
  local read_cipher
  local function next_handshake()
    while true do
      if #hbuf >= 4 then
        local len = rd24(hbuf, 2)
        if #hbuf >= 4 + len then
          local msg = hbuf:sub(1, 4 + len)
          hbuf = hbuf:sub(5 + len)
          return msg:byte(1), msg:sub(5), msg
        end
      end
      local typ, hdr, body = record.read(sock)
      if typ == TYPE.change_cipher_spec then
        -- middlebox compatibility record: ignore
      elseif typ == TYPE.alert and not read_cipher then
        record.alert(body)
      elseif read_cipher then
        if typ ~= TYPE.application_data then
          fail("unexpected plaintext record type %d after ServerHello", typ)
        end
        local inner_type, content = read_cipher:open(hdr, body)
        if inner_type == TYPE.alert then
          record.alert(content)
        elseif inner_type ~= TYPE.handshake then
          fail("unexpected record type %d during the handshake", inner_type)
        end
        hbuf = hbuf .. content
      elseif typ == TYPE.handshake then
        hbuf = hbuf .. body
      else
        fail("unexpected record type %d before ServerHello", typ)
      end
    end
  end

  local t, body, raw = next_handshake()
  if t ~= HS.server_hello then
    fail("expected ServerHello, got handshake message %d", t)
  end
  local suite, server_pub, group = M.parse_server_hello(body)
  transcript = transcript .. raw
  if #hbuf > 0 then
    fail("unexpected data after ServerHello in the same record")
  end

  local shared
  if group == GROUP_P256 then
    shared = p256.ecdh(ppriv, server_pub)
  else
    shared = x25519.scalarmult(priv, server_pub)
    if shared == string.rep("\0", 32) then
      fail("invalid x25519 shared secret")
    end
  end
  local zeros = string.rep("\0", 32)
  local early = hkdf.extract(sha256, zeros, zeros)
  local hs_secret = hkdf.extract(sha256, derive_secret(early, "derived", ""), shared)
  local c_hs = derive_secret(hs_secret, "c hs traffic", transcript)
  local s_hs = derive_secret(hs_secret, "s hs traffic", transcript)
  read_cipher = traffic(suite, s_hs)
  local write_cipher = traffic(suite, c_hs)

  local cert, cert_requested, cv_ok
  while true do
    t, body, raw = next_handshake()
    if t == HS.encrypted_extensions then
      transcript = transcript .. raw
    elseif t == HS.certificate_request then
      cert_requested = true
      transcript = transcript .. raw
    elseif t == HS.certificate then
      local ctx_len = body:byte(1)
      local p = 2 + ctx_len
      local list_len
      list_len, p = rd24(body, p)
      local stop = p + list_len
      local ders = {}
      while p < stop do
        local clen
        clen, p = rd24(body, p)
        ders[#ders + 1] = body:sub(p, p + clen - 1)
        p = p + clen
        local elen
        elen, p = rd16(body, p) -- per-certificate extensions
        p = p + elen
      end
      cert = M.authenticate(ders, opts)
      transcript = transcript .. raw
    elseif t == HS.certificate_verify then
      if not cert then
        fail("CertificateVerify without a certificate")
      end
      local alg = rd16(body, 1)
      local slen = rd16(body, 3)
      local sig = body:sub(5, 4 + slen)
      local ok, err = false, "certificate key could not be parsed"
      if cert.key_type then
        ok, err = M.check_signature(cert, alg, sig, sha256.digest(transcript))
      end
      if not ok and M.STRICT[opts.mode] then
        fail("CertificateVerify signature check failed%s", err and (": " .. err) or "")
      end
      cv_ok = ok
      transcript = transcript .. raw
    elseif t == HS.finished then
      local expected = finished_mac(s_hs, transcript)
      if not util.equal(body, expected) then
        fail("server Finished verification failed")
      end
      transcript = transcript .. raw
      break
    else
      fail("unexpected handshake message %d", t)
    end
  end
  if M.STRICT[opts.mode] and not cv_ok then
    fail("the server did not prove possession of its certificate key")
  end

  -- Application traffic secrets are derived from the transcript up to server Finished.
  local master = hkdf.extract(sha256, derive_secret(hs_secret, "derived", ""), zeros)
  local c_ap = derive_secret(master, "c ap traffic", transcript)
  local s_ap = derive_secret(master, "s ap traffic", transcript)

  -- Client flight: (compat CCS), [empty Certificate], Finished.
  local out = { record.header(TYPE.change_cipher_spec, 1) .. "\1" }
  if cert_requested then
    local empty = u8(HS.certificate) .. u24(4) .. u8(0) .. u24(0)
    out[#out + 1] = write_cipher:seal(TYPE.handshake, empty)
    transcript = transcript .. empty
  end
  local fin_body = finished_mac(c_hs, transcript)
  local fin = u8(HS.finished) .. u24(#fin_body) .. fin_body
  out[#out + 1] = write_cipher:seal(TYPE.handshake, fin)
  sock:raw_write(table.concat(out))

  return {
    suite = suite,
    suite_name = SUITES[suite].name,
    read = traffic(suite, s_ap),
    write = traffic(suite, c_ap),
    s_secret = s_ap,
    c_secret = c_ap,
    cert = cert,
    leftover = hbuf,
  }
end

---Next traffic secret after a KeyUpdate.
function M.update_secret(secret)
  return hkdf.expand_label(sha256, secret, "traffic upd", "", 32)
end

return M
