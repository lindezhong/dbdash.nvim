-- Byte-string helpers for the crypto modules.
local bit = require("bit")

local M = {}

function M.hex(s)
  return (s:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

function M.unhex(h)
  h = h:gsub("%s", "")
  return (h:gsub("%x%x", function(x)
    return string.char(tonumber(x, 16))
  end))
end

---Bytewise XOR of two equal-length strings.
function M.xor(a, b)
  assert(#a == #b, "xor: length mismatch")
  local out = {}
  for i = 1, #a do
    out[i] = string.char(bit.bxor(a:byte(i), b:byte(i)))
  end
  return table.concat(out)
end

---Big-endian 32-bit integer as 4 bytes.
function M.be32(n)
  return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255), bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
end

---Comparison that does not stop at the first difference.
function M.equal(a, b)
  if #a ~= #b then
    return false
  end
  local d = 0
  for i = 1, #a do
    d = bit.bor(d, bit.bxor(a:byte(i), b:byte(i)))
  end
  return d == 0
end

return M
