-- Cassandra driver (:help dbdash-databases): CQL native protocol v4 over TCP or TLS,
-- PasswordAuthenticator (SASL PLAIN), QUERY with paging, RESULT Rows mapped by column type.
local bit = require("bit")
local ffi = require("ffi")
local dberr = require("dbdash.util.error")
local map = require("dbdash.util.map")
local resultset = require("dbdash.db.resultset")
local socket = require("dbdash.net.socket")

local M = {
  name = "cassandra",
  schemes = { "cassandra", "cql" },
  dialect = "cassandra",
  capabilities = { tls = true, sql = true, query_language = "cql" },
}

local NULL = vim.NIL

local OP = {
  ERROR = 0x00,
  STARTUP = 0x01,
  READY = 0x02,
  AUTHENTICATE = 0x03,
  QUERY = 0x07,
  RESULT = 0x08,
  AUTH_CHALLENGE = 0x0E,
  AUTH_RESPONSE = 0x0F,
  AUTH_SUCCESS = 0x10,
}

local CONSISTENCY = {
  ANY = 0,
  ONE = 1,
  TWO = 2,
  THREE = 3,
  QUORUM = 4,
  ALL = 5,
  LOCAL_QUORUM = 6,
  EACH_QUORUM = 7,
  SERIAL = 8,
  LOCAL_SERIAL = 9,
  LOCAL_ONE = 10,
}

-- Big-endian primitives ---------------------------------------------------------------------

local function u16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

local function i32(n)
  n = n % 4294967296
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  )
end

local function rd_u16(s, p)
  return s:byte(p) * 256 + s:byte(p + 1), p + 2
end

local function rd_i32(s, p)
  local a, b, c, d = s:byte(p, p + 3)
  local n = ((a * 256 + b) * 256 + c) * 256 + d
  if n >= 2147483648 then
    n = n - 4294967296
  end
  return n, p + 4
end

local function rd_string(s, p)
  local n
  n, p = rd_u16(s, p)
  return s:sub(p, p + n - 1), p + n
end

local function rd_bytes(s, p)
  local n
  n, p = rd_i32(s, p)
  if n < 0 then
    return nil, p
  end
  return s:sub(p, p + n - 1), p + n
end

local function string_map(t)
  local parts = { u16(#vim.tbl_keys(t)) }
  for k, v in pairs(t) do
    parts[#parts + 1] = u16(#k) .. k .. u16(#v) .. v
  end
  return table.concat(parts)
end

-- Value decoding --------------------------------------------------------------------------

---Two's-complement big-endian integer bytes -> decimal string.
function M.varint(b)
  if #b == 0 then
    return "0"
  end
  local bytes = { b:byte(1, -1) }
  local neg = bytes[1] >= 128
  if neg then -- magnitude = two's complement
    local carry = 1
    for i = #bytes, 1, -1 do
      local v = (255 - bytes[i]) + carry
      bytes[i] = v % 256
      carry = math.floor(v / 256)
    end
  end
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
    for i = 1, #bytes do
      local cur = rem * 256 + bytes[i]
      bytes[i] = math.floor(cur / 10)
      rem = cur % 10
    end
    table.insert(digits, 1, tostring(rem))
  until zero()
  return (neg and "-" or "") .. table.concat(digits)
end

local function be_int(b)
  -- Exact for up to 8 bytes via the decimal string path when large.
  if #b <= 6 then
    local n = 0
    for i = 1, #b do
      n = n * 256 + b:byte(i)
    end
    if b:byte(1) >= 128 then
      n = n - 2 ^ (8 * #b)
    end
    return n
  end
  return resultset.integer(M.varint(b))
end

local function be_double(b)
  local buf = ffi.new("double[1]")
  ffi.copy(buf, b:reverse(), 8)
  return buf[0]
end

local function be_float(b)
  local buf = ffi.new("float[1]")
  ffi.copy(buf, b:reverse(), 4)
  return tonumber(buf[0])
end

local function uuid(b)
  local h = b:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end)
  return ("%s-%s-%s-%s-%s"):format(
    h:sub(1, 8),
    h:sub(9, 12),
    h:sub(13, 16),
    h:sub(17, 20),
    h:sub(21, 32)
  )
end

local function inet(b)
  if #b == 4 then
    return ("%d.%d.%d.%d"):format(b:byte(1, 4))
  end
  local parts = {}
  for i = 1, #b, 2 do
    parts[#parts + 1] = ("%x"):format(b:byte(i) * 256 + b:byte(i + 1))
  end
  return table.concat(parts, ":")
end

---Unsigned vint (protocol v5 / duration encoding).
local function rd_vint(s, p)
  local first = s:byte(p)
  local extra = 0
  local mask = 0x80
  while extra < 8 and bit.band(first, mask) ~= 0 do
    extra = extra + 1
    mask = bit.rshift(mask, 1)
  end
  local v = bit.band(first, mask - 1)
  for i = 1, extra do
    v = v * 256 + s:byte(p + i)
  end
  return v, p + 1 + extra
end

local function zigzag(v)
  if v % 2 == 0 then
    return v / 2
  end
  return -(v + 1) / 2
end

---@class dbdash.cql.Type
---@field id integer
---@field sub dbdash.cql.Type[]?
---@field fields { name: string, type: dbdash.cql.Type }[]?

local TYPE_NAMES = {
  [0x01] = "ascii",
  [0x02] = "bigint",
  [0x03] = "blob",
  [0x04] = "boolean",
  [0x05] = "counter",
  [0x06] = "decimal",
  [0x07] = "double",
  [0x08] = "float",
  [0x09] = "int",
  [0x0B] = "timestamp",
  [0x0C] = "uuid",
  [0x0D] = "varchar",
  [0x0E] = "varint",
  [0x0F] = "timeuuid",
  [0x10] = "inet",
  [0x11] = "date",
  [0x12] = "time",
  [0x13] = "smallint",
  [0x14] = "tinyint",
  [0x15] = "duration",
  [0x20] = "list",
  [0x21] = "map",
  [0x22] = "set",
  [0x30] = "udt",
  [0x31] = "tuple",
}

local LOGICAL = {
  ascii = "string",
  varchar = "string",
  bigint = "integer",
  counter = "integer",
  int = "integer",
  smallint = "integer",
  tinyint = "integer",
  varint = "integer",
  blob = "bytes",
  boolean = "boolean",
  decimal = "decimal",
  double = "number",
  float = "number",
  timestamp = "datetime",
  date = "date",
  time = "time",
  uuid = "uuid",
  timeuuid = "uuid",
  inet = "string",
  duration = "string",
  list = "array",
  set = "array",
  tuple = "array",
  map = "json",
  udt = "json",
}

local function read_type(s, p)
  local id
  id, p = rd_u16(s, p)
  local t = { id = id }
  if id == 0x0000 then
    t.custom, p = rd_string(s, p)
  elseif id == 0x20 or id == 0x22 then
    t.sub = {}
    t.sub[1], p = read_type(s, p)
  elseif id == 0x21 then
    t.sub = {}
    t.sub[1], p = read_type(s, p)
    t.sub[2], p = read_type(s, p)
  elseif id == 0x30 then
    t.keyspace, p = rd_string(s, p)
    t.udt, p = rd_string(s, p)
    local n
    n, p = rd_u16(s, p)
    t.fields = {}
    for i = 1, n do
      local name
      name, p = rd_string(s, p)
      local ft
      ft, p = read_type(s, p)
      t.fields[i] = { name = name, type = ft }
    end
  elseif id == 0x31 then
    local n
    n, p = rd_u16(s, p)
    t.sub = {}
    for i = 1, n do
      t.sub[i], p = read_type(s, p)
    end
  end
  return t, p
end
M.read_type = read_type

local function type_name(t)
  local n = TYPE_NAMES[t.id]
    or (t.custom and ("custom " .. t.custom))
    or ("0x" .. ("%04x"):format(t.id))
  if t.sub then
    local subs = {}
    for i, st in ipairs(t.sub) do
      subs[i] = type_name(st)
    end
    n = n .. "<" .. table.concat(subs, ", ") .. ">"
  elseif t.udt then
    n = t.keyspace .. "." .. t.udt
  end
  return n
end
M.type_name = type_name

---Decode a value of type t from bytes b (b is never nil here).
local function decode(t, b)
  local name = TYPE_NAMES[t.id]
  if name == "ascii" or name == "varchar" then
    return b
  elseif
    name == "bigint"
    or name == "counter"
    or name == "int"
    or name == "smallint"
    or name == "tinyint"
  then
    return be_int(b)
  elseif name == "varint" then
    return resultset.integer(M.varint(b))
  elseif name == "boolean" then
    return b:byte(1) ~= 0
  elseif name == "double" then
    return be_double(b)
  elseif name == "float" then
    return be_float(b)
  elseif name == "decimal" then
    local scale = rd_i32(b, 1)
    local digits = M.varint(b:sub(5))
    local neg = digits:sub(1, 1) == "-"
    digits = digits:gsub("^%-", "")
    if scale > 0 then
      digits = string.rep("0", math.max(0, scale - #digits + 1)) .. digits
      digits = digits:sub(1, #digits - scale) .. "." .. digits:sub(#digits - scale + 1)
    elseif scale < 0 then
      digits = digits .. string.rep("0", -scale)
    end
    return (neg and "-" or "") .. digits
  elseif name == "timestamp" then
    local ms = be_int(b)
    return require("dbdash.db.bson").ms_to_iso(tonumber(ms) or 0)
  elseif name == "date" then
    local days = 0
    for i = 1, 4 do
      days = days * 256 + b:byte(i)
    end
    days = days - 2 ^ 31
    return require("dbdash.db.bson").ms_to_iso(days * 86400000):sub(1, 10)
  elseif name == "time" then
    local ns = tonumber(be_int(b)) or 0
    local secs = math.floor(ns / 1e9)
    local frac = ns - secs * 1e9
    return ("%02d:%02d:%02d.%09d"):format(
      math.floor(secs / 3600),
      math.floor(secs % 3600 / 60),
      secs % 60,
      frac
    )
  elseif name == "uuid" or name == "timeuuid" then
    return uuid(b)
  elseif name == "inet" then
    return inet(b)
  elseif name == "blob" then
    return b
  elseif name == "duration" then
    local mo, d, ns, p
    mo, p = rd_vint(b, 1)
    d, p = rd_vint(b, p)
    ns = rd_vint(b, p)
    return ("%dmo%dd%dns"):format(zigzag(mo), zigzag(d), zigzag(ns))
  elseif name == "list" or name == "set" then
    local n, p = rd_i32(b, 1)
    local out = {}
    for i = 1, n do
      local e
      e, p = rd_bytes(b, p)
      out[i] = e == nil and NULL or decode(t.sub[1], e)
    end
    return out
  elseif name == "map" then
    local n, p = rd_i32(b, 1)
    local out = map.new()
    for _ = 1, n do
      local kb, vb
      kb, p = rd_bytes(b, p)
      vb, p = rd_bytes(b, p)
      local k = kb and decode(t.sub[1], kb) or "null"
      if type(k) ~= "string" then
        k = require("dbdash.util.pystr").str(k)
      end
      map.set(out, k, vb == nil and NULL or decode(t.sub[2], vb))
    end
    return out
  elseif name == "udt" then
    local out, p = map.new(), 1
    for _, f in ipairs(t.fields) do
      if p > #b then
        break
      end
      local fb
      fb, p = rd_bytes(b, p)
      map.set(out, f.name, fb == nil and NULL or decode(f.type, fb))
    end
    return out
  elseif name == "tuple" then
    local out, p = {}, 1
    for i, st in ipairs(t.sub) do
      local eb
      eb, p = rd_bytes(b, p)
      out[i] = eb == nil and NULL or decode(st, eb)
    end
    return out
  end
  return b -- custom / unknown: raw bytes as text
end
M.decode = decode

-- Connection ------------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

function Conn:send(opcode, body)
  self.stream = (self.stream + 1) % 32768
  self.sock:write(
    string.char(0x04, 0, math.floor(self.stream / 256), self.stream % 256, opcode)
      .. i32(#body)
      .. body
  )
end

---Read one response frame: opcode, body.
function Conn:recv()
  local h = self.sock:read_exact(9)
  local flags = h:byte(2)
  local opcode = h:byte(5)
  local len = rd_i32(h, 6)
  local body = len > 0 and self.sock:read_exact(len) or ""
  if bit.band(flags, 0x01) ~= 0 then
    dberr.raise("decode", "compressed frames are not supported")
  end
  local p = 1
  if bit.band(flags, 0x02) ~= 0 then -- tracing id
    p = p + 16
  end
  if bit.band(flags, 0x08) ~= 0 then -- warnings: [string list]
    local n
    n, p = rd_u16(body, p)
    self.warnings = {}
    for i = 1, n do
      self.warnings[i], p = rd_string(body, p)
    end
  end
  if bit.band(flags, 0x04) ~= 0 then -- custom payload: [bytes map]
    local n
    n, p = rd_u16(body, p)
    for _ = 1, n do
      local _
      _, p = rd_string(body, p)
      _, p = rd_bytes(body, p)
    end
  end
  return opcode, body:sub(p)
end

local function raise_error(body, phase)
  local code = rd_i32(body, 1)
  local msg = rd_string(body, 5)
  if code == 0x0100 then
    phase = "auth"
  elseif code == 0x1001 or code == 0x1100 or code == 0x1200 then
    phase = "timeout"
  end
  dberr.raise(phase, msg, { code = ("0x%04x"):format(code % 65536) })
end

function M.parse_url(info)
  info.host = info.host or "localhost"
  info.port = info.port or 9042
  local c = (info.params.consistency or "ONE"):upper()
  if not CONSISTENCY[c] then
    dberr.raise("config", "unknown consistency level " .. c)
  end
  info.consistency = CONSISTENCY[c]
  return info
end

function M.connect(info)
  local sock = socket.connect(
    info.host,
    info.port,
    { connect_timeout = info.connect_timeout, timeout = info.timeout }
  )
  local c = setmetatable({ sock = sock, stream = 0, consistency = info.consistency or 1 }, Conn)
  local ok, err = pcall(function()
    if info.tls ~= "disable" then
      require("dbdash.net.tls").from_info(sock, info)
    end
    c:send(OP.STARTUP, string_map({ CQL_VERSION = "3.0.0" }))
    local op, body = c:recv()
    if op == OP.AUTHENTICATE then
      if not info.user then
        dberr.raise("auth", "the server requires authentication (" .. rd_string(body, 1) .. ")")
      end
      local token = "\0" .. info.user .. "\0" .. (info.password or "")
      c:send(OP.AUTH_RESPONSE, i32(#token) .. token)
      op, body = c:recv()
      if op == OP.AUTH_CHALLENGE then
        dberr.raise("auth", "unsupported authentication challenge")
      end
      if op == OP.ERROR then
        raise_error(body, "auth")
      elseif op ~= OP.AUTH_SUCCESS then
        dberr.raise("auth", "unexpected response to authentication")
      end
    elseif op == OP.ERROR then
      raise_error(body, "connect")
    elseif op ~= OP.READY then
      dberr.raise("connect", "unexpected response to STARTUP")
    end
    if info.database then
      c:query('USE "' .. info.database:gsub('"', '""') .. '"', 1, nil)
    end
  end)
  if not ok then
    sock:close()
    error(err, 0)
  end
  return c
end

---Run one QUERY page. Returns kind and parsed result.
function Conn:query(cql, page_size, paging_state)
  local flags = 0x04
  local extra = i32(page_size)
  if paging_state then
    flags = flags + 0x08
    extra = extra .. i32(#paging_state) .. paging_state
  end
  self:send(OP.QUERY, i32(#cql) .. cql .. u16(self.consistency) .. string.char(flags) .. extra)
  local op, body = self:recv()
  if op == OP.ERROR then
    raise_error(body, "query")
  elseif op ~= OP.RESULT then
    dberr.raise("decode", "unexpected response opcode " .. op)
  end
  local kind, p = rd_i32(body, 1)
  if kind ~= 2 then
    return kind
  end
  -- Rows metadata.
  local mflags, ncols
  mflags, p = rd_i32(body, p)
  ncols, p = rd_i32(body, p)
  local state
  if bit.band(mflags, 0x0002) ~= 0 then
    state, p = rd_bytes(body, p)
  end
  local cols = {}
  if bit.band(mflags, 0x0004) == 0 then
    local global = bit.band(mflags, 0x0001) ~= 0
    if global then
      local _
      _, p = rd_string(body, p)
      _, p = rd_string(body, p)
    end
    for i = 1, ncols do
      if not global then
        local _
        _, p = rd_string(body, p)
        _, p = rd_string(body, p)
      end
      local name, t
      name, p = rd_string(body, p)
      t, p = read_type(body, p)
      cols[i] = { name = name, t = t }
    end
  end
  local nrows
  nrows, p = rd_i32(body, p)
  local rows = {}
  for r = 1, nrows do
    local row = {}
    for i = 1, ncols do
      local b
      b, p = rd_bytes(body, p)
      row[i] = b == nil and NULL or decode(cols[i].t, b)
    end
    rows[r] = row
  end
  return kind, { cols = cols, rows = rows, paging_state = state }
end

function Conn:execute(query, opts)
  local max = opts.max_rows or 10000
  local cql = vim.trim(query):gsub(";%s*$", "")
  local page = math.min(max + 1, 5000)
  local kind, res = self:query(cql, page, nil)
  if kind ~= 2 then
    return resultset.new({}, {})
  end
  local cols, rows = res.cols, res.rows
  while res.paging_state and #rows <= max do
    res = select(2, self:query(cql, page, res.paging_state))
    vim.list_extend(rows, res.rows)
  end
  local truncated = #rows > max or res.paging_state ~= nil
  while #rows > max do
    rows[#rows] = nil
  end
  local columns = {}
  for i, c in ipairs(cols) do
    local tn = TYPE_NAMES[c.t.id] or "custom"
    columns[i] = { name = c.name, type = LOGICAL[tn] or "unknown", db_type = type_name(c.t) }
  end
  return resultset.new(columns, rows, { truncated = truncated, warnings = self.warnings })
end

function Conn:close()
  self.sock:close()
end

-- database.options: none (dbdash.db.options)
M.options = {}

return M
