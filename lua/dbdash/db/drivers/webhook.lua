-- webhook:// push source: an HTTP endpoint described by an OpenAPI document (query.sql,
-- YAML or JSON; :help dbdash-webhook). Each accepted request gives items:
--   - a streaming media type (application/x-ndjson, application/jsonl, application/json-seq,
--     text/plain, text/csv, text/event-stream, database.options.stream_types): the body cut
--     at the delimiter, one item per piece (JSON ones decoded), each validated;
--   - other JSON media types: the decoded body, one item;
--   - forms (urlencoded, multipart): the fields as one mapping;
--   - no request body: the parameters as one mapping.
-- Every item comes with `params` (by location) and `request` for query.transform.
--
-- Security follows MCP's rules for HTTP endpoints (:help dbdash-webhook-security):
-- localhost by default, credentials only in headers or cookies, Origin and Host checked,
-- limits on body size, connections and slow requests.
local dberr = require("dbdash.util.error")
local options = require("dbdash.db.options")

local M = {
  name = "webhook",
  schemes = { "webhook" },
  capabilities = { tls = false, sql = false, query_language = "openapi" },
  query_optional = true, -- without an OpenAPI document: anything sent to the URL's path
}

local function strings(v)
  if type(v) ~= "table" then
    return "must be a list of strings"
  end
  for _, x in ipairs(v) do
    if type(x) ~= "string" then
      return "must be a list of strings"
    end
  end
end

local SPEC = {
  tokens = "map",
  delimiter = options.delimiter,
  stream_types = strings,
  max_body = require("dbdash.util.bytes").check,
  max_connections = "integer",
  timeout = function(v)
    if require("dbdash.util.duration").parse(v) == nil then
      return 'must be a duration such as "10s"'
    end
  end,
  allowed_origins = strings,
  allowed_hosts = strings,
}

local LOCAL = { ["127.0.0.1"] = true, ["::1"] = true, localhost = true }

function M.parse_url(info)
  info.host = (info.host and info.host ~= "") and info.host or "127.0.0.1"
  if not info.port then
    dberr.raise("config", "webhook:// needs a port: webhook://127.0.0.1:8765/path")
  end
  -- The URL's path, as written: the document's paths are appended to it.
  info.base_path = info.raw:match("^%a[%w+.-]*://[^/?#]*([^?#]*)") or ""
  return info
end

---The document used when query.sql is empty: POST or PUT of anything at the URL's path.
local function default_doc(base_path)
  local key = base_path == "" and "/" or ""
  return ([[
openapi: 3.1.0
info: { title: webhook, version: "1" }
paths:
  "%s":
    post: { requestBody: { content: { "*/*": {} } }, responses: { "202": { description: queued } } }
    put: { requestBody: { content: { "*/*": {} } }, responses: { "202": { description: queued } } }
]]):format(key)
end

---The options with their defaults, and the tokens with ${NAME} from the environment.
local function read_options(info)
  local o = options.check("webhook", info.options, SPEC, {
    delimiter = "\n",
    max_body = "10MB",
    max_connections = 16,
    timeout = "10s",
    allowed_origins = {},
    allowed_hosts = {},
    stream_types = {},
  })
  local tokens = {}
  for k, v in pairs(o.tokens or {}) do
    local what = "database.options.tokens." .. k
    if type(v) == "table" then
      tokens[k] = vim.tbl_map(function(x)
        return options.expand_env(x, what)
      end, v)
    else
      tokens[k] = options.expand_env(v, what) -- ${NAME}: from the environment
    end
  end
  return o, tokens
end

---The Hosts and Origins requests may come with (DNS rebinding, http_server.check_host).
local function allowed(host, is_local, o)
  local hosts = {
    [host:lower()] = true,
    localhost = is_local or nil,
    ["127.0.0.1"] = is_local or nil,
    ["::1"] = is_local or nil,
  }
  for _, h in ipairs(o.allowed_hosts) do
    hosts[h:lower()] = true
  end
  local origins = {}
  for _, h in ipairs(o.allowed_origins) do
    origins[h] = true
  end
  return hosts, origins
end

---Serve the document's operations until the run stops: each accepted request gives items
---(net/openapi.lua's Api:handle), every rejection is counted by status.
---@param ctx dbdash.db.StreamCtx
function M.produce(info, text, ctx)
  local openapi = require("dbdash.net.openapi")
  local server = require("dbdash.net.http_server")
  local o, tokens = read_options(info)
  local api = openapi.load(vim.trim(text) ~= "" and text or default_doc(info.base_path), {
    base_dir = ctx.base_dir,
    base_path = info.base_path,
    tokens = tokens,
  })
  local host = info.host
  local is_local = LOCAL[host] == true
  if not is_local then
    api:require_security(("webhook:// on %s (not this machine)"):format(host))
  end
  local hosts, origins = allowed(host, is_local, o)
  local max_body = require("dbdash.util.bytes").parse(o.max_body)
  local function reject(status, detail, headers)
    ctx.stats.rejected[status] = (ctx.stats.rejected[status] or 0) + 1
    return server.problem(status, detail, headers)
  end
  local handle_opts = {
    emit = ctx.emit,
    split = function(delimiter, on_piece)
      return require("dbdash.db").splitter(delimiter, max_body, on_piece, ctx.stats)
    end,
    max_body = max_body,
    delimiter = o.delimiter,
    stream_types = o.stream_types,
    hidden = api:credential_headers(),
  }
  local lok, srv = pcall(server.listen, host == "localhost" and "127.0.0.1" or host, info.port, {
    max_connections = o.max_connections,
    timeout = require("dbdash.util.duration").parse(o.timeout),
    on_error = function(status, detail)
      return reject(status, detail or "")
    end,
  }, function(req, read_body)
    local status, detail = server.check_host(req, hosts, origins)
    if status then
      return reject(status, detail)
    end
    local res, rejected = api:handle(req, read_body, handle_opts)
    if rejected then
      return reject(rejected.http_status, rejected.detail, rejected.headers)
    end
    return res
  end)
  if not lok then
    dberr.raise("connect", tostring(srv))
  end
  ctx.on_stop(function()
    srv:close()
  end)
  ctx.set_status(
    ("listening %s:%d"):format(host:find(":", 1, true) and ("[" .. host .. "]") or host, srv.port)
  )
  -- Serve until stopped.
  require("dbdash.util.async").await(function(cb)
    ctx.cancel:on_cancel(function()
      cb()
    end)
  end)
end

-- database.options this driver reads (dbdash.db.options)
M.options = SPEC

return M
