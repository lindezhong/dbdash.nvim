-- TLS 1.2 PRF (RFC 5246 §5): P_hash with HMAC-SHA256 or HMAC-SHA384.
local hmac = require("dbdash.crypto.hmac")

local M = {}

---PRF(secret, label, seed) truncated to `len` bytes.
---@param hash table hash module (sha256 or sha384)
function M.prf(hash, secret, label, seed, len)
  local mac = hmac.keyed(hash, secret)
  local s = label .. seed
  local a = s
  local out, have = {}, 0
  while have < len do
    a = mac(a)
    local block = mac(a .. s)
    out[#out + 1] = block
    have = have + #block
  end
  return table.concat(out):sub(1, len)
end

return M
