-- Merkle-Damgard framing shared by MD5, SHA-1 and SHA-256: buffering, padding and the
-- incremental hash object (update / final / copy).
local M = {}

---@class dbdash.crypto.Hash
---@field update fun(self, data: string): dbdash.crypto.Hash
---@field final fun(self): string
---@field copy fun(self): dbdash.crypto.Hash

---Build a hash constructor.
---@param o { block: integer, init: fun(): table, compress: fun(H: table, s: string, off: integer), digest: fun(H: table): string, length: fun(bits: number): string }
function M.define(o)
  local Hash = {}
  Hash.__index = Hash

  function Hash:update(data)
    local buf = self.buf .. data
    self.len = self.len + #data
    local n = #buf - #buf % o.block
    for off = 1, n, o.block do
      o.compress(self.H, buf, off)
    end
    self.buf = buf:sub(n + 1)
    return self
  end

  function Hash:final()
    local bits = self.len * 8
    local pad_len = o.block - ((self.len + 1 + o.block / 8) % o.block)
    if pad_len == o.block then
      pad_len = 0
    end
    self:update("\128" .. string.rep("\0", pad_len) .. o.length(bits))
    return o.digest(self.H)
  end

  function Hash:copy()
    local H = {}
    for i, v in pairs(self.H) do
      H[i] = v
    end
    return setmetatable({ H = H, buf = self.buf, len = self.len }, Hash)
  end

  local new = function()
    return setmetatable({ H = o.init(), buf = "", len = 0 }, Hash)
  end
  return {
    new = new,
    block = o.block,
    ---One-shot digest.
    digest = function(data)
      return new():update(data):final()
    end,
  }
end

---Big-endian 64-bit length field (bit counts stay below 2^53).
function M.be64(bits)
  local hi = math.floor(bits / 4294967296)
  local lo = bits % 4294967296
  local u = require("dbdash.crypto.util")
  return u.be32(hi) .. u.be32(lo)
end

---Little-endian 64-bit length field (MD5).
function M.le64(bits)
  return M.be64(bits):reverse()
end

return M
