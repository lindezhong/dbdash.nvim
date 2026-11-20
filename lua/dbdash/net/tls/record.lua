-- TLS 1.3 record layer (RFC 8446 §5): framing, AEAD protection and sequence numbers.
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
