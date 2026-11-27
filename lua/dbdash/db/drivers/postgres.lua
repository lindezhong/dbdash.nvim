-- PostgreSQL driver (design §8.4): frontend/backend protocol 3.0, Simple Query, text
-- format results mapped by type OID. Authentication: cleartext, md5, SCRAM-SHA-256.
local bit = require("bit")
local dberr = require("dbdash.db.error")
local dialect = require("dbdash.db.dialect")
local resultset = require("dbdash.db.resultset")
local socket = require("dbdash.net.socket")

local M = {
  name = "postgres",
  schemes = { "postgres", "postgresql" },
  dialect = dialect.get("postgres"),
  capabilities = { tls = true, sql = true, query_language = "sql" },
}

local NULL = vim.NIL

-- Wire helpers ---------------------------------------------------------------------------

local function i32(n)
  return string.char(
    bit.band(bit.rshift(n, 24), 255),
    bit.band(bit.rshift(n, 16), 255),
    bit.band(bit.rshift(n, 8), 255),
    bit.band(n, 255)
  )
end

local function read_i32(s, pos)
  local a, b, c, d = s:byte(pos, pos + 3)
  return bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d), pos + 4
end

local function read_i16(s, pos)
  local a, b = s:byte(pos, pos + 1)
  local n = a * 256 + b
  if n >= 32768 then
    n = n - 65536
  end
  return n, pos + 2
end

local function read_cstr(s, pos)
  local z = s:find("\0", pos, true)
  return s:sub(pos, z - 1), z + 1
end

---Frontend message: type byte + length + body (startup messages have no type byte).
local function message(t, body)
  return (t or "") .. i32(#body + 4) .. body
end
M.message = message

---Read one backend message: type, body.
local function read_message(sock)
  local head = sock:read_exact(5)
  local t = head:sub(1, 1)
  local len = read_i32(head, 2)
  local body = len > 4 and sock:read_exact(len - 4) or ""
  return t, body
end
M.read_message = read_message

---Fields of an ErrorResponse / NoticeResponse.
function M.parse_error(body)
  local f, pos = {}, 1
  while pos <= #body do
    local code = body:sub(pos, pos)
    if code == "\0" then
      break
    end
    local v
    v, pos = read_cstr(body, pos + 1)
    f[code] = v
  end
  return f
end

local function raise_pg(phase, body)
  local f = M.parse_error(body)
  local detail = f.D
  if f.H then
    detail = (detail and (detail .. "\n") or "") .. "hint: " .. f.H
  end
  if f.C == "28P01" or f.C == "28000" then
    phase = "auth"
  end
  dberr.raise(
    phase,
    f.M or "unknown error",
    { code = f.C, detail = detail, position = tonumber(f.P) }
  )
end

-- Type mapping ----------------------------------------------------------------------------

local TYPES = {
  [16] = "boolean",
  [17] = "bytes",
  [18] = "string",
  [19] = "string",
  [25] = "string",
  [1042] = "string",
  [1043] = "string",
  [20] = "integer",
  [21] = "integer",
  [23] = "integer",
  [26] = "integer",
  [700] = "number",
  [701] = "number",
  [1700] = "decimal",
  [790] = "decimal",
  [1082] = "date",
  [1083] = "time",
  [1266] = "time",
  [1114] = "datetime",
  [1184] = "datetime",
  [114] = "json",
  [3802] = "json",
  [2950] = "uuid",
}

-- Array type OID -> element type OID.
local ARRAYS = {
  [1000] = 16,
  [1001] = 17,
  [1002] = 18,
  [1003] = 19,
  [1005] = 21,
  [1007] = 23,
  [1009] = 25,
  [1014] = 1042,
  [1015] = 1043,
  [1016] = 20,
  [1021] = 700,
  [1022] = 701,
  [1231] = 1700,
  [1182] = 1082,
  [1183] = 1083,
  [1115] = 1114,
  [1185] = 1184,
  [199] = 114,
  [3807] = 3802,
  [2951] = 2950,
  [1028] = 26,
}

local TYPE_NAMES = {
  [16] = "bool",
  [17] = "bytea",
  [18] = "char",
  [19] = "name",
  [25] = "text",
  [1042] = "bpchar",
  [1043] = "varchar",
  [20] = "int8",
  [21] = "int2",
  [23] = "int4",
  [26] = "oid",
  [700] = "float4",
  [701] = "float8",
  [1700] = "numeric",
  [790] = "money",
  [1082] = "date",
  [1083] = "time",
  [1266] = "timetz",
  [1114] = "timestamp",
  [1184] = "timestamptz",
  [114] = "json",
  [3802] = "jsonb",
  [2950] = "uuid",
}

local function logical(oid)
  if ARRAYS[oid] then
    return "array"
  end
  return TYPES[oid] or "unknown"
end
M.logical = logical

local function decode_bytea(s)
  if s:sub(1, 2) == "\\x" then
    return (s:sub(3):gsub("%x%x", function(h)
      return string.char(tonumber(h, 16))
    end))
  end
  -- escape format: \\ and \ooo
  return (
    s:gsub("\\(%d%d%d)", function(o)
      return string.char(tonumber(o, 8))
    end):gsub("\\\\", "\\")
  )
end

local decode_value

---Parse a text-format array literal: {1,2,NULL}, {"a b",c}, nested {{1,2},{3,4}}.
function M.parse_array(s, elem_oid)
  local pos = 1
  -- Optional dimension decoration: [1:2]={...}
  local eq = s:match("^%[[^=]*%]=()")
  if eq then
    pos = eq
  end
  local function parse()
    assert(s:sub(pos, pos) == "{", "array literal must start with {")
    pos = pos + 1
    local out = {}
    if s:sub(pos, pos) == "}" then
      pos = pos + 1
      return out
    end
    while true do
      local c = s:sub(pos, pos)
      if c == "{" then
        out[#out + 1] = parse()
      elseif c == '"' then
        local buf = {}
        pos = pos + 1
        while true do
          local d = s:sub(pos, pos)
          if d == "\\" then
            buf[#buf + 1] = s:sub(pos + 1, pos + 1)
            pos = pos + 2
          elseif d == '"' then
            pos = pos + 1
            break
          else
            buf[#buf + 1] = d
            pos = pos + 1
          end
        end
        out[#out + 1] = decode_value(table.concat(buf), elem_oid)
      else
        local e = s:find("[,}]", pos)
        local raw = s:sub(pos, e - 1)
        pos = e
        out[#out + 1] = raw == "NULL" and NULL or decode_value(raw, elem_oid)
      end
      local sep = s:sub(pos, pos)
      pos = pos + 1
      if sep == "}" then
        return out
      end
    end
  end
  return parse()
end

---Decode one text-format value by type OID.
function decode_value(s, oid)
  local elem = ARRAYS[oid]
  if elem then
    return M.parse_array(s, elem)
  end
  local t = TYPES[oid]
  if t == "integer" then
    return resultset.integer(s)
  elseif t == "number" then
    if s == "NaN" then
      return 0 / 0
    elseif s == "Infinity" then
      return math.huge
    elseif s == "-Infinity" then
      return -math.huge
    end
    return tonumber(s)
  elseif t == "boolean" then
    return s == "t"
  elseif t == "bytes" then
    return decode_bytea(s)
  elseif t == "json" then
    return require("dbdash.db.json").decode(s)
  end
  return s
end
M.decode_value = decode_value

-- Authentication --------------------------------------------------------------------------

local function md5_password(user, password, salt)
  local md5 = require("dbdash.crypto.md5")
  local hex = require("dbdash.crypto.util").hex
  return "md5" .. hex(md5.digest(hex(md5.digest(password .. user)) .. salt))
end
M.md5_password = md5_password

---SCRAM-SHA-256 exchange as used by PostgreSQL (the user name is sent empty).
---@param send_initial fun(mech: string, data: string)
---@param send fun(data: string)
---@param recv fun(): integer, string next auth code and payload
function M.scram(password, send_initial, send, recv, nonce, user)
  local client = require("dbdash.crypto.scram").new({
    hash = require("dbdash.crypto.sha256"),
    user = user,
    password = password,
    nonce = nonce,
  })
  send_initial("SCRAM-SHA-256", client:first())
  local code, server_first = recv()
  if code ~= 11 then
    dberr.raise("auth", "unexpected SASL message " .. code)
  end
  send(client:final(server_first))
  local code2, server_final = recv()
  if code2 ~= 12 then
    dberr.raise("auth", "unexpected SASL message " .. code2)
  end
  client:verify(server_final)
end

-- Connection ------------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

function M.parse_url(info)
  info.host = info.host or "localhost"
  info.port = info.port or 5432
  if not info.user or info.user == "" then
    info.user = vim.env.PGUSER or vim.env.USER or "postgres"
  end
  info.database = info.database or info.user
  return info
end

function M.connect(info)
  local sock = socket.connect(
    info.host,
    info.port,
    { connect_timeout = info.connect_timeout, timeout = info.timeout }
  )
  local c = setmetatable({ sock = sock, params = {} }, Conn)
  local ok, err = pcall(function()
    if info.tls ~= "disable" then
      -- SSLRequest, then the TLS handshake on the same connection.
      sock:write(i32(8) .. i32(80877103))
      local answer = sock:read_exact(1)
      if answer ~= "S" then
        dberr.raise("tls", "the server does not accept TLS connections (ssl is off)")
      end
      require("dbdash.net.tls").from_info(sock, info)
    end
    c:startup(info)
  end)
  if not ok then
    sock:close()
    error(err, 0)
  end
  return c
end

function Conn:startup(info)
  local sock = self.sock
  local params = {
    "user",
    info.user,
    "database",
    info.database,
    "application_name",
    info.application_name,
    "client_encoding",
    "UTF8",
  }
  if info.params.options then
    vim.list_extend(params, { "options", info.params.options })
  end
  local body = i32(196608) .. table.concat(params, "\0") .. "\0\0"
  sock:write(message(nil, body))

  local function need_password()
    if not info.password then
      dberr.raise("auth", "the server requires a password, but the URL has none")
    end
    return info.password
  end

  while true do
    local t, b = read_message(sock)
    if t == "R" then
      local code = read_i32(b, 1)
      if code == 0 then
        -- AuthenticationOk
      elseif code == 3 then
        sock:write(message("p", need_password() .. "\0"))
      elseif code == 5 then
        sock:write(message("p", md5_password(info.user, need_password(), b:sub(5, 8)) .. "\0"))
      elseif code == 10 then
        local mechs = b:sub(5)
        if not mechs:find("SCRAM-SHA-256\0", 1, true) then
          dberr.raise(
            "auth",
            "no supported SASL mechanism (server offers: " .. mechs:gsub("\0", " ") .. ")"
          )
        end
        M.scram(need_password(), function(mech, data)
          sock:write(message("p", mech .. "\0" .. i32(#data) .. data))
        end, function(data)
          sock:write(message("p", data))
        end, function()
          local rt, rb = read_message(sock)
          if rt == "E" then
            raise_pg("auth", rb)
          end
          return read_i32(rb, 1), rb:sub(5)
        end)
      else
        dberr.raise("auth", ("unsupported authentication method (code %d)"):format(code))
      end
    elseif t == "S" then
      local k, pos = read_cstr(b, 1)
      self.params[k] = read_cstr(b, pos)
    elseif t == "K" then
      self.backend_key = b -- BackendKeyData (process id and secret key): see M.cancel
    elseif t == "Z" then
      return
    elseif t == "E" then
      raise_pg("connect", b)
    elseif t == "N" then
      -- notice during startup: ignore
    else
      dberr.raise("decode", ("unexpected message %q during startup"):format(t))
    end
  end
end

function Conn:execute(query, opts)
  local sock = self.sock
  local max = opts.max_rows or 10000
  sock:write(message("Q", query .. "\0"))
  local result, current, err, warnings = nil, nil, nil, {}
  while true do
    local t, b = read_message(sock)
    if t == "T" then
      local n, pos = read_i16(b, 1)
      local fields = {}
      for i = 1, n do
        local name
        name, pos = read_cstr(b, pos)
        local _, oid
        _, pos = read_i32(b, pos) -- table oid
        _, pos = read_i16(b, pos) -- attribute number
        oid, pos = read_i32(b, pos)
        pos = pos + 2 + 4 + 2 -- typlen, typmod, format
        fields[i] = {
          name = name,
          type = logical(oid),
          db_type = TYPE_NAMES[oid] or ("oid " .. oid),
          oid = oid,
        }
      end
      current = { columns = fields, rows = {}, truncated = false }
    elseif t == "D" then
      if current and not err then
        if #current.rows >= max then
          current.truncated = true
        else
          local n, pos = read_i16(b, 1)
          local row = {}
          for i = 1, n do
            local len
            len, pos = read_i32(b, pos)
            if len < 0 then
              row[i] = NULL
            else
              local raw = b:sub(pos, pos + len - 1)
              pos = pos + len
              local ok, v = pcall(decode_value, raw, current.columns[i].oid)
              row[i] = ok and v or raw
            end
          end
          current.rows[#current.rows + 1] = row
        end
      end
    elseif t == "C" then
      local tag = read_cstr(b, 1)
      if current then
        result = current
        current = nil
      elseif not result then
        result = { columns = {}, rows = {}, affected = tonumber(tag:match("(%d+)$")) }
      end
    elseif t == "I" then
      -- empty query
    elseif t == "E" then
      err = err or b
    elseif t == "N" then
      local f = M.parse_error(b)
      warnings[#warnings + 1] = (f.S or "NOTICE") .. ": " .. (f.M or "")
    elseif t == "S" then
      local k, pos = read_cstr(b, 1)
      self.params[k] = read_cstr(b, pos)
    elseif t == "Z" then
      break
    end
  end
  if err then
    raise_pg("query", err)
  end
  result = result or { columns = {}, rows = {} }
  for _, c in ipairs(result.columns) do
    c.oid = nil
  end
  return resultset.new(
    result.columns,
    result.rows,
    { truncated = result.truncated, affected = result.affected, warnings = warnings }
  )
end

function Conn:close()
  pcall(function()
    self.sock:write(message("X", ""))
  end)
  self.sock:close()
end

function Conn:server_version()
  return self.params.server_version
end

---Stop the query running on `conn`: a CancelRequest with its BackendKeyData on a new
---connection (plain TCP, like libpq: the server reads it before any TLS or login).
function M.cancel(conn, info)
  if not conn.backend_key then
    return
  end
  local sock = socket.connect(
    info.host,
    info.port,
    { connect_timeout = info.connect_timeout, timeout = info.connect_timeout }
  )
  pcall(function()
    sock:write(i32(8 + #conn.backend_key) .. i32(80877102) .. conn.backend_key)
    sock:read_to_eof(1024) -- the server closes the connection once it has the request
  end)
  sock:close()
end

return M
