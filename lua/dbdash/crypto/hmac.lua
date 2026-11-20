-- HMAC (RFC 2104) over any dbdash.crypto hash, with precomputed key states so repeated
-- MACs with one key (PBKDF2) cost two compressions each.
local util = require("dbdash.crypto.util")

local M = {}

---Keyed MAC function for a hash module.
---@param hash table hash module (new, block, digest)
---@param key string
---@return fun(msg: string): string
function M.keyed(hash, key)
  if #key > hash.block then
    key = hash.digest(key)
  end
  key = key .. string.rep("\0", hash.block - #key)
  local ipad = util.xor(key, string.rep("\54", hash.block))
  local opad = util.xor(key, string.rep("\92", hash.block))
  local inner = hash.new():update(ipad)
  local outer = hash.new():update(opad)
  return function(msg)
    local ih = inner:copy():update(msg):final()
    return outer:copy():update(ih):final()
  end
end

---HMAC(key, msg).
function M.hmac(hash, key, msg)
  return M.keyed(hash, key)(msg)
end

return M
