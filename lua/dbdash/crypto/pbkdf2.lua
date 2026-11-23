-- PBKDF2 (RFC 8018) with HMAC.
local checkpoint = require("dbdash.util.async").checkpoint -- yields inside tasks only
local bit = require("bit")
local hmac = require("dbdash.crypto.hmac")
local util = require("dbdash.crypto.util")

local M = {}

local function xor_into(acc, s)
  for i = 1, #s do
    acc[i] = bit.bxor(acc[i], s:byte(i))
  end
end

---@param hash table hash module
---@param password string
---@param salt string
---@param iterations integer
---@param dklen integer? defaults to the hash size
---@return string
function M.derive(hash, password, salt, iterations, dklen)
  dklen = dklen or hash.size
  local prf = hmac.keyed(hash, password)
  local out = {}
  local block = 1
  while #table.concat(out) < dklen do
    local u = prf(salt .. util.be32(block))
    local acc = { u:byte(1, -1) }
    for _ = 2, iterations do
      u = prf(u)
      xor_into(acc, u)
      checkpoint() -- SCRAM uses thousands of iterations: let the editor breathe
    end
    out[#out + 1] = string.char(unpack(acc))
    block = block + 1
  end
  return table.concat(out):sub(1, dklen)
end

return M
