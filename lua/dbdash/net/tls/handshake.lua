-- TLS 1.3 client handshake (RFC 8446): X25519 or secp256r1 key exchange, AES-128-GCM-SHA256 or
-- ChaCha20-Poly1305-SHA256, server authentication by CertificateVerify, Finished.
--
-- Modes (:help dbdash-tls):
--   require  encryption only; the certificate is not checked
--   pin      the leaf certificate's SHA-256 must equal the configured fingerprint and its
--            CertificateVerify signature must verify (otherwise a server could replay the
--            real certificate)
local auth = require("dbdash.net.tls.auth")
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
  [0x1301] = {
    name = "TLS_AES_128_GCM_SHA256",
    key_len = 16,
    new = function(k)
      return require("dbdash.crypto.aes_gcm").new(k)
    end,
  },
  [0x1303] = {
    name = "TLS_CHACHA20_POLY1305_SHA256",
    key_len = 32,
    new = function(k)
      return require("dbdash.crypto.chacha20_poly1305").new(k)
    end,
  },
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
-- TLS 1.2 ServerKeyExchange may also use RSA PKCS#1 v1.5 and SHA-512 variants.
local SIG_ALGS_12 = { 0x0401, 0x0501, 0x0601, 0x0806, 0x0603 }
-- What certificates may be signed with (servers pick certificates by it).
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

---@class dbdash.net.tls.handshake.ClientHelloOpts
---@field alpn string[]?
---@field tls12 boolean? false: offer TLS 1.3 only
---@field tls13 boolean? false: offer TLS 1.2 only

---Build the ClientHello handshake message: TLS 1.3 with a TLS 1.2 fallback. Key shares
---for both groups are sent up front (some servers, e.g. PostgreSQL by default, only accept
---secp256r1), so no HelloRetryRequest is needed.
---@param shares { x25519: string, p256: string }
---@param o dbdash.net.tls.handshake.ClientHelloOpts?
function M.client_hello(host, shares, random, session_id, o)
  o = o or {}
  local tls12 = o.tls12 ~= false
  local tls13 = o.tls13 ~= false
  local key_shares = u16(GROUP_X25519)
    .. vec16(shares.x25519)
    .. u16(GROUP_P256)
    .. vec16(shares.p256)
  local sig_algs = vim.list_extend(vim.deepcopy(SIG_ALGS), tls12 and SIG_ALGS_12 or {})
  local exts = {
    ext(10, vec16(list16({ GROUP_X25519, GROUP_P256 }))), -- supported_groups
    ext(13, vec16(list16(sig_algs))), -- signature_algorithms
    ext(50, vec16(list16(SIG_ALGS_CERT))), -- signature_algorithms_cert
  }
  if tls13 then
    exts[#exts + 1] =
      -- supported_versions
      ext(43, tls12 and (u8(4) .. u16(0x0304) .. u16(0x0303)) or (u8(2) .. u16(0x0304)))
    exts[#exts + 1] = ext(51, vec16(key_shares)) -- key_share
  end
  if tls12 then
    exts[#exts + 1] = ext(11, u8(1) .. u8(0)) -- ec_point_formats: uncompressed
    exts[#exts + 1] = ext(0xff01, u8(0)) -- renegotiation_info (initial handshake)
    exts[#exts + 1] = ext(23, "") -- extended_master_secret
    exts[#exts + 1] = ext(22, "") -- encrypt_then_mac
  end
  if o.alpn and #o.alpn > 0 then
    local names = {}
    for _, a in ipairs(o.alpn) do
      names[#names + 1] = u8(#a) .. a
    end
    exts[#exts + 1] = ext(16, vec16(table.concat(names)))
  end
  if is_dns_name(host) then
    local name = u8(0) .. vec16(host)
    table.insert(exts, 1, ext(0, vec16(name))) -- server_name
  end
  local suites = tls13 and { 0x1301, 0x1303 } or {}
  if tls12 then
    vim.list_extend(suites, require("dbdash.net.tls.handshake12").ORDER)
  end
  local body = u16(0x0303)
    .. random
    .. u8(#session_id)
    .. session_id
    .. vec16(list16(suites))
    .. u8(1)
    .. u8(0)
    .. vec16(table.concat(exts))
  return u8(HS.client_hello) .. u24(#body) .. body
end

---@class dbdash.tls.ServerHello
---@field version integer 0x0304 or 0x0303
---@field random string
---@field suite integer
---@field share string? TLS 1.3 key share
---@field group integer?
---@field ems boolean TLS 1.2 extended master secret
---@field etm boolean TLS 1.2 encrypt-then-MAC

---Parse ServerHello.
---@param offered13 boolean? false when the ClientHello did not offer TLS 1.3
---@return dbdash.tls.ServerHello
function M.parse_server_hello(body, offered13)
  local legacy = rd16(body, 1)
  local p = 3
  local random = body:sub(p, p + 31)
  if random == HRR_RANDOM then
    fail(
      "the server asked for a different key exchange group (HelloRetryRequest); only x25519 and secp256r1 are supported"
    )
  end
  p = p + 32
  local sid_len = body:byte(p)
  p = p + 1 + sid_len
  local suite
  suite, p = rd16(body, p)
  p = p + 1 -- compression
  local info = { random = random, suite = suite, ems = false, etm = false }
  if p <= #body then
    local ext_len
    ext_len, p = rd16(body, p)
    local stop = p + ext_len
    while p < stop do
      local typ, len
      typ, p = rd16(body, p)
      len, p = rd16(body, p)
      local data = body:sub(p, p + len - 1)
      p = p + len
      if typ == 43 then
        info.version = rd16(data, 1)
      elseif typ == 51 then
        info.group = rd16(data, 1)
        local klen = rd16(data, 3)
        if info.group ~= GROUP_X25519 and info.group ~= GROUP_P256 then
          fail("server chose an unsupported key exchange group 0x%04x", info.group)
        end
        info.share = data:sub(5, 4 + klen)
      elseif typ == 23 then
        info.ems = true
      elseif typ == 22 then
        info.etm = true
      end
    end
  end
  if not info.version then
    -- No supported_versions: TLS 1.2 or older.
    if legacy ~= 0x0303 then
      fail("the server only supports TLS versions older than 1.2 (0x%04x)", legacy)
    end
    local tail = random:sub(25)
    if offered13 ~= false and (tail == "DOWNGRD\1" or tail == "DOWNGRD\0") then
      fail("TLS downgrade detected (the server supports TLS 1.3 but negotiated an older version)")
    end
    info.version = 0x0303
    return info
  end
  if info.version ~= 0x0304 then
    fail("unsupported TLS version 0x%04x", info.version)
  end
  if not SUITES[suite] then
    fail("server chose an unsupported cipher suite 0x%04x", suite)
  end
  local share, group = info.share, info.group
  if
    not share
    or (group == GROUP_X25519 and #share ~= 32)
    or (group == GROUP_P256 and #share ~= 65)
  then
    fail("missing or invalid key share")
  end
  return info
end

---Content signed by the server in CertificateVerify.
function M.verify_content(transcript_hash)
  return string.rep(" ", 64) .. "TLS 1.3, server CertificateVerify\0" .. transcript_hash
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

---@class dbdash.net.tls.handshake.RunOpts
---@field host string
---@field mode "require"|"pin"|"verify-ca"|"verify-full"
---@field fingerprint string?
---@field ca string?
---@field base_dir string?

---@class dbdash.net.tls.handshake.State
---@field sock dbdash.net.Socket
---@field opts dbdash.net.tls.handshake.RunOpts
---@field transcript string the handshake messages so far
---@field hbuf string handshake bytes read but not taken yet
---@field read_cipher dbdash.tls.Cipher? the server's handshake protection

---The next handshake message (type, body, the whole message): plaintext before the
---ServerHello, protected after it (compatibility ChangeCipherSpec records are ignored).
local function next_handshake(h)
  while true do
    if #h.hbuf >= 4 then
      local len = rd24(h.hbuf, 2)
      if #h.hbuf >= 4 + len then
        local msg = h.hbuf:sub(1, 4 + len)
        h.hbuf = h.hbuf:sub(5 + len)
        return msg:byte(1), msg:sub(5), msg
      end
    end
    local typ, hdr, body = record.read(h.sock)
    if typ == TYPE.change_cipher_spec then
      -- middlebox compatibility record: ignore
    elseif typ == TYPE.alert and not h.read_cipher then
      record.alert(body)
    elseif h.read_cipher then
      if typ ~= TYPE.application_data then
        fail("unexpected plaintext record type %d after ServerHello", typ)
      end
      local inner_type, content = h.read_cipher:open(hdr, body)
      if inner_type == TYPE.alert then
        record.alert(content)
      elseif inner_type ~= TYPE.handshake then
        fail("unexpected record type %d during the handshake", inner_type)
      end
      h.hbuf = h.hbuf .. content
    elseif typ == TYPE.handshake then
      h.hbuf = h.hbuf .. body
    else
      fail("unexpected record type %d before ServerHello", typ)
    end
  end
end

---Certificate (TLS 1.3): the chain (with per-certificate extensions), authenticated.
local function read_certificate(body, opts)
  local p = 2 + body:byte(1) -- after the request context
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
  return auth.authenticate(ders, opts)
end

---CertificateVerify: the server's signature over the transcript (an error in strict
---modes); true when it checks.
local function check_verify(h, cert, body)
  if not cert then
    fail("CertificateVerify without a certificate")
  end
  local alg = rd16(body, 1)
  local slen = rd16(body, 3)
  local sig = body:sub(5, 4 + slen)
  local ok, err = false, "certificate key could not be parsed"
  if cert.key_type then
    ok, err = M.check_signature(cert, alg, sig, sha256.digest(h.transcript))
  end
  if not ok and auth.STRICT[h.opts.mode] then
    fail("CertificateVerify signature check failed%s", err and (": " .. err) or "")
  end
  return ok
end

---The server's encrypted flight up to its Finished: EncryptedExtensions,
---[CertificateRequest], Certificate, CertificateVerify, Finished. Returns the certificate
---and whether a client certificate was asked for.
local function server_flight(h, s_hs)
  local cert, cert_requested, cv_ok
  while true do
    local t, body, raw = next_handshake(h)
    if t == HS.certificate_request then
      cert_requested = true
    elseif t == HS.certificate then
      cert = read_certificate(body, h.opts)
    elseif t == HS.certificate_verify then
      cv_ok = check_verify(h, cert, body)
    elseif t == HS.finished then
      if not util.equal(body, finished_mac(s_hs, h.transcript)) then
        fail("server Finished verification failed")
      end
    elseif t ~= HS.encrypted_extensions then
      fail("unexpected handshake message %d", t)
    end
    h.transcript = h.transcript .. raw
    if t == HS.finished then
      break
    end
  end
  if auth.STRICT[h.opts.mode] and not cv_ok then
    fail("the server did not prove possession of its certificate key")
  end
  return cert, cert_requested
end

---The shared secret of the key share the server chose (P-256 or x25519).
local function shared_secret(sh, keys)
  if sh.group == GROUP_P256 then
    return require("dbdash.crypto.ecdsa_p256").ecdh(keys.p256_priv, sh.share)
  end
  local shared = x25519.scalarmult(keys.x25519_priv, sh.share)
  if shared == string.rep("\0", 32) then
    fail("invalid x25519 shared secret")
  end
  return shared
end

---Send the ClientHello and read the ServerHello: its fields and the client's key pairs.
local function hello(h)
  local priv, pub = x25519.keypair()
  local ppriv, ppub = require("dbdash.crypto.ecdsa_p256").ecdh_keypair()
  local rand = require("dbdash.crypto.random")
  local client_random = rand.bytes(32)
  local opts = h.opts
  local ch = M.client_hello(
    opts.host,
    { x25519 = pub, p256 = ppub },
    client_random,
    rand.bytes(32),
    { alpn = opts.alpn, tls12 = opts.tls12, tls13 = opts.tls13 }
  )
  h.sock:raw_write(record.header(TYPE.handshake, #ch) .. ch)
  h.transcript = ch
  -- ServerHello (plaintext; may be preceded by nothing else).
  local t, body, raw = next_handshake(h)
  if t ~= HS.server_hello then
    fail("expected ServerHello, got handshake message %d", t)
  end
  h.transcript = h.transcript .. raw
  local keys = { x25519_priv = priv, p256_priv = ppriv, p256_pub = ppub }
  return M.parse_server_hello(body, opts.tls13), client_random, keys
end

---Run the handshake on a connected socket (raw I/O). Returns the session. A TLS 1.2
---server continues in handshake12.lua.
---@param sock dbdash.net.Socket
---@param opts dbdash.net.tls.handshake.RunOpts
---@return dbdash.tls.Session
function M.run(sock, opts)
  local h = { sock = sock, opts = opts, transcript = "", hbuf = "" }
  local sh, client_random, keys = hello(h)
  if sh.version == 0x0303 then
    return require("dbdash.net.tls.handshake12").finish(sock, {
      opts = opts,
      suite = sh.suite,
      client_random = client_random,
      server_random = sh.random,
      transcript = h.transcript,
      leftover = h.hbuf,
      ems = sh.ems,
      etm = sh.etm,
      x25519 = { priv = keys.x25519_priv },
      p256 = { priv = keys.p256_priv, pub = keys.p256_pub },
    })
  end
  local suite = sh.suite
  if #h.hbuf > 0 then
    fail("unexpected data after ServerHello in the same record")
  end
  local zeros = string.rep("\0", 32)
  local early = hkdf.extract(sha256, zeros, zeros)
  local hs_secret =
    hkdf.extract(sha256, derive_secret(early, "derived", ""), shared_secret(sh, keys))
  local c_hs = derive_secret(hs_secret, "c hs traffic", h.transcript)
  local s_hs = derive_secret(hs_secret, "s hs traffic", h.transcript)
  h.read_cipher = traffic(suite, s_hs)
  local write_cipher = traffic(suite, c_hs)
  local cert, cert_requested = server_flight(h, s_hs)
  -- Application traffic secrets are derived from the transcript up to server Finished.
  local master = hkdf.extract(sha256, derive_secret(hs_secret, "derived", ""), zeros)
  local c_ap = derive_secret(master, "c ap traffic", h.transcript)
  local s_ap = derive_secret(master, "s ap traffic", h.transcript)
  -- Client flight: (compat CCS), [empty Certificate], Finished.
  local out = { record.header(TYPE.change_cipher_spec, 1) .. "\1" }
  if cert_requested then
    local empty = u8(HS.certificate) .. u24(4) .. u8(0) .. u24(0)
    out[#out + 1] = write_cipher:seal(TYPE.handshake, empty)
    h.transcript = h.transcript .. empty
  end
  local fin_body = finished_mac(c_hs, h.transcript)
  local fin = u8(HS.finished) .. u24(#fin_body) .. fin_body
  out[#out + 1] = write_cipher:seal(TYPE.handshake, fin)
  sock:raw_write(table.concat(out))
  return {
    version = 0x0304,
    suite = suite,
    suite_name = SUITES[suite].name,
    read = traffic(suite, s_ap),
    write = traffic(suite, c_ap),
    s_secret = s_ap,
    c_secret = c_ap,
    cert = cert,
    leftover = h.hbuf,
  }
end

---Next traffic secret after a KeyUpdate.
function M.update_secret(secret)
  return hkdf.expand_label(sha256, secret, "traffic upd", "", 32)
end

return M
