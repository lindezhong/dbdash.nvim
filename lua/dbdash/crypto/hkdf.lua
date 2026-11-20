-- HKDF (RFC 5869) and the TLS 1.3 HKDF-Expand-Label (RFC 8446 §7.1).
local hmac = require("dbdash.crypto.hmac")

local M = {}

function M.extract(hash, salt, ikm)
  if salt == nil or salt == "" then
    salt = string.rep("\0", hash.size)
  end
  return hmac.hmac(hash, salt, ikm)
end

function M.expand(hash, prk, info, len)
  local prf = hmac.keyed(hash, prk)
  local out, t, i = {}, "", 1
  local have = 0
  while have < len do
    t = prf(t .. info .. string.char(i))
    out[#out + 1] = t
    have = have + #t
    i = i + 1
  end
  return table.concat(out):sub(1, len)
end

---HKDF-Expand-Label(secret, label, context, length) with the "tls13 " prefix.
function M.expand_label(hash, secret, label, context, len)
  local full = "tls13 " .. label
  local info = string.char(math.floor(len / 256), len % 256)
    .. string.char(#full)
    .. full
    .. string.char(#context)
    .. context
  return M.expand(hash, secret, info, len)
end

return M
