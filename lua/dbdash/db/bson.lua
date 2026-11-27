-- BSON encoding/decoding for the MongoDB driver.
--
-- Encoding takes Lua values from dbdash.db.json.parse: ordered mappings become documents,
-- lists arrays, integers int32/int64, json.double boxes doubles, and Extended JSON wrappers
-- ({"$oid": ...}, {"$date": ...}, {"$numberLong": ...}, {"$numberDecimal": ...},
-- {"$regex": ..., "$options": ...}, {"$numberInt"}, {"$numberDouble"}) their BSON types.
-- Decoding returns tagged values (see M.decode) that the driver maps to logical types.
local bit = require("bit")
local ffi = require("ffi")
local json = require("dbdash.util.json")
local map = require("dbdash.util.map")

local M = {}

local NULL = vim.NIL

local function fail(msg, ...)
  require("dbdash.util.error").raise("query", msg:format(...))
end

-- Little-endian helpers ---------------------------------------------------------------------

local function i32(n)
  n = n % 4294967296
  return string.char(
    n % 256,
    math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 16777216) % 256
  )
end

---int64 from a Lua number (|n| < 2^53) or decimal string.
local function i64(v)
  local x = type(v) == "string" and ffi.new("int64_t", 0) or nil
  if x then
    local neg = v:sub(1, 1) == "-"
    for d in v:gsub("^[-+]", ""):gmatch("%d") do
      x = x * 10 + tonumber(d)
    end
    if neg then
      x = -x
    end
  else
    x = ffi.new("int64_t", v)
  end
  local u = ffi.cast("uint64_t", x)
  local out = {}
  for k = 0, 7 do
    out[k + 1] = string.char(tonumber(bit.band(bit.rshift(u, k * 8), 0xff)))
  end
  return table.concat(out)
end

local function f64(v)
  local buf = ffi.new("double[1]", v)
  return ffi.string(buf, 8)
end

local function rd_i32(s, p)
  local a, b, c, d = s:byte(p, p + 3)
  local n = a + b * 256 + c * 65536 + d * 16777216
  if n >= 2147483648 then
    n = n - 4294967296
  end
  return n
end

---int64 at p as a Lua number when exact, else a decimal string.
local function rd_i64(s, p)
  local buf = ffi.new("int64_t[1]")
  ffi.copy(buf, s:sub(p, p + 7), 8)
  local v = buf[0]
  if v >= -9007199254740992LL and v <= 9007199254740992LL then
    return tonumber(v)
  end
  return (tostring(v):gsub("LL$", ""))
end

local function rd_f64(s, p)
  local buf = ffi.new("double[1]")
  ffi.copy(buf, s:sub(p, p + 7), 8)
  return buf[0]
end

-- Encoding --------------------------------------------------------------------------------

local encode_doc

local function cstring(s)
  if s:find("\0", 1, true) then
    fail("BSON keys cannot contain NUL bytes")
  end
  return s .. "\0"
end

local function oid_bytes(hex)
  if type(hex) ~= "string" or not hex:match("^%x+$") or #hex ~= 24 then
    fail("$oid must be 24 hex characters")
  end
  return (hex:gsub("%x%x", function(h)
    return string.char(tonumber(h, 16))
  end))
end

---Encode an element: type byte, name, value bytes.
local function element(name, v)
  local k = cstring(tostring(name))
  if v == nil or v == NULL then
    return "\10" .. k
  end
  local t = type(v)
  if t == "boolean" then
    return "\8" .. k .. (v and "\1" or "\0")
  elseif t == "number" then
    if v == math.floor(v) and v >= -2147483648 and v <= 2147483647 then
      return "\16" .. k .. i32(v)
    elseif v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return "\18" .. k .. i64(v)
    end
    return "\1" .. k .. f64(v)
  elseif t == "string" then
    return "\2" .. k .. i32(#v + 1) .. v .. "\0"
  elseif json.is_double(v) then
    return "\1" .. k .. f64(v.v)
  elseif json.is_int64(v) then
    return "\18" .. k .. i64(v.s)
  elseif map.is_map(v) then
    local keys = map.keys(v)
    local first = keys[1]
    if #keys == 1 and first == "$oid" then
      return "\7" .. k .. oid_bytes(v["$oid"])
    elseif #keys == 1 and first == "$date" then
      local d = v["$date"]
      local ms
      if type(d) == "number" then
        ms = d
      elseif type(d) == "string" then
        local err
        ms, err = require("dbdash.util.time").iso_to_ms(d)
        if not ms then
          fail("%s", err)
        end
      elseif map.is_map(d) and d["$numberLong"] then
        return "\9" .. k .. i64(d["$numberLong"])
      else
        fail("unsupported $date value")
      end
      return "\9" .. k .. i64(ms)
    elseif #keys == 1 and first == "$numberLong" then
      return "\18" .. k .. i64(tostring(v["$numberLong"]))
    elseif #keys == 1 and first == "$numberInt" then
      return "\16" .. k .. i32(tonumber(v["$numberInt"]))
    elseif #keys == 1 and first == "$numberDouble" then
      return "\1" .. k .. f64(tonumber(v["$numberDouble"]))
    elseif #keys == 1 and first == "$numberDecimal" then
      fail("$numberDecimal values are not supported in queries; use a double or a string")
    elseif #keys == 1 and first == "$binary" then
      local b = v["$binary"]
      local data, sub = b, 0
      if map.is_map(b) then -- Extended JSON: {"base64": ..., "subType": "00"}
        data = vim.base64.decode(b.base64 or "")
        sub = tonumber(b.subType or "0", 16) or 0
      end
      return "\5" .. k .. i32(#data) .. string.char(sub) .. data
    elseif first == "$regex" and #keys <= 2 then
      return "\11" .. k .. cstring(v["$regex"]) .. cstring(v["$options"] or "")
    end
    return "\3" .. k .. encode_doc(v)
  elseif t == "table" then
    local m = map.new()
    for i, x in ipairs(v) do
      map.set(m, tostring(i - 1), x)
    end
    return "\4" .. k .. encode_doc(m)
  end
  fail("cannot encode a %s value in BSON", t)
end

---Encode an ordered mapping as a BSON document.
function encode_doc(m)
  local parts = {}
  for k, v in map.pairs(m) do
    parts[#parts + 1] = element(k, v)
  end
  local body = table.concat(parts)
  return i32(#body + 5) .. body .. "\0"
end
M.encode = encode_doc

-- Decoding --------------------------------------------------------------------------------

---Tagged values for types without a natural Lua form.
local Tagged = {}
Tagged.__index = Tagged
M.Tagged = Tagged

local function tagged(kind, value)
  return setmetatable({ kind = kind, value = value }, Tagged)
end

function M.is_tagged(v)
  return getmetatable(v) == Tagged
end

---Milliseconds since the epoch -> "YYYY-MM-DDTHH:MM:SS.mmmZ".
function M.ms_to_iso(ms)
  local secs = math.floor(ms / 1000)
  local msr = ms - secs * 1000
  local days = math.floor(secs / 86400)
  local rem = secs - days * 86400
  -- civil_from_days
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor(
    (doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365
  )
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then
    y = y + 1
  end
  return ("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"):format(
    y,
    m,
    d,
    math.floor(rem / 3600),
    math.floor(rem % 3600 / 60),
    rem % 60,
    msr
  )
end

---Decode a Decimal128 (IEEE 754-2008 BID) to its string form.
function M.decimal128(b)
  local lo = ffi.new("uint64_t[1]")
  local hi = ffi.new("uint64_t[1]")
  ffi.copy(lo, b:sub(1, 8), 8)
  ffi.copy(hi, b:sub(9, 16), 8)
  local h = hi[0]
  local sign = bit.band(bit.rshift(h, 63), 1ULL) == 1ULL
  local comb = tonumber(bit.band(bit.rshift(h, 58), 0x1fULL))
  if comb == 0x1e then
    return sign and "-Infinity" or "Infinity"
  elseif comb == 0x1f then
    return "NaN"
  end
  local exp, coeff_hi
  if bit.band(bit.rshift(h, 61), 3ULL) == 3ULL then
    -- Non-canonical (coefficient > 2^113): treated as zero.
    exp = tonumber(bit.band(bit.rshift(h, 47), 0x3fffULL))
    coeff_hi = 0ULL
    lo[0] = 0ULL
  else
    exp = tonumber(bit.band(bit.rshift(h, 49), 0x3fffULL))
    coeff_hi = bit.band(h, 0x1ffffffffffffULL)
  end
  exp = exp - 6176
  -- Coefficient = coeff_hi * 2^64 + lo, as decimal digits (long division by 10 on 32-bit limbs).
  local limbs = {
    tonumber(bit.rshift(coeff_hi, 32)),
    tonumber(bit.band(coeff_hi, 0xffffffffULL)),
    tonumber(bit.rshift(lo[0], 32)),
    tonumber(bit.band(lo[0], 0xffffffffULL)),
  }
  local digits = {}
  local function zero()
    return limbs[1] == 0 and limbs[2] == 0 and limbs[3] == 0 and limbs[4] == 0
  end
  repeat
    local rem = 0
    for i = 1, 4 do
      local cur = rem * 4294967296 + limbs[i]
      limbs[i] = math.floor(cur / 10)
      rem = cur - limbs[i] * 10
    end
    table.insert(digits, 1, tostring(rem))
  until zero()
  local s = table.concat(digits)
  if exp < 0 then
    local point = #s + exp
    if point > 0 then
      s = s:sub(1, point) .. "." .. s:sub(point + 1)
    else
      s = "0." .. string.rep("0", -point) .. s
    end
  elseif exp > 0 then
    s = s .. string.rep("0", exp)
  end
  return (sign and "-" or "") .. s
end

local decode_doc

local function decode_value(t, s, p)
  if t == 0x01 then
    return rd_f64(s, p), p + 8
  elseif t == 0x02 or t == 0x0D or t == 0x0E then
    local n = rd_i32(s, p)
    return s:sub(p + 4, p + 4 + n - 2), p + 4 + n
  elseif t == 0x03 then
    return decode_doc(s, p, false)
  elseif t == 0x04 then
    return decode_doc(s, p, true)
  elseif t == 0x05 then
    local n = rd_i32(s, p)
    return tagged("binary", s:sub(p + 5, p + 4 + n)), p + 5 + n
  elseif t == 0x06 or t == 0x0A or t == 0xFF or t == 0x7F then
    return NULL, p
  elseif t == 0x07 then
    return tagged("oid", (s:sub(p, p + 11):gsub(".", function(c)
      return ("%02x"):format(c:byte())
    end))),
      p + 12
  elseif t == 0x08 then
    return s:byte(p) == 1, p + 1
  elseif t == 0x09 then
    local ms = rd_i64(s, p)
    return tagged("date", type(ms) == "number" and M.ms_to_iso(ms) or ms), p + 8
  elseif t == 0x0B then
    local z1 = s:find("\0", p, true)
    local z2 = s:find("\0", z1 + 1, true)
    return tagged("regex", "/" .. s:sub(p, z1 - 1) .. "/" .. s:sub(z1 + 1, z2 - 1)), z2 + 1
  elseif t == 0x10 then
    return rd_i32(s, p), p + 4
  elseif t == 0x11 then
    return tagged("timestamp", rd_i32(s, p + 4) % 4294967296), p + 8
  elseif t == 0x12 then
    return rd_i64(s, p), p + 8
  elseif t == 0x13 then
    return tagged("decimal", M.decimal128(s:sub(p, p + 15))), p + 16
  elseif t == 0x0C then -- DBPointer (deprecated)
    local n = rd_i32(s, p)
    return NULL, p + 4 + n + 12
  elseif t == 0x0F then -- code with scope
    local n = rd_i32(s, p)
    return tagged("code", "<code>"), p + n
  end
  fail("unsupported BSON type 0x%02x", t)
end

---Decode a document at position p. Returns value and the position after it.
function decode_doc(s, p, as_array)
  local len = rd_i32(s, p)
  local stop = p + len - 1
  p = p + 4
  local out = as_array and {} or map.new()
  while p < stop do
    local t = s:byte(p)
    local z = s:find("\0", p + 1, true)
    local name = s:sub(p + 1, z - 1)
    local v
    v, p = decode_value(t, s, z + 1)
    if as_array then
      out[#out + 1] = v
    else
      map.set(out, name, v)
    end
  end
  return out, stop + 1
end

---Decode a complete BSON document.
function M.decode(s, p)
  return (decode_doc(s, p or 1, false))
end

M.i32 = i32
M.rd_i32 = rd_i32
M.rd_i64 = rd_i64

return M
