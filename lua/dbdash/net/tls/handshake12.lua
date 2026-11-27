-- TLS 1.2 client handshake (RFC 5246), entered when the ServerHello negotiates TLS 1.2.
--
-- Key exchange: ECDHE (x25519, secp256r1) with an RSA or ECDSA signed ServerKeyExchange,
-- or RSA key transport. Record protection: AES-GCM, ChaCha20-Poly1305 or AES-CBC with
-- HMAC (encrypt-then-MAC when the server agrees). Extended master secret is used when the
-- server supports it. Renegotiation is refused.
local record = require("dbdash.net.tls.record")
local prf12 = require("dbdash.crypto.prf12")
local util = require("dbdash.crypto.util")

local M = {}

local fail = record.fail
local TYPE = record.TYPE

local function sha256()
  return require("dbdash.crypto.sha256")
end
local function sha384()
  return require("dbdash.crypto.sha512").sha384
end
local function sha1()
  return require("dbdash.crypto.sha1")
end

---@class dbdash.tls12.Suite
---@field name string
---@field kx "ecdhe"|"rsa"
---@field auth "rsa"|"ecdsa"
---@field cipher "gcm"|"chacha"|"cbc"
---@field key_len integer
---@field mac fun(): table? HMAC hash for CBC suites
---@field prf fun(): table PRF hash

local function suite(name, kx, auth, cipher, key_len, prf, mac)
  return {
    name = name,
    kx = kx,
    auth = auth,
    cipher = cipher,
    key_len = key_len,
    prf = prf,
    mac = mac,
  }
end

M.SUITES = {
  [0xC02B] = suite("TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256", "ecdhe", "ecdsa", "gcm", 16, sha256),
  [0xC02F] = suite("TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", "ecdhe", "rsa", "gcm", 16, sha256),
  [0xC02C] = suite("TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384", "ecdhe", "ecdsa", "gcm", 32, sha384),
  [0xC030] = suite("TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384", "ecdhe", "rsa", "gcm", 32, sha384),
  [0xCCA9] = suite(
    "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
    "ecdhe",
    "ecdsa",
    "chacha",
    32,
    sha256
  ),
  [0xCCA8] = suite(
    "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
    "ecdhe",
    "rsa",
    "chacha",
    32,
    sha256
  ),
  [0xC023] = suite(
    "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256",
    "ecdhe",
    "ecdsa",
    "cbc",
    16,
    sha256,
    sha256
  ),
  [0xC027] = suite(
    "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256",
    "ecdhe",
    "rsa",
    "cbc",
    16,
    sha256,
    sha256
  ),
  [0xC024] = suite(
    "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384",
    "ecdhe",
    "ecdsa",
    "cbc",
    32,
    sha384,
    sha384
  ),
  [0xC028] = suite(
    "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384",
    "ecdhe",
    "rsa",
    "cbc",
    32,
    sha384,
    sha384
  ),
  [0xC009] = suite(
    "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA",
    "ecdhe",
    "ecdsa",
    "cbc",
    16,
    sha256,
    sha1
  ),
  [0xC013] = suite("TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA", "ecdhe", "rsa", "cbc", 16, sha256, sha1),
  [0xC00A] = suite(
    "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA",
    "ecdhe",
    "ecdsa",
    "cbc",
    32,
    sha256,
    sha1
  ),
  [0xC014] = suite("TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA", "ecdhe", "rsa", "cbc", 32, sha256, sha1),
  [0x009C] = suite("TLS_RSA_WITH_AES_128_GCM_SHA256", "rsa", "rsa", "gcm", 16, sha256),
  [0x009D] = suite("TLS_RSA_WITH_AES_256_GCM_SHA384", "rsa", "rsa", "gcm", 32, sha384),
  [0x003C] = suite("TLS_RSA_WITH_AES_128_CBC_SHA256", "rsa", "rsa", "cbc", 16, sha256, sha256),
  [0x002F] = suite("TLS_RSA_WITH_AES_128_CBC_SHA", "rsa", "rsa", "cbc", 16, sha256, sha1),
  [0x0035] = suite("TLS_RSA_WITH_AES_256_CBC_SHA", "rsa", "rsa", "cbc", 32, sha256, sha1),
}

-- Preference order: forward-secret AEAD, forward-secret CBC, then RSA key transport.
M.ORDER = {
  0xC02B,
  0xC02F,
  0xC02C,
  0xC030,
  0xCCA9,
  0xCCA8,
  0xC023,
  0xC027,
  0xC024,
  0xC028,
  0xC009,
  0xC013,
  0xC00A,
  0xC014,
  0x009C,
  0x009D,
  0x003C,
  0x002F,
  0x0035,
}

local HS = {
  hello_request = 0,
  server_hello_done = 14,
  certificate = 11,
  server_key_exchange = 12,
  certificate_request = 13,
  client_key_exchange = 16,
  finished = 20,
}
M.HS = HS

local function u8(n)
  return string.char(n % 256)
end
local function u16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end
local function u24(n)
  return string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end
local function rd16(s, p)
  return s:byte(p) * 256 + s:byte(p + 1), p + 2
end
local function rd24(s, p)
  return s:byte(p) * 65536 + s:byte(p + 1) * 256 + s:byte(p + 2), p + 3
end

local function message(t, body)
  return u8(t) .. u24(#body) .. body
end

---Verify a TLS 1.2 digitally-signed struct (SignatureAndHashAlgorithm + signature).
---@return boolean ok, string? err
function M.check_signature(cert, alg, sig, content)
  if cert.key_type == "rsa" then
    local rsa = require("dbdash.crypto.rsa")
    local pkcs1 = {
      [0x0401] = sha256,
      [0x0501] = sha384,
      [0x0601] = function()
        return require("dbdash.crypto.sha512")
      end,
    }
    local pss = {
      [0x0804] = sha256,
      [0x0805] = sha384,
      [0x0806] = function()
        return require("dbdash.crypto.sha512")
      end,
    }
    if pkcs1[alg] then
      return rsa.pkcs1_verify(cert.rsa, pkcs1[alg](), content, sig)
    elseif pss[alg] then
      return rsa.pss_verify(cert.rsa, pss[alg](), content, sig)
    end
  elseif cert.key_type == "ec" then
    local hashes = {
      [0x0403] = sha256,
      [0x0503] = sha384,
      [0x0603] = function()
        return require("dbdash.crypto.sha512")
      end,
    }
    if hashes[alg] then
      local curves = require("dbdash.crypto.ecdsa").curves
      local curve = cert.ec.curve == "P-384" and curves.p384 or curves.p256
      return curve:verify(cert.ec, hashes[alg]().digest(content), sig)
    end
  else
    return false, "certificate key could not be parsed"
  end
  return false, ("signature algorithm 0x%04x does not match the certificate key"):format(alg)
end

---Traffic protection for one direction.
local function protection(s, key, iv, mac_key, etm)
  if s.cipher == "gcm" then
    return record.aead12(require("dbdash.crypto.aes_gcm").new(key), iv, true)
  elseif s.cipher == "chacha" then
    return record.aead12(require("dbdash.crypto.chacha20_poly1305").new(key), iv, false)
  end
  return record.cbc12(key, s.mac(), mac_key, etm)
end

---@class dbdash.net.tls.handshake12.Ctx
---@field opts table
---@field suite integer
---@field client_random string
---@field server_random string
---@field transcript string
---@field leftover string
---@field ems boolean
---@field etm boolean
---@field x25519 { priv: string }
---@field p256 { priv: string }

---@class dbdash.net.tls.handshake12.State
---@field io table
---@field s table the cipher suite (M.SUITES)
---@field ctx dbdash.net.tls.handshake12.Ctx
---@field transcript string[] the handshake messages so far
---@field hbuf string handshake bytes read but not taken yet
---@field read_cipher table? the server's protection, after its ChangeCipherSpec

---The next handshake message (type, body, the whole message), or "ccs" for a
---ChangeCipherSpec.
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
    local typ, hdr, body = record.read(h.io)
    if h.read_cipher then
      typ, body = h.read_cipher:open(hdr, body)
    end
    if typ == TYPE.handshake then
      h.hbuf = h.hbuf .. body
    elseif typ == TYPE.alert then
      record.alert(body)
    elseif typ == TYPE.change_cipher_spec then
      return "ccs"
    else
      fail("unexpected record type %d during the TLS 1.2 handshake", typ)
    end
  end
end

---Certificate: the chain, authenticated (net/tls/auth.lua).
local function read_certificate(body, opts)
  local list_len, p = rd24(body, 1)
  local stop = p + list_len
  local ders = {}
  while p < stop do
    local clen
    clen, p = rd24(body, p)
    ders[#ders + 1] = body:sub(p, p + clen - 1)
    p = p + clen
  end
  return require("dbdash.net.tls.auth").authenticate(ders, opts)
end

---ServerKeyExchange (ECDHE, a named curve): the curve and the server's point, its
---signature checked with the certificate (an error in strict modes).
local function read_key_exchange(h, cert, body)
  if h.s.kx ~= "ecdhe" then
    fail("unexpected ServerKeyExchange for RSA key exchange")
  end
  if body:byte(1) ~= 3 then
    fail("only named curves are supported in ServerKeyExchange")
  end
  local ctx = h.ctx
  local group = rd16(body, 2)
  local plen = body:byte(4)
  local params = body:sub(1, 4 + plen)
  local point = body:sub(5, 4 + plen)
  local alg = rd16(body, 5 + plen)
  local slen = rd16(body, 7 + plen)
  local sig = body:sub(9 + plen, 8 + plen + slen)
  local ok, err = false, "no certificate" ---@type boolean, string?
  if cert then
    ok, err = M.check_signature(cert, alg, sig, ctx.client_random .. ctx.server_random .. params)
  end
  if not ok and require("dbdash.net.tls.auth").STRICT[ctx.opts.mode] then
    fail("ServerKeyExchange signature check failed%s", err and (": " .. err) or "")
  end
  return { group = group, point = point }
end

---The server flight: Certificate, [ServerKeyExchange], [CertificateRequest],
---ServerHelloDone. Returns the certificate, the key exchange's parameters and whether a
---client certificate was asked for.
local function server_flight(h)
  local cert, server_params, cert_requested
  while true do
    local t, body, raw = next_handshake(h)
    if t == "ccs" then
      fail("unexpected ChangeCipherSpec")
    end
    h.transcript[#h.transcript + 1] = raw
    if t == HS.certificate then
      cert = read_certificate(body, h.ctx.opts)
    elseif t == HS.server_key_exchange then
      server_params = read_key_exchange(h, cert, body)
    elseif t == HS.certificate_request then
      cert_requested = true
    elseif t == HS.server_hello_done then
      break
    else
      fail("unexpected handshake message %d in the server flight", t)
    end
  end
  if not cert or not cert.der then
    fail("the server sent no certificate")
  end
  return cert, server_params, cert_requested
end

---The premaster secret and the ClientKeyExchange body: ECDHE (x25519 or P-256) or RSA.
local function key_exchange(h, cert, server_params)
  local ctx = h.ctx
  if h.s.kx ~= "ecdhe" then
    if cert.key_type ~= "rsa" then
      fail("RSA key exchange needs an RSA certificate")
    end
    local premaster = "\3\3" .. require("dbdash.crypto.random").bytes(46)
    local enc = require("dbdash.crypto.rsa").pkcs1_encrypt(cert.rsa, premaster)
    return premaster, u16(#enc) .. enc
  end
  if not server_params then
    fail("missing ServerKeyExchange")
  end
  if server_params.group == 0x001d then
    local x25519 = require("dbdash.crypto.x25519")
    local premaster = x25519.scalarmult(ctx.x25519.priv, server_params.point)
    if premaster == string.rep("\0", 32) then
      fail("invalid x25519 shared secret")
    end
    return premaster, u8(32) .. x25519.public(ctx.x25519.priv)
  elseif server_params.group == 0x0017 then
    local curve = require("dbdash.crypto.ecdsa").curves.p256
    return curve:ecdh(ctx.p256.priv, server_params.point), u8(#ctx.p256.pub) .. ctx.p256.pub
  end
  fail("server chose an unsupported curve 0x%04x", server_params.group)
end

---The master secret (extended master secret when agreed) and both directions' keys.
---@return string master, table write_cipher, table keys of the server's direction
local function key_schedule(h, premaster)
  local s, ctx = h.s, h.ctx
  local prf_hash = s.prf()
  local master
  if ctx.ems then
    local hash = prf_hash.digest(table.concat(h.transcript))
    master = prf12.prf(prf_hash, premaster, "extended master secret", hash, 48)
  else
    local seed = ctx.client_random .. ctx.server_random
    master = prf12.prf(prf_hash, premaster, "master secret", seed, 48)
  end
  local mac_len = s.cipher == "cbc" and s.mac().size or 0
  local iv_len = s.cipher == "gcm" and 4 or (s.cipher == "chacha" and 12 or 0)
  local kb = prf12.prf(
    prf_hash,
    master,
    "key expansion",
    ctx.server_random .. ctx.client_random,
    2 * (mac_len + s.key_len + iv_len)
  )
  local pos = 1
  local function take(n)
    local v = kb:sub(pos, pos + n - 1)
    pos = pos + n
    return v
  end
  local c_mac, s_mac = take(mac_len), take(mac_len)
  local c_key, s_key = take(s.key_len), take(s.key_len)
  local c_iv, s_iv = take(iv_len), take(iv_len)
  local etm = s.cipher == "cbc" and ctx.etm
  return master, protection(s, c_key, c_iv, c_mac, etm), { s_key, s_iv, s_mac, etm }
end

---The Finished verify data of `label` over the transcript so far.
local function verify_data(h, master, label)
  local prf_hash = h.s.prf()
  return prf12.prf(prf_hash, master, label, prf_hash.digest(table.concat(h.transcript)), 12)
end

---Continue the handshake after a TLS 1.2 ServerHello.
---@param io table socket-like object (raw_read_exact / raw_write)
---@param ctx dbdash.net.tls.handshake12.Ctx
---@return dbdash.tls.Session
function M.finish(io, ctx)
  local s = M.SUITES[ctx.suite]
  if not s then
    fail("server chose an unsupported cipher suite 0x%04x", ctx.suite)
  end
  local h =
    { io = io, s = s, ctx = ctx, transcript = { ctx.transcript }, hbuf = ctx.leftover or "" }
  local cert, server_params, cert_requested = server_flight(h)
  -- Client flight: [Certificate (none)], ClientKeyExchange, ChangeCipherSpec, Finished.
  local out_msgs = {}
  if cert_requested then
    out_msgs[#out_msgs + 1] = message(HS.certificate, u24(0)) -- no client certificate
  end
  local premaster, cke_body = key_exchange(h, cert, server_params)
  out_msgs[#out_msgs + 1] = message(HS.client_key_exchange, cke_body)
  vim.list_extend(h.transcript, out_msgs)
  local master, write_cipher, server_keys = key_schedule(h, premaster)
  local fin = message(HS.finished, verify_data(h, master, "client finished"))
  h.transcript[#h.transcript + 1] = fin
  local wire = {}
  for _, m in ipairs(out_msgs) do
    wire[#wire + 1] = record.header(TYPE.handshake, #m) .. m
  end
  wire[#wire + 1] = record.header(TYPE.change_cipher_spec, 1) .. "\1"
  wire[#wire + 1] = write_cipher:seal(TYPE.handshake, fin)
  io:raw_write(table.concat(wire))
  -- Server ChangeCipherSpec and Finished.
  if next_handshake(h) ~= "ccs" then
    fail("expected ChangeCipherSpec from the server")
  end
  h.read_cipher = protection(s, unpack(server_keys))
  local t, body = next_handshake(h)
  if t ~= HS.finished then
    fail("expected server Finished, got handshake message %s", tostring(t))
  end
  if not util.equal(body, verify_data(h, master, "server finished")) then
    fail("server Finished verification failed")
  end
  return {
    version = 0x0303,
    suite = ctx.suite,
    suite_name = s.name,
    read = h.read_cipher,
    write = write_cipher,
    cert = cert,
    leftover = h.hbuf,
    etm = server_keys[4],
    ems = ctx.ems,
  }
end

return M
