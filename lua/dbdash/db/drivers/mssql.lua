-- SQL Server driver (design §8.4): TDS 7.4, optionally encrypted (TLS negotiated in
-- PRELOGIN, or TDS 8 strict mode), SQL authentication via LOGIN7, SQL_BATCH, and
-- COLMETADATA / ROW / NBCROW decoding.
local bit = require("bit")
local ffi = require("ffi")
local dberr = require("dbdash.util.error")
local resultset = require("dbdash.db.resultset")
local socket = require("dbdash.net.socket")

local M = {
  name = "mssql",
  schemes = { "mssql", "sqlserver" },
  dialect = "mssql",
  capabilities = { tls = true, sql = true, query_language = "sql" },
}

local NULL = vim.NIL

local PKT = { SQL_BATCH = 0x01, REPLY = 0x04, ATTENTION = 0x06, LOGIN7 = 0x10, PRELOGIN = 0x12 }
local PACKET_SIZE = 4096

-- Little-endian helpers ---------------------------------------------------------------------

local function le(n, bytes)
  local out = {}
  for i = 1, bytes do
    out[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(out)
end

local function rd_u(s, p, bytes)
  local n = 0
  for i = bytes - 1, 0, -1 do
    n = n * 256 + s:byte(p + i)
  end
  return n
end

local function rd_s(s, p, bytes)
  local n = rd_u(s, p, bytes)
  local lim = 2 ^ (8 * bytes - 1)
  if n >= lim then
    n = n - 2 * lim
  end
  return n
end

---Exact signed little-endian integer of up to 8 bytes (number or decimal string).
local function rd_int(s, p, bytes)
  if bytes <= 4 then
    return rd_s(s, p, bytes)
  end
  local buf = ffi.new("int64_t[1]")
  ffi.copy(buf, s:sub(p, p + 7), 8)
  local v = buf[0]
  if v >= -9007199254740992LL and v <= 9007199254740992LL then
    return tonumber(v)
  end
  return (tostring(v):gsub("LL$", ""))
end

-- Text encodings ----------------------------------------------------------------------------

---UTF-8 -> UTF-16LE.
function M.utf16(s)
  local bytes = {}
  local i = 1
  while i <= #s do
    local c = s:byte(i)
    local cp, n
    if c < 0x80 then
      cp, n = c, 1
    elseif c < 0xE0 then
      cp, n = bit.band(c, 0x1F), 2
    elseif c < 0xF0 then
      cp, n = bit.band(c, 0x0F), 3
    else
      cp, n = bit.band(c, 0x07), 4
    end
    for k = 1, n - 1 do
      cp = cp * 64 + bit.band(s:byte(i + k) or 0x80, 0x3F)
    end
    i = i + n
    if cp >= 0x10000 then
      cp = cp - 0x10000
      bytes[#bytes + 1] = le(0xD800 + math.floor(cp / 0x400), 2) .. le(0xDC00 + cp % 0x400, 2)
    else
      bytes[#bytes + 1] = le(cp, 2)
    end
  end
  return table.concat(bytes)
end

---UTF-16LE -> UTF-8.
function M.utf8(s)
  local out = {}
  local utf8 = require("dbdash.util.utf8")
  local i = 1
  while i + 1 <= #s do
    local u = s:byte(i) + s:byte(i + 1) * 256
    i = i + 2
    if u >= 0xD800 and u <= 0xDBFF and i + 1 <= #s then
      local lo = s:byte(i) + s:byte(i + 1) * 256
      if lo >= 0xDC00 and lo <= 0xDFFF then
        u = 0x10000 + (u - 0xD800) * 0x400 + (lo - 0xDC00)
        i = i + 2
      end
    end
    out[#out + 1] = utf8.char(u)
  end
  return table.concat(out)
end

---Single-byte (Windows-1252 / Latin-1) text -> UTF-8.
local function latin1(s)
  if not s:find("[\128-\255]") then
    return s
  end
  local utf8 = require("dbdash.util.utf8")
  return (s:gsub("[\128-\255]", function(c)
    return utf8.char(c:byte())
  end))
end

-- Packets ---------------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

function Conn:send(typ, payload)
  local max = self.packet_size - 8
  local id = 1
  local out = {}
  repeat
    local chunk = payload:sub(1, max)
    payload = payload:sub(max + 1)
    local last = #payload == 0
    out[#out + 1] = string.char(
      typ,
      last and 1 or 0,
      math.floor((#chunk + 8) / 256),
      (#chunk + 8) % 256,
      0,
      0,
      id % 256,
      0
    ) .. chunk
    id = id + 1
  until last
  self.sock:write(table.concat(out))
end

---Read a whole message (packets until end-of-message).
function Conn:recv()
  local parts = {}
  while true do
    local h = self.sock:read_exact(8)
    local len = h:byte(3) * 256 + h:byte(4)
    parts[#parts + 1] = self.sock:read_exact(len - 8)
    if bit.band(h:byte(2), 1) == 1 then
      return table.concat(parts)
    end
  end
end

-- PRELOGIN / LOGIN7 -----------------------------------------------------------------------

local ENCRYPT = { OFF = 0, ON = 1, NOT_SUP = 2, REQ = 3 }

function M.prelogin(encrypt)
  local opts = {
    { 0x00, "\16\0\0\0\0\0" }, -- VERSION
    { 0x01, string.char(encrypt or ENCRYPT.NOT_SUP) }, -- ENCRYPTION
    { 0x02, "\0" }, -- INSTOPT
    { 0x03, "\0\0\0\0" }, -- THREADID
    { 0x04, "\0" }, -- MARS
  }
  local header_len = #opts * 5 + 1
  local head, data = {}, {}
  local offset = header_len
  for _, o in ipairs(opts) do
    head[#head + 1] = string.char(o[1], math.floor(offset / 256), offset % 256, 0, #o[2])
    data[#data + 1] = o[2]
    offset = offset + #o[2]
  end
  return table.concat(head) .. "\255" .. table.concat(data)
end

---Encryption setting from a PRELOGIN response.
function M.parse_prelogin(p)
  local i = 1
  while p:byte(i) ~= 0xFF do
    local token = p:byte(i)
    local off = p:byte(i + 1) * 256 + p:byte(i + 2)
    if token == 0x01 then
      return p:byte(off + 1)
    end
    i = i + 5
  end
end

---TDS password obfuscation: swap nibbles, then XOR 0xA5 (on UTF-16LE bytes).
function M.obfuscate(pw16)
  return (
    pw16:gsub(".", function(c)
      local b = c:byte()
      return string.char(
        bit.bxor(bit.bor(bit.lshift(bit.band(b, 0x0F), 4), bit.rshift(b, 4)), 0xA5)
      )
    end)
  )
end

function M.login7(info)
  local fields = {
    M.utf16(vim.uv.os_gethostname() or "dbdash"),
    M.utf16(info.user or ""),
    M.obfuscate(M.utf16(info.password or "")),
    M.utf16(info.application_name),
    M.utf16(info.host),
    "", -- unused / extension
    M.utf16("dbdash.nvim"),
    "", -- language
    M.utf16(info.database or ""),
  }
  local fixed = 94
  local offsets, data = {}, {}
  local pos = fixed
  for _, f in ipairs(fields) do
    offsets[#offsets + 1] = le(pos, 2) .. le(#f / 2, 2)
    data[#data + 1] = f
    pos = pos + #f
  end
  local body_tail = table.concat(offsets)
    .. string.rep("\0", 6) -- ClientID
    .. le(pos, 2)
    .. le(0, 2) -- SSPI
    .. le(pos, 2)
    .. le(0, 2) -- AtchDBFile
    .. le(pos, 2)
    .. le(0, 2) -- ChangePassword
    .. le(0, 4) -- cbSSPILong
  local head = le(0x74000004, 4) -- TDS 7.4
    .. le(PACKET_SIZE, 4)
    .. le(0x07000000, 4) -- client program version
    .. le(vim.uv.os_getpid() % 65536, 4)
    .. le(0, 4) -- connection id
    .. string.char(0xE0, 0x03, 0x00, 0x00) -- option flags 1, 2, type flags, option flags 3
    .. le(0, 4) -- time zone
    .. le(0x0409, 4) -- LCID
  local login = head .. body_tail .. table.concat(data)
  return le(#login + 4, 4) .. login
end

-- Type info and values --------------------------------------------------------------------

local FIXED = {
  [0x1F] = { 0, "null", "null" },
  [0x30] = { 1, "integer", "tinyint" },
  [0x32] = { 1, "boolean", "bit" },
  [0x34] = { 2, "integer", "smallint" },
  [0x38] = { 4, "integer", "int" },
  [0x7F] = { 8, "integer", "bigint" },
  [0x3B] = { 4, "number", "real" },
  [0x3E] = { 8, "number", "float" },
  [0x3A] = { 4, "datetime", "smalldatetime" },
  [0x3D] = { 8, "datetime", "datetime" },
  [0x3C] = { 8, "decimal", "money" },
  [0x7A] = { 4, "decimal", "smallmoney" },
}

local BYTELEN = {
  [0x26] = { "integer", "int" },
  [0x68] = { "boolean", "bit" },
  [0x6D] = { "number", "float" },
  [0x6E] = { "decimal", "money" },
  [0x6F] = { "datetime", "datetime" },
  [0x24] = { "uuid", "uniqueidentifier" },
  [0x6A] = { "decimal", "decimal" },
  [0x6C] = { "decimal", "numeric" },
  [0x37] = { "decimal", "decimal" },
  [0x3F] = { "decimal", "numeric" },
}

local SCALED = {
  [0x29] = { "time", "time" },
  [0x2A] = { "datetime", "datetime2" },
  [0x2B] = { "datetime", "datetimeoffset" },
}

local USHORT = {
  [0xA7] = { "string", "varchar" },
  [0xAF] = { "string", "char" },
  [0xE7] = { "string", "nvarchar" },
  [0xEF] = { "string", "nchar" },
  [0xA5] = { "bytes", "varbinary" },
  [0xAD] = { "bytes", "binary" },
}

local LONGLEN =
  { [0x23] = { "string", "text" }, [0x63] = { "string", "ntext" }, [0x22] = { "bytes", "image" } }

---Parse TYPE_INFO at p. Returns type descriptor and next position.
local function type_info(s, p)
  local t = s:byte(p)
  p = p + 1
  local d = { id = t }
  if FIXED[t] then
    d.kind, d.size, d.ltype, d.name = "fixed", FIXED[t][1], FIXED[t][2], FIXED[t][3]
  elseif BYTELEN[t] then
    d.kind, d.ltype, d.name = "bytelen", BYTELEN[t][1], BYTELEN[t][2]
    d.max = s:byte(p)
    p = p + 1
    if t == 0x6A or t == 0x6C or t == 0x37 or t == 0x3F then
      d.precision, d.scale = s:byte(p), s:byte(p + 1)
      p = p + 2
    end
  elseif t == 0x28 then
    d.kind, d.ltype, d.name = "bytelen", "date", "date"
  elseif SCALED[t] then
    d.kind, d.ltype, d.name = "bytelen", SCALED[t][1], SCALED[t][2]
    d.scale = s:byte(p)
    p = p + 1
  elseif USHORT[t] then
    d.kind, d.ltype, d.name = "ushort", USHORT[t][1], USHORT[t][2]
    d.max = rd_u(s, p, 2)
    p = p + 2
    if t == 0xA7 or t == 0xAF or t == 0xE7 or t == 0xEF then
      d.collation = s:sub(p, p + 4)
      p = p + 5
    end
    if d.max == 0xFFFF then
      d.kind = "plp"
      d.name = d.name .. "(max)"
    end
  elseif LONGLEN[t] then
    d.kind, d.ltype, d.name = "longlen", LONGLEN[t][1], LONGLEN[t][2]
    d.max = rd_u(s, p, 4)
    p = p + 4
    if t ~= 0x22 then
      p = p + 5 -- collation
    end
    local parts = s:byte(p)
    p = p + 1
    for _ = 1, parts do
      local n = rd_u(s, p, 2)
      p = p + 2 + n * 2
    end
  elseif t == 0xF1 then
    d.kind, d.ltype, d.name = "plp", "string", "xml"
    local schema = s:byte(p)
    p = p + 1
    if schema == 1 then
      for _ = 1, 2 do
        local n = s:byte(p)
        p = p + 1 + n * 2
      end
      local n = rd_u(s, p, 2)
      p = p + 2 + n * 2
    end
  elseif t == 0x62 then
    d.kind, d.ltype, d.name = "variant", "unknown", "sql_variant"
    p = p + 4
  else
    dberr.raise("decode", ("unsupported SQL Server type 0x%02x"):format(t))
  end
  return d, p
end
M.type_info = type_info

local DAY_MS = 86400000
local EPOCH_1900 = -25567 -- days from 1970-01-01 to 1900-01-01
local EPOCH_0001 = -719162 -- days from 1970-01-01 to 0001-01-01

local function iso_date(days_since_1970)
  return require("dbdash.db.bson").ms_to_iso(days_since_1970 * DAY_MS):sub(1, 10)
end

local function clock(units, scale)
  local secs = math.floor(units / 10 ^ scale)
  local frac = units - secs * 10 ^ scale
  local s = ("%02d:%02d:%02d"):format(
    math.floor(secs / 3600),
    math.floor(secs % 3600 / 60),
    secs % 60
  )
  if scale > 0 then
    s = s .. "." .. ("%0" .. scale .. "d"):format(frac)
  end
  return s
end

---Unsigned little-endian magnitude bytes -> decimal string.
local function le_decimal(b)
  local bytes = { b:byte(1, -1) }
  local digits = {}
  local function zero()
    for _, x in ipairs(bytes) do
      if x ~= 0 then
        return false
      end
    end
    return true
  end
  repeat
    local rem = 0
    for i = #bytes, 1, -1 do
      local cur = rem * 256 + bytes[i]
      bytes[i] = math.floor(cur / 10)
      rem = cur % 10
    end
    table.insert(digits, 1, tostring(rem))
  until zero()
  return table.concat(digits)
end

local function scaled(digits, scale, neg)
  if scale > 0 then
    digits = string.rep("0", math.max(0, scale - #digits + 1)) .. digits
    digits = digits:sub(1, #digits - scale) .. "." .. digits:sub(#digits - scale + 1)
  end
  return (neg and "-" or "") .. digits
end

local function money(b)
  local v
  if #b == 8 then
    local hi, lo = rd_s(b, 1, 4), rd_u(b, 5, 4)
    local buf = ffi.new("int64_t[1]", ffi.new("int64_t", hi) * 4294967296LL + lo)
    v = buf[0]
  else
    v = ffi.new("int64_t", rd_s(b, 1, 4))
  end
  local neg = v < 0
  local s = tostring(neg and -v or v):gsub("LL$", "")
  return scaled(s, 4, neg)
end

local function guid(b)
  local function hx(x)
    return (x:gsub(".", function(c)
      return ("%02X"):format(c:byte())
    end))
  end
  return hx(b:sub(1, 4):reverse())
    .. "-"
    .. hx(b:sub(5, 6):reverse())
    .. "-"
    .. hx(b:sub(7, 8):reverse())
    .. "-"
    .. hx(b:sub(9, 10))
    .. "-"
    .. hx(b:sub(11, 16))
end

---Decode the data bytes `b` of a non-NULL value of type d.
local function value(d, b)
  local t = d.id
  local name = d.name
  if t == 0x30 then
    return b:byte(1)
  elseif t == 0x32 or t == 0x68 then
    return b:byte(1) ~= 0
  elseif t == 0x34 or t == 0x38 or t == 0x7F or t == 0x26 then
    if #b == 1 then
      return b:byte(1)
    end
    return rd_int(b, 1, #b)
  elseif t == 0x3B or (t == 0x6D and #b == 4) then
    local buf = ffi.new("float[1]")
    ffi.copy(buf, b, 4)
    return tonumber(buf[0])
  elseif t == 0x3E or t == 0x6D then
    local buf = ffi.new("double[1]")
    ffi.copy(buf, b, 8)
    return buf[0]
  elseif t == 0x3C or t == 0x7A or t == 0x6E then
    return money(b)
  elseif t == 0x3D or (t == 0x6F and #b == 8) then
    local days, ticks = rd_s(b, 1, 4), rd_u(b, 5, 4)
    local ms = math.floor(ticks * 10 / 3 + 0.5)
    return require("dbdash.db.bson")
      .ms_to_iso((EPOCH_1900 + days) * DAY_MS + ms)
      :gsub("T", " ")
      :gsub("Z$", "")
  elseif t == 0x3A or t == 0x6F then
    local days, mins = rd_u(b, 1, 2), rd_u(b, 3, 2)
    return require("dbdash.db.bson")
      .ms_to_iso((EPOCH_1900 + days) * DAY_MS + mins * 60000)
      :sub(1, 16)
      :gsub("T", " ")
  elseif t == 0x6A or t == 0x6C or t == 0x37 or t == 0x3F then
    return scaled(le_decimal(b:sub(2)), d.scale, b:byte(1) == 0)
  elseif t == 0x24 then
    return guid(b)
  elseif t == 0x28 then
    return iso_date(EPOCH_0001 + rd_u(b, 1, 3))
  elseif t == 0x29 then
    return clock(rd_u(b, 1, #b), d.scale)
  elseif t == 0x2A then
    local tlen = #b - 3
    return iso_date(EPOCH_0001 + rd_u(b, tlen + 1, 3)) .. " " .. clock(rd_u(b, 1, tlen), d.scale)
  elseif t == 0x2B then
    local tlen = #b - 5
    local off = rd_s(b, tlen + 4, 2)
    local units = rd_u(b, 1, tlen)
    local days = EPOCH_0001 + rd_u(b, tlen + 1, 3)
    -- Stored as UTC; render in the stored offset.
    local total = days * 86400 * 10 ^ d.scale + units + off * 60 * 10 ^ d.scale
    local day_units = 86400 * 10 ^ d.scale
    local ld = math.floor(total / day_units)
    local sign = off < 0 and "-" or "+"
    return ("%s %s %s%02d:%02d"):format(
      iso_date(ld),
      clock(total - ld * day_units, d.scale),
      sign,
      math.floor(math.abs(off) / 60),
      math.abs(off) % 60
    )
  elseif t == 0xE7 or t == 0xEF or t == 0x63 or name == "xml" then
    return M.utf8(b)
  elseif t == 0xA7 or t == 0xAF or t == 0x23 then
    local cp65001 = d.collation and bit.band(d.collation:byte(4), 0x08) ~= 0
    return cp65001 and b or latin1(b)
  end
  return b
end
M.value = value

-- Token stream ----------------------------------------------------------------------------

local TOKEN = {
  ALTMETADATA = 0x88,
  COLMETADATA = 0x81,
  ROW = 0xD1,
  NBCROW = 0xD2,
  DONE = 0xFD,
  DONEPROC = 0xFE,
  DONEINPROC = 0xFF,
  ENVCHANGE = 0xE3,
  ERROR = 0xAA,
  INFO = 0xAB,
  LOGINACK = 0xAD,
  ORDER = 0xA9,
  RETURNSTATUS = 0x79,
  RETURNVALUE = 0xAC,
  COLINFO = 0xA5,
  TABNAME = 0xA4,
  FEATUREEXTACK = 0xAE,
  SSPI = 0xED,
}

local function us_varchar(s, p)
  local n = rd_u(s, p, 2)
  return M.utf8(s:sub(p + 2, p + 1 + n * 2)), p + 2 + n * 2
end

local function b_varchar(s, p)
  local n = s:byte(p)
  return M.utf8(s:sub(p + 1, p + n * 2)), p + 1 + n * 2
end

---Read one column value at p. Returns value (NULL for null) and next position.
local function read_value(d, s, p)
  local k = d.kind
  if k == "fixed" then
    if d.size == 0 then
      return NULL, p
    end
    return value(d, s:sub(p, p + d.size - 1)), p + d.size
  elseif k == "bytelen" then
    local n = s:byte(p)
    if n == 0 then
      return NULL, p + 1
    end
    return value(d, s:sub(p + 1, p + n)), p + 1 + n
  elseif k == "ushort" then
    local n = rd_u(s, p, 2)
    if n == 0xFFFF then
      return NULL, p + 2
    end
    return value(d, s:sub(p + 2, p + 1 + n)), p + 2 + n
  elseif k == "plp" then
    if s:sub(p, p + 7) == string.rep("\255", 8) then
      return NULL, p + 8
    end
    p = p + 8
    local chunks = {}
    while true do
      local n = rd_u(s, p, 4)
      p = p + 4
      if n == 0 then
        break
      end
      chunks[#chunks + 1] = s:sub(p, p + n - 1)
      p = p + n
    end
    return value(d, table.concat(chunks)), p
  elseif k == "longlen" then
    local tp = s:byte(p)
    if tp == 0 then
      return NULL, p + 1
    end
    p = p + 1 + tp + 8
    local n = rd_u(s, p, 4)
    return value(d, s:sub(p + 4, p + 3 + n)), p + 4 + n
  elseif k == "variant" then
    local n = rd_u(s, p, 4)
    if n == 0 then
      return NULL, p + 4
    end
    local inner = s:sub(p + 4, p + 3 + n)
    p = p + 4 + n
    -- sql_variant: base type, prop bytes, data
    local bt, props = inner:byte(1), inner:byte(2)
    local id, _ = type_info(string.char(bt) .. inner:sub(3, 2 + props), 1)
    id.kind = "raw"
    return value(id, inner:sub(3 + props)), p
  end
  dberr.raise("decode", "unsupported column kind " .. tostring(k))
end

---Parse a reply's tokens. Returns result sets, the first error, info messages.
function M.parse_tokens(s, max_rows)
  local p = 1
  local results, current, err, infos = {}, nil, nil, {}
  local env = {}
  while p <= #s do
    local t = s:byte(p)
    p = p + 1
    if t == TOKEN.COLMETADATA then
      local n = rd_u(s, p, 2)
      p = p + 2
      if n ~= 0xFFFF then
        local cols = {}
        for i = 1, n do
          p = p + 4 + 2 -- user type, flags
          local d
          d, p = type_info(s, p)
          local name
          name, p = b_varchar(s, p)
          d.colname = name
          cols[i] = d
        end
        current = { cols = cols, rows = {}, truncated = false }
        results[#results + 1] = current
      end
    elseif t == TOKEN.ROW or t == TOKEN.NBCROW then
      local cols = current.cols
      local nulls
      if t == TOKEN.NBCROW then
        local nb = math.ceil(#cols / 8)
        nulls = s:sub(p, p + nb - 1)
        p = p + nb
      end
      local row = {}
      for i, d in ipairs(cols) do
        if
          nulls
          and bit.band(nulls:byte(math.floor((i - 1) / 8) + 1), bit.lshift(1, (i - 1) % 8)) ~= 0
        then
          row[i] = NULL
        else
          row[i], p = read_value(d, s, p)
        end
      end
      if #current.rows < max_rows then
        current.rows[#current.rows + 1] = row
      else
        current.truncated = true
      end
    elseif t == TOKEN.DONE or t == TOKEN.DONEPROC or t == TOKEN.DONEINPROC then
      local status = rd_u(s, p, 2)
      if bit.band(status, 0x10) ~= 0 and current and not current.affected then
        current.count = rd_u(s, p + 4, 4)
      elseif bit.band(status, 0x10) ~= 0 and not current then
        results.affected = rd_u(s, p + 4, 4)
      end
      p = p + 12
    elseif t == TOKEN.ERROR or t == TOKEN.INFO then
      local len = rd_u(s, p, 2)
      local q = p + 2
      local number = rd_s(s, q, 4)
      local state, class = s:byte(q + 4), s:byte(q + 5)
      local msg = us_varchar(s, q + 6)
      if t == TOKEN.ERROR then
        err = err or { number = number, state = state, class = class, message = msg }
      else
        infos[#infos + 1] = msg
      end
      p = p + 2 + len
    elseif t == TOKEN.ENVCHANGE then
      local len = rd_u(s, p, 2)
      local typ = s:byte(p + 2)
      if typ == 4 then -- packet size: new value as B_VARCHAR
        env.packet_size = tonumber((b_varchar(s, p + 3)))
      end
      p = p + 2 + len
    elseif t == TOKEN.LOGINACK then
      -- Length, interface(1), TDS version(4), program name, program version(4)
      local len = rd_u(s, p, 2)
      local name, q = b_varchar(s, p + 2 + 1 + 4)
      env.server = name
      env.version = ("%d.%d.%d"):format(
        s:byte(q),
        s:byte(q + 1),
        s:byte(q + 2) * 256 + s:byte(q + 3)
      )
      env.logged_in = true
      p = p + 2 + len
    elseif t == TOKEN.ORDER or t == TOKEN.COLINFO or t == TOKEN.TABNAME or t == TOKEN.SSPI then
      p = p + 2 + rd_u(s, p, 2)
    elseif t == TOKEN.FEATUREEXTACK then
      while s:byte(p) ~= 0xFF do
        local len = rd_u(s, p + 1, 4)
        p = p + 5 + len
      end
      p = p + 1
    elseif t == TOKEN.RETURNSTATUS then
      p = p + 4
    elseif t == TOKEN.RETURNVALUE then
      dberr.raise("decode", "RETURNVALUE tokens are not supported (use SELECT)")
    else
      dberr.raise("decode", ("unexpected TDS token 0x%02x"):format(t))
    end
  end
  return results, err, infos, env
end

local function raise_sql(err, phase)
  if err.number == 18456 then
    phase = "auth"
  end
  dberr.raise(phase, err.message, { code = tostring(err.number) })
end

-- Connection ------------------------------------------------------------------------------

function M.parse_url(info)
  info.host = info.host or "localhost"
  info.port = info.port or 1433
  return info
end

---Handshake transport that carries TLS records inside TDS PRELOGIN packets (TDS 7.x).
local function tds_io(c)
  local io = { buf = "" }
  function io:raw_write(data)
    c:send(PKT.PRELOGIN, data)
  end
  function io:raw_read_exact(n)
    while #self.buf < n do
      local h = c.sock:read_exact(8)
      local len = h:byte(3) * 256 + h:byte(4)
      self.buf = self.buf .. c.sock:read_exact(len - 8)
    end
    local out = self.buf:sub(1, n)
    self.buf = self.buf:sub(n + 1)
    return out
  end
  return io
end

---TLS modes:
---  tls=disable                  no encryption (the server must not force it)
---  tls=require|pin|verify-*     TDS 7.4 with TLS negotiated in PRELOGIN (usually TLS 1.2)
---  &encrypt=strict              TDS 8 (SQL Server 2022+): TLS first, ALPN tds/8.0
function M.connect(info)
  local strict = (info.params.encrypt or ""):lower() == "strict"
  if strict and info.tls == "disable" then
    info.tls = "require"
  end
  local sock = socket.connect(
    info.host,
    info.port,
    { connect_timeout = info.connect_timeout, timeout = info.timeout }
  )
  local c = setmetatable({ sock = sock, packet_size = PACKET_SIZE }, Conn)
  local ok, err = pcall(function()
    local tls = require("dbdash.net.tls")
    if strict then
      tls.from_info(sock, info, { alpn = { "tds/8.0" } })
    end
    local want = info.tls ~= "disable"
    c:send(PKT.PRELOGIN, M.prelogin(want and ENCRYPT.ON or ENCRYPT.NOT_SUP))
    local enc = M.parse_prelogin(c:recv())
    if not strict then
      if want then
        if enc == ENCRYPT.NOT_SUP then
          dberr.raise("tls", "the server does not support encryption")
        end
        -- TLS inside TDS 7.x packets is TLS 1.2 at most.
        tls.from_info(sock, info, { io = tds_io(c), tls13 = false })
      elseif enc == ENCRYPT.REQ or enc == ENCRYPT.ON then
        dberr.raise(
          "tls",
          "the server requires encryption; connect with ?tls=require (or pin / verify-full)"
        )
      end
    end
    c:send(PKT.LOGIN7, M.login7(info))
    local _, e, _, env = M.parse_tokens(c:recv(), 0)
    if e then
      raise_sql(e, "auth")
    end
    if not env.logged_in then
      dberr.raise("auth", "login was not acknowledged")
    end
    c.version = env.version
    if env.packet_size then
      c.packet_size = env.packet_size
    end
  end)
  if not ok then
    sock:close()
    error(err, 0)
  end
  return c
end

---ALL_HEADERS with a transaction descriptor (required since TDS 7.2).
local ALL_HEADERS = le(22, 4) .. le(18, 4) .. le(2, 2) .. string.rep("\0", 8) .. le(1, 4)

function Conn:execute(query, opts)
  local max = opts.max_rows or 10000
  self:send(PKT.SQL_BATCH, ALL_HEADERS .. M.utf16(query))
  local results, err, infos = M.parse_tokens(self:recv(), max)
  if err then
    raise_sql(err, "query")
  end
  local last = results[#results]
  if not last then
    return resultset.new({}, {}, { affected = results.affected, warnings = infos })
  end
  local columns = {}
  for i, d in ipairs(last.cols) do
    columns[i] = { name = d.colname, type = d.ltype, db_type = d.name }
  end
  return resultset.new(columns, last.rows, { truncated = last.truncated, warnings = infos })
end

function Conn:close()
  self.sock:close()
end

---Stop the batch running on `conn`: an attention packet on the same connection (the
---server ends the batch and acknowledges it; the connection is closed right after).
function M.cancel(conn)
  if conn.sock.closed then
    return
  end
  conn.sock:write(string.char(PKT.ATTENTION, 1, 0, 8, 0, 0, 1, 0))
end

function Conn:server_version()
  return self.version
end

return M
