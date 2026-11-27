-- MySQL / MariaDB driver (design §8.4): handshake v10, mysql_native_password and
-- caching_sha2_password (fast path, and full authentication with the server's RSA key on
-- plain-text connections), COM_QUERY text protocol with multiple result sets.
local bit = require("bit")
local dberr = require("dbdash.db.error")
local dialect = require("dbdash.db.dialect")
local resultset = require("dbdash.db.resultset")
local socket = require("dbdash.net.socket")
local util = require("dbdash.crypto.util")

local M = {
  name = "mysql",
  schemes = { "mysql", "mariadb" },
  dialect = dialect.get("mysql"),
  capabilities = { tls = true, sql = true, query_language = "sql" },
}

local NULL = vim.NIL

-- Capability flags.
local CLIENT = {
  SSL = 0x800,
  LONG_PASSWORD = 0x1,
  FOUND_ROWS = 0x2,
  LONG_FLAG = 0x4,
  CONNECT_WITH_DB = 0x8,
  PROTOCOL_41 = 0x200,
  TRANSACTIONS = 0x2000,
  SECURE_CONNECTION = 0x8000,
  MULTI_STATEMENTS = 0x10000,
  MULTI_RESULTS = 0x20000,
  PLUGIN_AUTH = 0x80000,
  PLUGIN_AUTH_LENENC = 0x200000,
}
local SERVER_MORE_RESULTS_EXISTS = 0x0008

-- Little-endian helpers ---------------------------------------------------------------------

local function le(n, bytes)
  local out = {}
  for i = 1, bytes do
    out[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(out)
end

local function read_le(s, pos, bytes)
  local n = 0
  for i = bytes - 1, 0, -1 do
    n = n * 256 + s:byte(pos + i)
  end
  return n, pos + bytes
end

---Length-encoded integer. Returns nil for the NULL marker (0xFB).
local function read_lenenc(s, pos)
  local b = s:byte(pos)
  if b < 0xfb then
    return b, pos + 1
  elseif b == 0xfb then
    return nil, pos + 1
  elseif b == 0xfc then
    return read_le(s, pos + 1, 2), pos + 3
  elseif b == 0xfd then
    return read_le(s, pos + 1, 3), pos + 4
  end
  return read_le(s, pos + 1, 8), pos + 9
end

local function read_lenenc_str(s, pos)
  local n
  n, pos = read_lenenc(s, pos)
  if n == nil then
    return nil, pos
  end
  return s:sub(pos, pos + n - 1), pos + n
end

local function lenenc(n)
  if n < 251 then
    return string.char(n)
  elseif n < 65536 then
    return "\252" .. le(n, 2)
  elseif n < 16777216 then
    return "\253" .. le(n, 3)
  end
  return "\254" .. le(n, 8)
end

local function cstr(s, pos)
  local z = s:find("\0", pos, true) or (#s + 1)
  return s:sub(pos, z - 1), z + 1
end

-- Auth scrambles ----------------------------------------------------------------------------

---mysql_native_password: SHA1(pw) XOR SHA1(nonce .. SHA1(SHA1(pw))).
function M.native_scramble(password, nonce)
  if password == "" then
    return ""
  end
  local sha1 = require("dbdash.crypto.sha1")
  local h1 = sha1.digest(password)
  return util.xor(h1, sha1.digest(nonce .. sha1.digest(h1)))
end

---caching_sha2_password: SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) .. nonce).
function M.sha2_scramble(password, nonce)
  if password == "" then
    return ""
  end
  local sha256 = require("dbdash.crypto.sha256")
  local h1 = sha256.digest(password)
  return util.xor(h1, sha256.digest(sha256.digest(h1) .. nonce))
end

local function scramble(plugin, password, nonce)
  if plugin == "mysql_native_password" then
    return M.native_scramble(password, nonce)
  elseif plugin == "caching_sha2_password" then
    return M.sha2_scramble(password, nonce)
  elseif plugin == "mysql_clear_password" then
    return password .. "\0"
  end
  dberr.raise("auth", "unsupported authentication plugin " .. tostring(plugin))
end

-- Type mapping ----------------------------------------------------------------------------

local TYPES = {
  [0x01] = "integer",
  [0x02] = "integer",
  [0x03] = "integer",
  [0x08] = "integer",
  [0x09] = "integer",
  [0x0d] = "integer",
  [0x04] = "number",
  [0x05] = "number",
  [0x00] = "decimal",
  [0xf6] = "decimal",
  [0x0a] = "date",
  [0x0e] = "date",
  [0x0b] = "time",
  [0x07] = "datetime",
  [0x0c] = "datetime",
  [0x11] = "datetime",
  [0x12] = "datetime",
  [0xf5] = "json",
  [0x10] = "bytes",
  [0xff] = "bytes",
  [0x06] = "null",
}
local TYPE_NAMES = {
  [0x00] = "DECIMAL",
  [0x01] = "TINYINT",
  [0x02] = "SMALLINT",
  [0x03] = "INT",
  [0x04] = "FLOAT",
  [0x05] = "DOUBLE",
  [0x06] = "NULL",
  [0x07] = "TIMESTAMP",
  [0x08] = "BIGINT",
  [0x09] = "MEDIUMINT",
  [0x0a] = "DATE",
  [0x0b] = "TIME",
  [0x0c] = "DATETIME",
  [0x0d] = "YEAR",
  [0x0f] = "VARCHAR",
  [0x10] = "BIT",
  [0xf5] = "JSON",
  [0xf6] = "DECIMAL",
  [0xf7] = "ENUM",
  [0xf8] = "SET",
  [0xf9] = "TINYBLOB",
  [0xfa] = "MEDIUMBLOB",
  [0xfb] = "LONGBLOB",
  [0xfc] = "BLOB",
  [0xfd] = "VARCHAR",
  [0xfe] = "CHAR",
  [0xff] = "GEOMETRY",
}
local FLAG_UNSIGNED, FLAG_BINARY = 0x20, 0x80
local BINARY_CHARSET = 63

---Logical type from column type, flags and charset.
function M.logical(t, flags, charset)
  local lt = TYPES[t]
  if lt then
    return lt
  end
  if charset == BINARY_CHARSET and bit.band(flags, FLAG_BINARY) ~= 0 then
    return "bytes"
  end
  return "string"
end

local function decode_value(raw, col)
  local t = col.type
  if t == "integer" then
    return resultset.integer(raw)
  elseif t == "number" then
    return tonumber(raw) or raw
  elseif t == "json" then
    return require("dbdash.db.json").decode(raw)
  end
  return raw
end

-- Packets ---------------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

---Read one logical packet (joining 16 MB continuation packets).
function Conn:read_packet()
  local parts = {}
  while true do
    local head = self.sock:read_exact(4)
    local len = read_le(head, 1, 3)
    self.seq = (head:byte(4) + 1) % 256
    parts[#parts + 1] = len > 0 and self.sock:read_exact(len) or ""
    if len < 0xffffff then
      return table.concat(parts)
    end
  end
end

function Conn:write_packet(payload)
  local out = {}
  repeat
    local chunk = payload:sub(1, 0xffffff)
    payload = payload:sub(0xffffff + 1)
    out[#out + 1] = le(#chunk, 3) .. string.char(self.seq) .. chunk
    self.seq = (self.seq + 1) % 256
  until #chunk < 0xffffff
  self.sock:write(table.concat(out))
end

---Parse an ERR packet and raise it.
local function raise_err(p, phase)
  local code = read_le(p, 2, 2)
  local state, msg = nil, p:sub(4)
  if p:sub(4, 4) == "#" then
    state, msg = p:sub(5, 9), p:sub(10)
  end
  if code == 1045 or code == 1044 or code == 1698 or code == 1251 then
    phase = "auth"
  end
  dberr.raise(phase, msg, { code = state and (tostring(code) .. " " .. state) or tostring(code) })
end
M.raise_err = raise_err

---OK packet: affected rows, last insert id, status flags, warnings.
local function parse_ok(p)
  local affected, pos = read_lenenc(p, 2)
  local _
  _, pos = read_lenenc(p, pos)
  local status = read_le(p, pos, 2)
  local warnings = read_le(p, pos + 2, 2)
  return { affected = affected, status = status, warnings = warnings }
end

-- Connection ------------------------------------------------------------------------------

function M.parse_url(info)
  info.host = info.host or "localhost"
  info.port = info.port or 3306
  info.user = info.user or vim.env.USER or "root"
  return info
end

function M.connect(info)
  local sock = socket.connect(
    info.host,
    info.port,
    { connect_timeout = info.connect_timeout, timeout = info.timeout }
  )
  local c = setmetatable({ sock = sock, seq = 0 }, Conn)
  local ok, err = pcall(c.handshake, c, info)
  if not ok then
    sock:close()
    error(err, 0)
  end
  return c
end

---Parse the server's initial handshake packet.
function M.parse_handshake(p)
  local proto = p:byte(1)
  if proto == 0xff then
    raise_err(p, "connect")
  end
  if proto ~= 10 then
    dberr.raise("connect", "unsupported MySQL protocol version " .. proto)
  end
  local hs = {}
  local pos
  hs.version, pos = cstr(p, 2)
  hs.thread_id, pos = read_le(p, pos, 4)
  local part1 = p:sub(pos, pos + 7)
  pos = pos + 9
  local cap_lo
  cap_lo, pos = read_le(p, pos, 2)
  hs.charset = p:byte(pos)
  pos = pos + 1
  hs.status, pos = read_le(p, pos, 2)
  local cap_hi
  cap_hi, pos = read_le(p, pos, 2)
  hs.capabilities = cap_lo + cap_hi * 65536
  local auth_len = p:byte(pos)
  pos = pos + 11
  local part2_len = math.max(13, auth_len - 8)
  local part2 = p:sub(pos, pos + part2_len - 1)
  pos = pos + part2_len
  hs.nonce = (part1 .. part2):gsub("%z$", "")
  hs.plugin = cstr(p, pos)
  if hs.plugin == "" then
    hs.plugin = "mysql_native_password"
  end
  return hs
end

function Conn:handshake(info)
  local hs = M.parse_handshake(self:read_packet())
  self.version = hs.version
  self.thread_id = hs.thread_id -- the connection id, for KILL QUERY (M.cancel)
  local password = info.password or ""
  local caps = bit.bor(
    CLIENT.LONG_PASSWORD,
    CLIENT.FOUND_ROWS,
    CLIENT.LONG_FLAG,
    CLIENT.PROTOCOL_41,
    CLIENT.TRANSACTIONS,
    CLIENT.SECURE_CONNECTION,
    CLIENT.MULTI_STATEMENTS,
    CLIENT.MULTI_RESULTS,
    CLIENT.PLUGIN_AUTH,
    CLIENT.PLUGIN_AUTH_LENENC
  )
  if info.database then
    caps = bit.bor(caps, CLIENT.CONNECT_WITH_DB)
  end
  caps = bit.band(caps, bit.bor(hs.capabilities, CLIENT.CONNECT_WITH_DB))
  local head = function(c)
    return le(c % 4294967296, 4)
      .. le(16777216, 4)
      .. string.char(255) -- utf8mb4_0900_ai_ci (servers without it fall back to the default)
      .. string.rep("\0", 23)
  end
  if info.tls ~= "disable" then
    if bit.band(hs.capabilities, CLIENT.SSL) == 0 then
      dberr.raise("tls", "the server does not support TLS connections")
    end
    caps = bit.bor(caps, CLIENT.SSL)
    self:write_packet(head(caps)) -- SSLRequest
    require("dbdash.net.tls").from_info(self.sock, info)
    self.tls = true
  end
  local plugin = hs.plugin
  local auth = scramble(plugin, password, hs.nonce)
  local body = head(caps)
    .. info.user
    .. "\0"
    .. lenenc(#auth)
    .. auth
    .. (info.database and (info.database .. "\0") or "")
    .. plugin
    .. "\0"
  self:write_packet(body)

  local nonce = hs.nonce
  while true do
    local p = self:read_packet()
    local h = p:byte(1)
    if h == 0x00 then
      return
    elseif h == 0xff then
      raise_err(p, "auth")
    elseif h == 0xfe then
      -- AuthSwitchRequest: plugin name and new nonce.
      local pos
      plugin, pos = cstr(p, 2)
      nonce = p:sub(pos):gsub("%z$", "")
      self:write_packet(scramble(plugin, password, nonce))
    elseif h == 0x01 then
      local data = p:sub(2)
      if plugin == "caching_sha2_password" and data == "\3" then
        -- fast authentication succeeded; OK follows
      elseif plugin == "caching_sha2_password" and data == "\4" and self.tls then
        -- Full authentication over TLS: the password is sent as is.
        self:write_packet(password .. "\0")
      elseif plugin == "caching_sha2_password" and data == "\4" then
        -- Full authentication. Without TLS the password must be RSA-encrypted with the
        -- server's public key (requested with 0x02).
        self:write_packet("\2")
        local kp = self:read_packet()
        if kp:byte(1) == 0xff then
          raise_err(kp, "auth")
        end
        local rsa = require("dbdash.crypto.rsa")
        local key = rsa.from_pem(kp:sub(2))
        local pw = password .. "\0"
        local mask = string.rep(nonce, math.ceil(#pw / #nonce)):sub(1, #pw)
        self:write_packet(rsa.oaep_encrypt(key, util.xor(pw, mask)))
      else
        dberr.raise("auth", "unexpected authentication data from the server")
      end
    else
      dberr.raise("decode", ("unexpected packet 0x%02x during authentication"):format(h))
    end
  end
end

---Read a column definition packet.
local function parse_column(p)
  local pos = 1
  local _, name
  for _ = 1, 4 do -- catalog, schema, table, org_table
    _, pos = read_lenenc_str(p, pos)
  end
  name, pos = read_lenenc_str(p, pos)
  _, pos = read_lenenc_str(p, pos) -- org_name
  pos = pos + 1 -- length of fixed fields (0x0c)
  local charset = read_le(p, pos, 2)
  local t = p:byte(pos + 6)
  local flags = read_le(p, pos + 7, 2)
  local tn = TYPE_NAMES[t] or ("type " .. t)
  if bit.band(flags, FLAG_UNSIGNED) ~= 0 then
    tn = tn .. " UNSIGNED"
  end
  return { name = name, type = M.logical(t, flags, charset), db_type = tn }
end
M.parse_column = parse_column

local function is_eof(p)
  return p:byte(1) == 0xfe and #p < 9
end

function Conn:execute(query, opts)
  local max = opts.max_rows or 10000
  self.seq = 0
  self:write_packet("\3" .. query)
  local result, err, warnings = nil, nil, {}
  while true do
    local p = self:read_packet()
    local h = p:byte(1)
    local more
    if h == 0xff then
      -- An error ends the whole multi-statement batch.
      err = p
      break
    elseif h == 0x00 then
      local ok = parse_ok(p)
      if not result then
        result = { columns = {}, rows = {}, affected = ok.affected }
      end
      if ok.warnings > 0 then
        warnings[#warnings + 1] = ok.warnings .. " warning(s)"
      end
      more = bit.band(ok.status, SERVER_MORE_RESULTS_EXISTS) ~= 0
    elseif h == 0xfb then
      dberr.raise("query", "LOAD DATA LOCAL INFILE is not supported")
    else
      local ncols = read_lenenc(p, 1)
      local cols = {}
      for i = 1, ncols do
        cols[i] = parse_column(self:read_packet())
      end
      local eof = self:read_packet()
      if not is_eof(eof) then
        dberr.raise("decode", "expected EOF after column definitions")
      end
      local rs = { columns = cols, rows = {}, truncated = false }
      while true do
        local r = self:read_packet()
        if is_eof(r) then
          local status = read_le(r, 4, 2)
          more = bit.band(status, SERVER_MORE_RESULTS_EXISTS) ~= 0
          break
        elseif r:byte(1) == 0xff then
          err = r
          break
        end
        if #rs.rows >= max then
          rs.truncated = true
        else
          local row, pos = {}, 1
          for i = 1, ncols do
            local v
            v, pos = read_lenenc_str(r, pos)
            row[i] = v == nil and NULL or decode_value(v, cols[i])
          end
          rs.rows[#rs.rows + 1] = row
        end
      end
      if err then
        break
      end
      result = rs -- the last statement with columns wins
    end
    if not more then
      break
    end
  end
  if err then
    raise_err(err, "query")
  end
  result = result or { columns = {}, rows = {} }
  return resultset.new(
    result.columns,
    result.rows,
    { truncated = result.truncated, affected = result.affected, warnings = warnings }
  )
end

function Conn:close()
  pcall(function()
    self.seq = 0
    self:write_packet("\1") -- COM_QUIT
  end)
  self.sock:close()
end

---Stop the query running on `conn`: KILL QUERY <its connection id> on a new connection
---(a user can always kill the queries of its own connections).
function M.cancel(conn, info)
  if not conn.thread_id then
    return
  end
  local killer = M.connect(info)
  pcall(killer.execute, killer, ("KILL QUERY %d"):format(conn.thread_id), { max_rows = 1 })
  killer:close()
end

function Conn:server_version()
  return self.version
end

return M
