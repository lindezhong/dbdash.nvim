-- Redis driver (:help dbdash-databases): one command per query, tokenized shell-style; replies are
-- mapped to tables by command, with generic fallbacks.
--
-- Connects with HELLO 3 (RESP3: maps, doubles, booleans) and falls back to RESP2 + AUTH
-- for servers that do not know HELLO.
local dberr = require("dbdash.util.error")
local map = require("dbdash.util.map")
local resultset = require("dbdash.db.resultset")
local socket = require("dbdash.net.socket")

local M = {
  name = "redis",
  schemes = { "redis", "rediss" },
  -- Redis commands are tokenized shell-style: double quotes with backslash escapes
  dialect = require("dbdash.db.dialect").make("redis", {
    quote_string = function(s)
      return '"' .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
    end,
    quote_ident = function(s)
      return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
    end,
    boolean_literal = function(b)
      return b and "1" or "0"
    end,
    null = '""',
  }),
  capabilities = { tls = true, sql = false, query_language = "redis-command" },
}

local NULL = vim.NIL

-- RESP ------------------------------------------------------------------------------------

---@class dbdash.redis.Error
---@field redis_error string

local ErrMT = {}

local function is_err(v)
  return getmetatable(v) == ErrMT
end

---Encode a command as a RESP array of bulk strings.
function M.encode(args)
  local out = { "*" .. #args .. "\r\n" }
  for _, a in ipairs(args) do
    a = tostring(a)
    out[#out + 1] = "$" .. #a .. "\r\n" .. a .. "\r\n"
  end
  return table.concat(out)
end

---Read one reply from a socket-like object (read_until, read_exact).
function M.read_reply(sock)
  local line = sock:read_until("\r\n"):sub(1, -3)
  local t, rest = line:sub(1, 1), line:sub(2)
  if t == "+" then
    return rest
  elseif t == "-" then
    return setmetatable({ redis_error = rest }, ErrMT)
  elseif t == ":" then
    return resultset.integer(rest)
  elseif t == "$" or t == "=" or t == "!" then
    local n = tonumber(rest)
    if n < 0 then
      return NULL
    end
    local s = sock:read_exact(n + 2):sub(1, n)
    if t == "=" then
      return s:sub(5) -- "txt:" / "mkd:" prefix
    elseif t == "!" then
      return setmetatable({ redis_error = s }, ErrMT)
    end
    return s
  elseif t == "*" or t == "~" or t == ">" then
    local n = tonumber(rest)
    if n < 0 then
      return NULL
    end
    local arr = {}
    for i = 1, n do
      arr[i] = M.read_reply(sock)
    end
    if t == ">" then -- out-of-band push: skip it and read the actual reply
      return M.read_reply(sock)
    end
    return arr
  elseif t == "%" then
    local m = map.new()
    for _ = 1, tonumber(rest) do
      local k = M.read_reply(sock)
      map.set(m, type(k) == "table" and vim.json.encode(k) or k, M.read_reply(sock))
    end
    return m
  elseif t == "|" then -- attributes precede the real reply
    for _ = 1, tonumber(rest) * 2 do
      M.read_reply(sock)
    end
    return M.read_reply(sock)
  elseif t == "_" then
    return NULL
  elseif t == "," then
    local l = rest:lower()
    if l == "inf" then
      return math.huge
    elseif l == "-inf" then
      return -math.huge
    elseif l == "nan" then
      return 0 / 0
    end
    return tonumber(rest)
  elseif t == "#" then
    return rest == "t"
  elseif t == "(" then
    return resultset.integer(rest)
  end
  dberr.raise("decode", ("unexpected RESP type byte %q"):format(t))
end

-- Tokenizer -------------------------------------------------------------------------------

local ESC =
  { n = "\n", r = "\r", t = "\t", b = "\b", a = "\a", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }

---Split a command line like redis-cli: whitespace separates, quotes group, backslashes
---escape (\n, \t, \xHH inside double quotes).
---@param s string
---@return string[]
function M.tokenize(s)
  local out, cur, i, n = {}, nil, 1, #s
  local function push(ch)
    cur = (cur or "") .. ch
  end
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      if cur then
        out[#out + 1] = cur
        cur = nil
      end
      i = i + 1
    elseif c == '"' then
      cur = cur or ""
      i = i + 1
      while true do
        if i > n then
          dberr.raise("query", "unbalanced double quote in command")
        end
        local d = s:sub(i, i)
        if d == '"' then
          i = i + 1
          break
        elseif d == "\\" then
          local e = s:sub(i + 1, i + 1)
          if e == "x" and s:sub(i + 2, i + 3):match("^%x%x$") then
            push(string.char(tonumber(s:sub(i + 2, i + 3), 16)))
            i = i + 4
          else
            push(ESC[e] or e)
            i = i + 2
          end
        else
          push(d)
          i = i + 1
        end
      end
    elseif c == "'" then
      cur = cur or ""
      i = i + 1
      while true do
        if i > n then
          dberr.raise("query", "unbalanced single quote in command")
        end
        local d = s:sub(i, i)
        if d == "'" then
          i = i + 1
          break
        elseif d == "\\" and s:sub(i + 1, i + 1) == "'" then
          push("'")
          i = i + 2
        else
          push(d)
          i = i + 1
        end
      end
    elseif c == "\\" and i < n then
      push(s:sub(i + 1, i + 1))
      i = i + 2
    else
      push(c)
      i = i + 1
    end
  end
  if cur then
    out[#out + 1] = cur
  end
  return out
end

-- Result mapping --------------------------------------------------------------------------

local function ltype(v)
  local t = type(v)
  if v == NULL then
    return "null"
  elseif t == "number" then
    return v == math.floor(v) and "integer" or "number"
  elseif t == "boolean" then
    return "boolean"
  elseif t == "table" then
    return map.is_map(v) and "json" or "array"
  end
  return "string"
end

---Build a ResultSet; column types come from the first non-NULL value.
local function build(names, rows, max_rows)
  local truncated = #rows > max_rows
  while #rows > max_rows do
    rows[#rows] = nil
  end
  local columns = {}
  for i, name in ipairs(names) do
    local t = "null"
    for _, r in ipairs(rows) do
      if r[i] ~= nil and r[i] ~= NULL then
        t = ltype(r[i])
        break
      end
    end
    columns[i] = { name = name, type = t, db_type = "redis" }
  end
  for _, r in ipairs(rows) do
    for i = 1, #names do
      if r[i] == nil then
        r[i] = NULL
      end
    end
  end
  return resultset.new(columns, rows, { truncated = truncated })
end

---Pairs from a RESP3 map or a flat RESP2 array.
local function pairs_of(reply)
  local out = {}
  if map.is_map(reply) then
    for k, v in map.pairs(reply) do
      out[#out + 1] = { k, v }
    end
  elseif type(reply) == "table" then
    for i = 1, #reply - 1, 2 do
      out[#out + 1] = { reply[i], reply[i + 1] }
    end
  end
  return out
end

local function generic(reply, max_rows)
  if map.is_map(reply) then
    local rows = {}
    for _, kv in ipairs(pairs_of(reply)) do
      rows[#rows + 1] = { kv[1], kv[2] }
    end
    return build({ "key", "value" }, rows, max_rows)
  elseif type(reply) == "table" and reply ~= NULL then
    local rows = {}
    for i, v in ipairs(reply) do
      rows[i] = { i - 1, v }
    end
    return build({ "index", "value" }, rows, max_rows)
  end
  return build({ "value" }, { { reply } }, max_rows)
end

local function has_flag(args, flag)
  for i = 2, #args do
    if args[i]:upper() == flag then
      return true
    end
  end
  return false
end

---Per-command mapping: function(reply, args, max_rows) -> ResultSet.
M.mappers = {
  GET = function(reply, args, max)
    return build({ "key", "value" }, { { args[2], reply } }, max)
  end,
  MGET = function(reply, args, max)
    local rows = {}
    for i, v in ipairs(reply) do
      rows[i] = { args[i + 1], v }
    end
    return build({ "key", "value" }, rows, max)
  end,
  HGETALL = function(reply, _, max)
    local rows = {}
    for _, kv in ipairs(pairs_of(reply)) do
      rows[#rows + 1] = kv
    end
    return build({ "field", "value" }, rows, max)
  end,
  HMGET = function(reply, args, max)
    local rows = {}
    for i, v in ipairs(reply) do
      rows[i] = { args[i + 2], v }
    end
    return build({ "field", "value" }, rows, max)
  end,
  KEYS = function(reply, _, max)
    local rows = {}
    for i, k in ipairs(reply) do
      rows[i] = { k }
    end
    return build({ "key" }, rows, max)
  end,
  LRANGE = function(reply, args, max)
    local start = tonumber(args[3]) or 0
    local rows = {}
    for i, v in ipairs(reply) do
      rows[i] = { start >= 0 and start + i - 1 or i - 1, v }
    end
    return build({ "index", "value" }, rows, max)
  end,
  SMEMBERS = function(reply, _, max)
    local rows = {}
    for i, v in ipairs(reply) do
      rows[i] = { v }
    end
    return build({ "member" }, rows, max)
  end,
  ZRANGE = function(reply, args, max)
    local rows = {}
    if has_flag(args, "WITHSCORES") then
      if type(reply[1]) == "table" then -- RESP3: [[member, score], ...]
        for i, p in ipairs(reply) do
          rows[i] = { p[1], tonumber(p[2]) }
        end
      else
        for i = 1, #reply - 1, 2 do
          rows[#rows + 1] = { reply[i], tonumber(reply[i + 1]) }
        end
      end
      return build({ "member", "score" }, rows, max)
    end
    for i, v in ipairs(reply) do
      rows[i] = { v }
    end
    return build({ "member" }, rows, max)
  end,
  INFO = function(reply, _, max)
    local rows, section = {}, ""
    for line in tostring(reply):gmatch("[^\r\n]+") do
      local s = line:match("^#%s*(.+)$")
      if s then
        section = s:lower()
      else
        local k, v = line:match("^([^:]+):(.*)$")
        if k then
          rows[#rows + 1] = { section, k, resultset.integer(v) }
        end
      end
    end
    return build({ "section", "key", "value" }, rows, max)
  end,
  XRANGE = function(reply, _, max)
    local names, index, rows = { "id" }, {}, {}
    for _, entry in ipairs(reply) do
      local row = { entry[1] }
      for _, kv in ipairs(pairs_of(entry[2])) do
        local f = tostring(kv[1])
        if not index[f] then
          names[#names + 1] = f
          index[f] = #names
        end
        row[index[f]] = kv[2]
      end
      rows[#rows + 1] = row
    end
    return build(names, rows, max)
  end,
}
M.mappers.ZREVRANGE = M.mappers.ZRANGE
M.mappers.XREVRANGE = M.mappers.XRANGE

-- Connection ------------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

---Send a command and read its reply (errors are returned, not raised).
function Conn:call(args)
  self.sock:write(M.encode(args))
  return M.read_reply(self.sock)
end

local AUTH_ERRORS = { WRONGPASS = true, NOAUTH = true, NOPERM = true }

local function raise_reply(reply, phase)
  local code = reply.redis_error:match("^(%u+)") or "ERR"
  if AUTH_ERRORS[code] then
    phase = "auth"
  end
  dberr.raise(phase, reply.redis_error, { code = code })
end

function M.parse_url(info)
  info.host = info.host or "localhost"
  info.port = info.port or 6379
  if info.scheme == "rediss" and info.tls == "disable" then
    info.tls = "require"
  end
  if info.database and not info.database:match("^%d+$") then
    dberr.raise("config", ("redis database must be a number, got %q"):format(info.database))
  end
  return info
end

function M.connect(info)
  local sock = socket.connect(
    info.host,
    info.port,
    { connect_timeout = info.connect_timeout, timeout = info.timeout }
  )
  local c = setmetatable({ sock = sock, resp = 2 }, Conn)
  local ok, err = pcall(function()
    if info.tls ~= "disable" then
      require("dbdash.net.tls").from_info(sock, info)
    end
    local hello = { "HELLO", "3" }
    if info.password then
      vim.list_extend(
        hello,
        { "AUTH", (info.user and info.user ~= "") and info.user or "default", info.password }
      )
    end
    local reply = c:call(hello)
    if is_err(reply) then
      local code = reply.redis_error:match("^(%u+)")
      if AUTH_ERRORS[code] then
        raise_reply(reply, "auth")
      end
      -- Old servers (no HELLO / no RESP3): RESP2 with AUTH.
      if info.password then
        local auth = (info.user and info.user ~= "") and { "AUTH", info.user, info.password }
          or { "AUTH", info.password }
        local r = c:call(auth)
        if is_err(r) then
          raise_reply(r, "auth")
        end
      end
    else
      c.resp = 3
      c.version = map.is_map(reply) and reply.version or nil
    end
    if info.database and info.database ~= "0" then
      local r = c:call({ "SELECT", info.database })
      if is_err(r) then
        raise_reply(r, "connect")
      end
    end
  end)
  if not ok then
    sock:close()
    error(err, 0)
  end
  return c
end

function Conn:execute(query, opts)
  local args = M.tokenize(query)
  if #args == 0 then
    dberr.raise("query", "empty command")
  end
  local cmd = args[1]:upper()
  local max = opts.max_rows or 10000
  if cmd == "SCAN" then
    -- Iterate the cursor until it returns to 0 or enough keys were collected.
    args[2] = "0"
    local rows, seen = {}, {}
    repeat
      local reply = self:call(args)
      if is_err(reply) then
        raise_reply(reply, "query")
      end
      args[2] = tostring(reply[1])
      for _, k in ipairs(reply[2]) do
        if not seen[k] then
          seen[k] = true
          rows[#rows + 1] = { k }
        end
      end
    until args[2] == "0" or #rows > max
    return build({ "key" }, rows, max)
  end
  local reply = self:call(args)
  if is_err(reply) then
    raise_reply(reply, "query")
  end
  local mapper = M.mappers[cmd]
  if mapper and type(reply) == "table" or (mapper and (cmd == "GET" or cmd == "INFO")) then
    return mapper(reply, args, max)
  end
  return generic(reply, max)
end

function Conn:close()
  self.sock:close()
end

function Conn:server_version()
  return self.version
end

-- database.options: none (dbdash.db.options)
M.options = {}

return M
