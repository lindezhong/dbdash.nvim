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

function M.parse_url(info)
  if info.scheme == "mongodb+srv" then
    dberr.raise("config", "mongodb+srv URLs are not supported yet; use mongodb://host:port")
  end
  info.host = info.host or "localhost"
  info.port = info.port or 27017
  info.database = info.database or "test"
  local t = info.params.tls or info.params.ssl
  if (t == "true" or t == "1") and info.tls == "disable" then
    info.tls = "require"
  end
  return info
end

function M.connect(info)
  local sock = socket.connect(info.host, info.port, { connect_timeout = info.connect_timeout, timeout = info.timeout })
  local c = setmetatable({ sock = sock, db = info.database }, Conn)
  local ok, err = pcall(function()
    if info.tls ~= "disable" then
      require("dbdash.net.tls").from_info(sock, info)
    end
    local hello = c:command(doc({ { "hello", 1 }, { "$db", "admin" } }), "connect")
    c.max_wire = hello.maxWireVersion
    if info.user and info.user ~= "" then
      c:auth(info)
    end
  end)
  if not ok then
    sock:close()
    error(err, 0)
  end
  return c
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
  elseif type(coll) ~= "string" then
    dberr.raise("query", 'the query needs "collection": "<name>"')
  end
  local db = opt(q, "database") or self.db
  local filter = opt(q, "filter") or map.new()
  local levels = tonumber(opt(q, "flatten")) or 0
  self.db = db

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
    fields[#fields + 1] = { "$db", db }
    local docs, truncated = self:cursor(doc(fields), coll, max)
    return M.to_resultset(docs, levels, max, truncated)
  elseif op == "aggregate" then
    local pipeline = opt(q, "pipeline") or {}
    local docs, truncated = self:cursor(doc({
      { "aggregate", coll },
      { "pipeline", pipeline },
      { "cursor", doc({ { "batchSize", math.min(max + 1, 10000) } }) },
      { "$db", db },
    }), coll, max)
    return M.to_resultset(docs, levels, max, truncated)
  elseif op == "count" then
    local r = self:command(doc({ { "count", coll }, { "query", filter }, { "$db", db } }))
    return resultset.new({ { name = "count", type = "integer", db_type = "int" } }, { { r.n } })
  elseif op == "distinct" then
    local field = opt(q, "field")
    if type(field) ~= "string" then
      dberr.raise("query", 'distinct needs "field": "<name>"')
    end
    local r = self:command(doc({ { "distinct", coll }, { "key", field }, { "query", filter }, { "$db", db } }))
    local docs = {}
    for i, v in ipairs(r.values or {}) do
      docs[i] = map.from_pairs({ { field, v } })
    end
    return M.to_resultset(docs, 0, max, false)
  end
  dberr.raise("query", ("unknown operation %q (use find, aggregate, count or distinct)"):format(op))
end

function Conn:close()
  self.sock:close()
end

return M
