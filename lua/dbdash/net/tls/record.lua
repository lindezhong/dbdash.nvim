-- TLS record layer (RFC 8446 §5, RFC 5246 §6): framing, AEAD and CBC protection, sequence numbers.
local bit = require("bit")

local M = {}

M.TYPE = { change_cipher_spec = 20, alert = 21, handshake = 22, application_data = 23 }
M.MAX_PLAINTEXT = 16384

local ALERTS = {
  [0] = "close_notify", [10] = "unexpected_message", [20] = "bad_record_mac",
  [22] = "record_overflow", [40] = "handshake_failure", [42] = "bad_certificate",
  [43] = "unsupported_certificate", [44] = "certificate_revoked", [45] = "certificate_expired",
  [46] = "certificate_unknown", [47] = "illegal_parameter", [48] = "unknown_ca",
  [49] = "access_denied", [50] = "decode_error", [51] = "decrypt_error",
  [70] = "protocol_version", [71] = "insufficient_security", [80] = "internal_error",
  [86] = "inappropriate_fallback", [90] = "user_canceled", [109] = "missing_extension",
  [110] = "unsupported_extension", [112] = "unrecognized_name", [116] = "certificate_required",
  [120] = "no_application_protocol",
}
M.ALERTS = ALERTS

local function fail(msg, ...)
  error({ phase = "tls", message = msg:format(...) }, 0)
end
M.fail = fail

---Traffic protection for one direction.
---@class dbdash.tls.Cipher
---@field aead dbdash.crypto.Aead
---@field iv string 12 bytes
---@field seq integer
local Cipher = {}
Cipher.__index = Cipher

function M.cipher(aead, iv)
  return setmetatable({ aead = aead, iv = iv, seq = 0 }, Cipher)
end

function Cipher:nonce()
  local s = self.seq
  local seq = {}
  for i = 12, 1, -1 do
    seq[i] = s % 256
    s = math.floor(s / 256)
  end
  local out = {}
  for i = 1, 12 do
    out[i] = string.char(bit.bxor(self.iv:byte(i), seq[i]))
  end
  self.seq = self.seq + 1
  return table.concat(out)
end

local function header(typ, len)
  return string.char(typ, 3, 3, math.floor(len / 256), len % 256)
end
M.header = header

---Protect one record: returns the full wire record.
function Cipher:seal(typ, content)
  local inner = content .. string.char(typ)
  local len = #inner + self.aead.tag_size
  local hdr = header(M.TYPE.application_data, len)
  return hdr .. self.aead:seal(self:nonce(), inner, hdr)
end

---Unprotect a record body (with its 5-byte header as AAD). Returns content type, content.
function Cipher:open(hdr, body)
  local inner = self.aead:open(self:nonce(), body, hdr)
  if not inner then
    fail("record authentication failed (bad_record_mac)")
  end
  local i = #inner
  while i > 0 and inner:byte(i) == 0 do
    i = i - 1
  end
  if i == 0 then
    fail("record without content type")
  end
  return inner:byte(i), inner:sub(1, i - 1)
end

-- TLS 1.2 record protection (RFC 5246, RFC 5288, RFC 7905, RFC 7366) -----------------------

local util = require("dbdash.crypto.util")

local function seq8(n)
  local out = {}
  for i = 8, 1, -1 do
    out[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(out)
end
M.seq8 = seq8

local function u16(n)
  return string.char(math.floor(n / 256), n % 256)
end

---AEAD protection: GCM (4-byte implicit IV + 8-byte explicit nonce sent with each record)
---or ChaCha20-Poly1305 (12-byte IV XOR the sequence number, nothing sent).
local Aead12 = {}
Aead12.__index = Aead12

function M.aead12(aead, iv, explicit)
  return setmetatable({ aead = aead, iv = iv, explicit = explicit, seq = 0 }, Aead12)
end

function Aead12:nonce(explicit_part)
  if self.explicit then
    return self.iv .. explicit_part
  end
  local s = string.rep("\0", 4) .. explicit_part
  local out = {}
  for i = 1, 12 do
    out[i] = string.char(bit.bxor(self.iv:byte(i), s:byte(i)))
  end
  return table.concat(out)
end

function Aead12:seal(typ, content)
  local s = seq8(self.seq)
  self.seq = self.seq + 1
  local aad = s .. string.char(typ, 3, 3) .. u16(#content)
  local ct = self.aead:seal(self:nonce(s), content, aad)
  local body = (self.explicit and s or "") .. ct
  return header(typ, #body) .. body
end

function Aead12:open(hdr, body)
  local typ = hdr:byte(1)
  local s = seq8(self.seq)
  self.seq = self.seq + 1
  local explicit_part = s
  if self.explicit then
    if #body < 8 + 16 then
      fail("record too short (bad_record_mac)")
    end
    explicit_part, body = body:sub(1, 8), body:sub(9)
  end
  local aad = s .. string.char(typ, 3, 3) .. u16(#body - 16)
  local pt = self.aead:open(self:nonce(explicit_part), body, aad)
  if not pt then
    fail("record authentication failed (bad_record_mac)")
  end
  return typ, pt
end

---CBC protection with HMAC: MAC-then-encrypt, or encrypt-then-MAC when negotiated.
local Cbc12 = {}
Cbc12.__index = Cbc12

---@param key string AES key
---@param mac_hash table hash module (sha1, sha256 or sha384)
function M.cbc12(key, mac_hash, mac_key, etm)
  local aes = require("dbdash.crypto.aes")
  return setmetatable({
    ks = aes.expand(key),
    mac = require("dbdash.crypto.hmac").keyed(mac_hash, mac_key),
    mac_len = mac_hash.size,
    etm = etm,
    seq = 0,
  }, Cbc12)
end

local function pad(data)
  local n = 15 - #data % 16
  return data .. string.rep(string.char(n), n + 1)
end

function Cbc12:seal(typ, content)
  local aes = require("dbdash.crypto.aes")
  local s = seq8(self.seq)
  self.seq = self.seq + 1
  local iv = require("dbdash.crypto.random").bytes(16)
  local body
  if self.etm then
    local ct = iv .. aes.cbc_encrypt(self.ks, iv, pad(content))
    body = ct .. self.mac(s .. string.char(typ, 3, 3) .. u16(#ct) .. ct)
  else
    local mac = self.mac(s .. string.char(typ, 3, 3) .. u16(#content) .. content)
    body = iv .. aes.cbc_encrypt(self.ks, iv, pad(content .. mac))
  end
  return header(typ, #body) .. body
end

---Check and strip padding without branching on secret data; returns content length and
---a 0/1 flag for the padding check.
local function unpad(pt, mac_len)
  local n = #pt
  local padlen = pt:byte(n)
  local good = 1
  if padlen + 1 + mac_len > n then
    good, padlen = 0, 0
  end
  -- Look at the last 256 bytes so the work does not depend on padlen.
  for i = 1, math.min(256, n) do
    local inside = i <= padlen + 1 and 1 or 0
    local same = pt:byte(n - i + 1) == padlen and 1 or 0
    good = bit.band(good, bit.bor(1 - inside, same))
  end
  return n - padlen - 1, good
end

function Cbc12:open(hdr, body)
  local aes = require("dbdash.crypto.aes")
  local typ = hdr:byte(1)
  local s = seq8(self.seq)
  self.seq = self.seq + 1
  local ml = self.mac_len
  if self.etm then
    if #body < 32 + ml or (#body - ml) % 16 ~= 0 then
      fail("bad record length (bad_record_mac)")
    end
    local ct, tag = body:sub(1, -ml - 1), body:sub(-ml)
    if not util.equal(self.mac(s .. string.char(typ, 3, 3) .. u16(#ct) .. ct), tag) then
      fail("record authentication failed (bad_record_mac)")
    end
    local pt = aes.cbc_decrypt(self.ks, ct:sub(1, 16), ct:sub(17))
    local len, good = unpad(pt, 0)
    if good ~= 1 then
      fail("bad record padding (bad_record_mac)")
    end
    return typ, pt:sub(1, len)
  end
  if #body < 16 + math.max(16, ml + 1) or #body % 16 ~= 0 then
    fail("bad record length (bad_record_mac)")
  end
  local pt = aes.cbc_decrypt(self.ks, body:sub(1, 16), body:sub(17))
  local len, good = unpad(pt, ml)
  local content = pt:sub(1, len - ml)
  local tag = pt:sub(len - ml + 1, len)
  local mac_ok = util.equal(self.mac(s .. string.char(typ, 3, 3) .. u16(#content) .. content), tag)
  -- One error for padding and MAC failures (no padding oracle).
  if good ~= 1 or not mac_ok then
    fail("record authentication failed (bad_record_mac)")
  end
  return typ, content
end

---Read one record from the socket: type, header, body.
function M.read(sock)
  local hdr = sock:raw_read_exact(5)
  local len = hdr:byte(4) * 256 + hdr:byte(5)
  if len > M.MAX_PLAINTEXT + 256 then
    fail("record too large (%d bytes)", len)
  end
  return hdr:byte(1), hdr, sock:raw_read_exact(len)
end

---Raise for a received alert.
function M.alert(content)
  local level, desc = content:byte(1), content:byte(2)
  local name = ALERTS[desc] or ("alert " .. tostring(desc))
  if desc == 0 then
    error({ phase = "connect", message = "connection closed by the server (close_notify)", tls_closed = true }, 0)
  end
  fail("server sent %s alert: %s", level == 2 and "fatal" or "warning", name)
end

return M
