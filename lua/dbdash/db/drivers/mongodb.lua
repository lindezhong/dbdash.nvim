-- MongoDB driver (design §8.5): OP_MSG over TCP (or TLS), SCRAM-SHA-256 / SCRAM-SHA-1
-- authentication, and a JSON query document:
--   { "collection": "orders", "operation": "find" | "aggregate" | "count" | "distinct",
--     "filter": {...}, "projection": {...}, "sort": {...}, "limit": 100,
--     "pipeline": [...], "field": "region", "flatten": 1 }
-- "collection" may be omitted for aggregate to run a database-level pipeline.
-- Each document is a row; columns are the union of top-level keys in first-seen order;
-- nested documents are expanded to "a.b" columns up to `flatten` levels.
local bson = require("dbdash.db.bson")
local dberr = require("dbdash.db.error")
local dialect = require("dbdash.db.dialect")
local json = require("dbdash.db.json")
local map = require("dbdash.util.map")
local resultset = require("dbdash.db.resultset")
local socket = require("dbdash.net.socket")

local M = {
  name = "mongodb",
  schemes = { "mongodb", "mongodb+srv" },
  dialect = dialect.get("mongodb"),
  capabilities = { tls = true, sql = false, query_language = "mongo-json" },
}

local NULL = vim.NIL
local OP_MSG = 2013

local function doc(pairs_)
  return map.from_pairs(pairs_)
end

-- Connection ------------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

---Send a command document and return the reply document. Raises on ok: 0.
function Conn:command(cmd, phase)
  self.request_id = (self.request_id or 0) + 1
  local body = "\0\0\0\0" .. "\0" .. bson.encode(cmd)
  local header = bson.i32(16 + #body) .. bson.i32(self.request_id) .. bson.i32(0) .. bson.i32(OP_MSG)
  self.sock:write(header .. body)
  local h = self.sock:read_exact(16)
  local len = bson.rd_i32(h, 1)
  local op = bson.rd_i32(h, 13)
  local payload = self.sock:read_exact(len - 16)
  if op ~= OP_MSG then
    dberr.raise("decode", "unexpected MongoDB reply opcode " .. op)
  end
  if payload:byte(5) ~= 0 then
    dberr.raise("decode", "unexpected OP_MSG section kind " .. payload:byte(5))
  end
  local reply = bson.decode(payload, 6)
  if reply.ok ~= 1 then
    local code = reply.codeName or (reply.code and tostring(reply.code)) or nil
    local p = phase or "query"
    if reply.code == 18 or reply.codeName == "AuthenticationFailed" then
      p = "auth"
    end
    dberr.raise(p, tostring(reply.errmsg or "command failed"), { code = code })
  end
  return reply
end

local function payload_of(reply)
  local p = reply.payload
  if bson.is_tagged(p) then
    return p.value
  end
  return tostring(p or "")
end

function Conn:auth(info)
  local mech = info.params.authMechanism or "SCRAM-SHA-256"
  local source = info.params.authSource or info.database or "admin"
  local hash, password
  if mech == "SCRAM-SHA-256" then
    hash, password = require("dbdash.crypto.sha256"), info.password
  elseif mech == "SCRAM-SHA-1" then
    local util = require("dbdash.crypto.util")
    hash = require("dbdash.crypto.sha1")
    password = util.hex(require("dbdash.crypto.md5").digest(info.user .. ":mongo:" .. info.password))
  else
    dberr.raise("config", "unsupported authMechanism " .. mech .. " (use SCRAM-SHA-256 or SCRAM-SHA-1)")
  end
  local client = require("dbdash.crypto.scram").new({ hash = hash, user = info.user, password = password })
  local reply = self:command(doc({
    { "saslStart", 1 },
    { "mechanism", mech },
    { "payload", M.bin(client:first()) },
    { "autoAuthorize", 1 },
    { "options", doc({ { "skipEmptyExchange", true } }) },
    { "$db", source },
  }), "auth")
  local final = client:final(payload_of(reply))
  reply = self:command(doc({
    { "saslContinue", 1 },
    { "conversationId", reply.conversationId },
    { "payload", M.bin(final) },
    { "$db", source },
  }), "auth")
  client:verify(payload_of(reply))
  if reply.done ~= true then
    reply = self:command(doc({
      { "saslContinue", 1 },
      { "conversationId", reply.conversationId },
      { "payload", M.bin("") },
      { "$db", source },
    }), "auth")
  end
end

---A BSON binary value (subtype 0) for command payloads.
function M.bin(s)
  return map.from_pairs({ { "$binary", s } })
end

---Is an SRV target acceptable for the queried host (Initial DNS Seedlist Discovery)?
---Targets must share the host's parent domain; for one- or two-label hosts, they must end
---in ".<host>".
function M.srv_target_ok(host, target)
  host, target = host:lower():gsub("%.$", ""), target:lower():gsub("%.$", "")
  local labels = select(2, host:gsub("%.", ".")) + 1
  local suffix = labels >= 3 and host:gsub("^[^.]+", "") or ("." .. host)
  return #target > #suffix and target:sub(-#suffix) == suffix
end

local TXT_OPTIONS = { authSource = true, replicaSet = true, loadBalanced = true }

function M.parse_url(info)
  info.srv = info.scheme == "mongodb+srv"
  if info.srv then
    if #info.hosts ~= 1 or info.port then
      dberr.raise("config", "mongodb+srv URLs take exactly one host name and no port")
    end
    if info.params.tls == nil and info.params.ssl == nil then
      info.tls = "verify-full" -- as the mongodb+srv specification requires TLS
    end
  end
  for _, h in ipairs(info.hosts) do
    h.host = h.host or "localhost"
    h.port = h.port or 27017
  end
  info.host, info.port = info.hosts[1].host, info.hosts[1].port
  info.database = info.database or "test"
  local t = info.params.tls or info.params.ssl
  if (t == "true" or t == "1") and info.tls == "disable" then
    info.tls = "require"
  end
  info.read_preference = info.params.readPreference or "primary"
  local rp = { primary = true, primaryPreferred = true, secondary = true, secondaryPreferred = true, nearest = true }
  if not rp[info.read_preference] then
    dberr.raise("config", "unknown readPreference " .. info.read_preference)
  end
  return info
end

---Resolve a mongodb+srv host: SRV targets (validated) and TXT options.
local function resolve_srv(info)
  local dns = require("dbdash.net.dns")
  local opts = { server = info.params.dns }
  local name = info.host
  local recs = dns.srv("_mongodb._tcp." .. name, opts)
  if #recs == 0 then
    dberr.raise("connect", "no SRV records for _mongodb._tcp." .. name)
  end
  local hosts = {}
  for _, r in ipairs(recs) do
    local target = r.target:gsub("%.$", "")
    if not M.srv_target_ok(name, target) then
      dberr.raise("connect", ("SRV target %s is not in the domain of %s"):format(target, name))
    end
    hosts[#hosts + 1] = { host = target, port = r.port }
  end
  local ok, txts = pcall(dns.txt, name, opts)
  if ok and #txts > 1 then
    dberr.raise("connect", "more than one TXT record for " .. name)
  elseif ok and #txts == 1 then
    for k, v in txts[1]:gmatch("([^&=]+)=([^&]*)") do
      if not TXT_OPTIONS[k] then
        dberr.raise("connect", ("TXT option %s is not allowed for mongodb+srv"):format(k))
      end
      if info.params[k] == nil then
        info.params[k] = v
      end
    end
  end
  return hosts
end

---Connect to one host (TLS as configured) and send hello.
local function open(info, host, port)
  local sock = socket.connect(host, port, { connect_timeout = info.connect_timeout, timeout = info.timeout })
  local c = setmetatable({ sock = sock, db = info.database }, Conn)
  local ok, res = pcall(function()
    if info.tls ~= "disable" then
      local per_host = setmetatable({ host = host }, { __index = info })
      require("dbdash.net.tls").from_info(sock, per_host)
    end
    return c:command(doc({ { "hello", 1 }, { "$db", "admin" } }), "connect")
  end)
  if not ok then
    sock:close()
    error(res, 0)
  end
  c.max_wire = res.maxWireVersion
  return c, res
end

M.open = open -- replaceable in tests

local function writable(hello)
  return hello.isWritablePrimary == true or hello.ismaster == true
end

---Try the hosts in order: use a writable primary (following hello.primary when a member
---names another one), or with a non-primary readPreference the first reachable member.
function M.connect(info)
  local hosts = info.hosts
  if info.srv then
    hosts = resolve_srv(info)
  end
  local any = info.read_preference ~= "primary"
  local fallback, last_err
  local function finish(c)
    local ok, err = pcall(function()
      if info.user and info.user ~= "" then
        c:auth(info)
      end
    end)
    if not ok then
      c:close()
      error(err, 0)
    end
    return c
  end
  for _, h in ipairs(hosts) do
    local ok, c, hello = pcall(M.open, info, h.host, h.port)
    if not ok then
      last_err = c
    elseif writable(hello) then
      if fallback then
        fallback:close()
      end
      return finish(c)
    elseif info.read_preference == "secondary" or info.read_preference == "secondaryPreferred" or info.read_preference == "nearest" then
      return finish(c)
    else
      local primary = type(hello.primary) == "string" and hello.primary or nil
      if any and not fallback then
        fallback = c
      else
        c:close()
      end
      if primary then
        local ph, pp = primary:match("^(.-):(%d+)$")
        local pok, pc, phello = pcall(M.open, info, ph or primary, tonumber(pp) or 27017)
        if pok and writable(phello) then
          if fallback then
            fallback:close()
          end
          return finish(pc)
        elseif pok then
          pc:close()
        else
          last_err = pc
        end
      end
      last_err = last_err or ("%s:%d is not a primary"):format(h.host, h.port)
    end
  end
  if fallback then
    return finish(fallback)
  end
  if type(last_err) == "table" then
    error(last_err, 0)
  end
  dberr.raise("connect", "no usable MongoDB server: " .. tostring(last_err))
end

-- Results ---------------------------------------------------------------------------------

local function convert(v)
  if bson.is_tagged(v) then
    local k = v.kind
    if k == "date" then
      return v.value, "datetime", "date"
    elseif k == "oid" then
      return v.value, "string", "objectId"
    elseif k == "decimal" then
      return v.value, "decimal", "decimal128"
    elseif k == "binary" then
      return v.value, "bytes", "binData"
    elseif k == "timestamp" then
      return v.value, "integer", "timestamp"
    end
    return tostring(v.value), "string", k
  end
  if v == NULL then
    return NULL, "null", "null"
  end
  local t = type(v)
  if t == "number" then
    return v, v == math.floor(v) and "integer" or "number", v == math.floor(v) and "int" or "double"
  elseif t == "string" then
    if v:match("^%-?%d+$") and #v > 15 then
      return resultset.integer(v), "integer", "long"
    end
    return v, "string", "string"
  elseif t == "boolean" then
    return v, "boolean", "bool"
  elseif map.is_map(v) then
    local out = map.new()
    for kk, vv in map.pairs(v) do
      map.set(out, kk, (convert(vv)))
    end
    return out, "json", "object"
  elseif t == "table" then
    local out = {}
    for i, vv in ipairs(v) do
      out[i] = (convert(vv))
    end
    return out, "array", "array"
  end
  return tostring(v), "unknown", t
end

---Flatten nested documents into "a.b" keys, up to `levels` deep.
local function flatten(d, levels, prefix, out)
  out = out or map.new()
  for k, v in map.pairs(d) do
    local key = prefix and (prefix .. "." .. k) or k
    if levels > 0 and map.is_map(v) and not bson.is_tagged(v) then
      flatten(v, levels - 1, key, out)
    else
      map.set(out, key, v)
    end
  end
  return out
end

---Documents -> ResultSet.
function M.to_resultset(docs, flatten_levels, max_rows, truncated)
  local names, index = {}, {}
  local flat = {}
  for i, d in ipairs(docs) do
    local fd = flatten_levels > 0 and flatten(d, flatten_levels) or d
    flat[i] = fd
    for _, k in ipairs(map.keys(fd)) do
      if not index[k] then
        names[#names + 1] = k
        index[k] = #names
      end
    end
  end
  local rows, ltypes, dbtypes = {}, {}, {}
  for r, fd in ipairs(flat) do
    local row = {}
    for c, name in ipairs(names) do
      local raw = fd[name]
      if raw == nil then
        row[c] = NULL
      else
        local v, lt, dt = convert(raw)
        row[c] = v
        if lt ~= "null" and not ltypes[c] then
          ltypes[c], dbtypes[c] = lt, dt
        end
      end
    end
    rows[r] = row
  end
  local columns = {}
  for c, name in ipairs(names) do
    columns[c] = { name = name, type = ltypes[c] or "null", db_type = dbtypes[c] }
  end
  return resultset.new(columns, rows, { truncated = truncated })
end

-- Queries ---------------------------------------------------------------------------------

local function opt(q, key)
  local v = q[key]
  if v == nil or v == NULL then
    return nil
  end
  return v
end

---Run a cursor command, following getMore until done or max_rows is exceeded.
function Conn:cursor(cmd, coll, max_rows)
  local reply = self:command(cmd)
  local cur = reply.cursor
  local docs = {}
  local function take(batch)
    for _, d in ipairs(batch or {}) do
      docs[#docs + 1] = d
    end
  end
  take(cur.firstBatch)
  local id = cur.id
  while id ~= 0 and id ~= "0" and #docs <= max_rows do
    local r = self:command(doc({
      { "getMore", json.int64(tostring(id)) },
      { "collection", coll == 1 and "$cmd.aggregate" or coll },
      { "batchSize", math.min(max_rows + 1 - #docs, 10000) },
      { "$db", self.db },
    }))
    take(r.cursor.nextBatch)
    id = r.cursor.id
  end
  if id ~= 0 and id ~= "0" then
    pcall(self.command, self, doc({
      { "killCursors", coll == 1 and "$cmd.aggregate" or coll },
      { "cursors", { json.int64(tostring(id)) } },
      { "$db", self.db },
    }))
  end
  local truncated = #docs > max_rows
  while #docs > max_rows do
    docs[#docs] = nil
  end
  return docs, truncated
end

function Conn:execute(query, opts)
  local max = opts.max_rows or 10000
  local q = json.parse(query)
  if not map.is_map(q) then
    dberr.raise("query", "a MongoDB query must be a JSON object")
  end
  local coll = opt(q, "collection")
  local op = opt(q, "operation") or "find"
  if op == "aggregate" and coll == nil then
    coll = 1 -- database-level aggregation ($documents, $currentOp, ...)
  elseif op ~= "command" and type(coll) ~= "string" then
    dberr.raise("query", 'the query needs "collection": "<name>"')
  end
  local db = opt(q, "database") or self.db
  local filter = opt(q, "filter") or map.new()
  local levels = tonumber(opt(q, "flatten")) or 0
  self.db = db
  -- A comment marks the operation so that M.cancel can find it (servers from 4.4 accept it
  -- on every command used here).
  self.op_comment = nil
  if (self.max_wire or 0) >= 9 and op ~= "command" then
    self.op_comment = "dbdash:" .. require("dbdash.util.uuid").v7()
  end
  ---The command document of `fields`, with the comment and the database.
  local function command(fields)
    if self.op_comment then
      fields[#fields + 1] = { "comment", self.op_comment }
    end
    fields[#fields + 1] = { "$db", db }
    return doc(fields)
  end

  if op == "find" then
    local limit = tonumber(opt(q, "limit"))
    local fields = {
      { "find", coll },
      { "filter", filter },
    }
    if opt(q, "projection") then
      fields[#fields + 1] = { "projection", q.projection }
    end
    if opt(q, "sort") then
      fields[#fields + 1] = { "sort", q.sort }
    end
    if opt(q, "skip") then
      fields[#fields + 1] = { "skip", q.skip }
    end
    if limit then
      fields[#fields + 1] = { "limit", limit }
    end
    fields[#fields + 1] = { "batchSize", math.min(max + 1, 10000) }
    local docs, truncated = self:cursor(command(fields), coll, max)
    return M.to_resultset(docs, levels, max, truncated)
  elseif op == "aggregate" then
    local pipeline = opt(q, "pipeline") or {}
    local docs, truncated = self:cursor(command({
      { "aggregate", coll },
      { "pipeline", pipeline },
      { "cursor", doc({ { "batchSize", math.min(max + 1, 10000) } }) },
    }), coll, max)
    return M.to_resultset(docs, levels, max, truncated)
  elseif op == "count" then
    local r = self:command(command({ { "count", coll }, { "query", filter } }))
    return resultset.new({ { name = "count", type = "integer", db_type = "int" } }, { { r.n } })
  elseif op == "distinct" then
    local field = opt(q, "field")
    if type(field) ~= "string" then
      dberr.raise("query", 'distinct needs "field": "<name>"')
    end
    local r = self:command(command({ { "distinct", coll }, { "key", field }, { "query", filter } }))
    local docs = {}
    for i, v in ipairs(r.values or {}) do
      docs[i] = map.from_pairs({ { field, v } })
    end
    return M.to_resultset(docs, 0, max, false)
  end
  if op == "command" then
    -- Any database command; the reply becomes one row (without "ok").
    local cmd = opt(q, "command")
    if not map.is_map(cmd) then
      dberr.raise("query", 'operation "command" needs "command": { ... }')
    end
    local full = map.new()
    for k, v in map.pairs(cmd) do
      map.set(full, k, v)
    end
    map.set(full, "$db", db)
    local reply = self:command(full)
    local row = map.new()
    for k, v in map.pairs(reply) do
      if k ~= "ok" and k:sub(1, 1) ~= "$" then
        map.set(row, k, v)
      end
    end
    return M.to_resultset({ row }, levels, max, false)
  end
  dberr.raise("query", ("unknown operation %q (use find, aggregate, count, distinct or command)"):format(op))
end

function Conn:close()
  self.sock:close()
end

---Stop the operation running on `conn`: on a new connection, find it by its comment
---($currentOp) and killOp it (users may kill their own operations).
function M.cancel(conn, info)
  local tag = conn.op_comment
  if not tag then
    return
  end
  local c = M.connect(info)
  pcall(function()
    local reply = c:command(doc({
      { "aggregate", 1 },
      {
        "pipeline",
        {
          doc({ { "$currentOp", doc({ { "allUsers", false } }) } }),
          doc({ { "$match", doc({ { "command.comment", tag } }) } }),
        },
      },
      { "cursor", doc({}) },
      { "$db", "admin" },
    }))
    for _, op in ipairs(reply.cursor and reply.cursor.firstBatch or {}) do
      pcall(c.command, c, doc({ { "killOp", 1 }, { "op", op.opid }, { "$db", "admin" } }))
    end
  end)
  c:close()
end

return M
