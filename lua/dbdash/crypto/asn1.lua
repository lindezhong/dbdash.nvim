-- Minimal DER reader: enough to walk certificates and public keys (:help dbdash-tls).
local bit = require("bit")

local M = {}

M.TAG = {
  INTEGER = 0x02,
  BIT_STRING = 0x03,
  OCTET_STRING = 0x04,
  NULL = 0x05,
  OID = 0x06,
  SEQUENCE = 0x30,
  SET = 0x31,
}

---@class dbdash.asn1.Node
---@field tag integer
---@field value string contents bytes
---@field raw string the whole TLV (for hashing signed parts)
---@field children dbdash.asn1.Node[]? for constructed types

---@return any (it raises: `x or fail(...)` keeps x's type)
local function fail(msg)
  require("dbdash.util.error").raise("tls", "ASN.1: " .. msg)
end

---Read one TLV at `pos`. Returns node and the position after it.
function M.read(s, pos)
  pos = pos or 1
  local start = pos
  local tag = s:byte(pos)
  if not tag then
    fail("unexpected end of data")
  end
  if tag % 32 == 31 then
    fail("high tag numbers are not supported")
  end
  local len = s:byte(pos + 1)
  if not len then
    fail("truncated length")
  end
  pos = pos + 2
  if len >= 0x80 then
    local nb = len - 0x80
    if nb == 0 or nb > 4 then
      fail("unsupported length encoding")
    end
    len = 0
    for i = 0, nb - 1 do
      len = len * 256 + s:byte(pos + i)
    end
    pos = pos + nb
  end
  if pos + len - 1 > #s then
    fail("length exceeds data")
  end
  local node = { tag = tag, value = s:sub(pos, pos + len - 1), raw = s:sub(start, pos + len - 1) }
  if bit.band(tag, 0x20) ~= 0 then
    node.children = {}
    local p = 1
    while p <= #node.value do
      local child
      child, p = M.read(node.value, p)
      node.children[#node.children + 1] = child
    end
  end
  return node, pos + len
end

---Parse a complete DER blob.
function M.parse(der)
  local node, after = M.read(der, 1)
  if after ~= #der + 1 then
    fail("trailing data after DER structure")
  end
  return node
end

---Dotted OID string.
function M.oid(node)
  local s = node.value
  local first = s:byte(1)
  local parts = { math.floor(first / 40), first % 40 }
  local v = 0
  for i = 2, #s do
    local b = s:byte(i)
    v = v * 128 + b % 128
    if b < 128 then
      parts[#parts + 1] = v
      v = 0
    end
  end
  return table.concat(parts, ".")
end

---INTEGER contents without the sign padding byte.
function M.unsigned(node)
  local v = node.value
  if #v > 1 and v:byte(1) == 0 then
    return v:sub(2)
  end
  return v
end

---BIT STRING contents (drops the unused-bits byte).
function M.bits(node)
  return node.value:sub(2)
end

---Decode PEM text to DER for the first block with `label` (or any label).
function M.pem(text, label)
  local pat = label
      and ("%-%-%-%-%-BEGIN " .. label:gsub("%-", "%%-") .. "%-%-%-%-%-(.-)%-%-%-%-%-END")
    or "%-%-%-%-%-BEGIN [^%-]+%-%-%-%-%-(.-)%-%-%-%-%-END"
  local body = text:match(pat)
  if not body then
    fail("no PEM block found")
  end
  return vim.base64.decode((body:gsub("%s", "")))
end

return M
