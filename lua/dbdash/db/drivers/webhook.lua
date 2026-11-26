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
local dberr = require("dbdash.db.error")
local map = require("dbdash.util.map")
local options = require("dbdash.db.push.options")

local M = {
  name = "webhook",
  schemes = { "webhook" },
  capabilities = { tls = false, sql = false, query_language = "openapi", push = true },
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

function M.connect()
  dberr.raise("config", "webhook:// is a push source: it runs as a stream (:help dbdash-push)")
end

function M.parse_url(info)
  info.host = (info.host and info.host ~= "") and info.host or "127.0.0.1"
  if not info.port then
    dberr.raise("config", "webhook:// needs a port: webhook://127.0.0.1:8765/path")
  end
  -- The URL's path, as written: the document's paths are appended to it.
  info.base_path = info.raw:match("^%a[%w+.-]*://[^/?#]*([^?#]*)") or ""
  return info
end

local function problem(status, detail)
  return {
    status = status,
    headers = { ["Content-Type"] = "application/problem+json" },
    body = vim.json.encode({
      type = "about:blank",
      title = require("dbdash.net.http_server").REASONS[status] or "Error",
      status = status,
      detail = detail,
    }),
  }
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

---@param ctx dbdash.db.StreamCtx
function M.produce(info, text, ctx)
  local openapi = require("dbdash.net.openapi")
  local server = require("dbdash.net.http_server")
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
    tokens[k] = v
  end
  local ok, api = pcall(openapi.load, vim.trim(text) ~= "" and text or default_doc(info.base_path), {
    base_dir = ctx.base_dir,
    base_path = info.base_path,
    tokens = tokens,
  })
  if not ok then
    error(api, 0)
  end
  local host = info.host
  local is_local = LOCAL[host] == true
  if not is_local then
    -- MCP: an endpoint others can reach must authenticate every request.
    for _, r in ipairs(api.routes) do
      for _, op in pairs(r.ops) do
        if #op.security == 0 then
          dberr.raise("config", ("webhook:// on %s (not this machine) needs a security requirement on every operation; %s has none"):format(host, op.id))
        end
      end
    end
  end
  local bind = host == "localhost" and "127.0.0.1" or host
  local max_body = require("dbdash.util.bytes").parse(o.max_body)
  local hosts = { [host:lower()] = true, localhost = is_local or nil, ["127.0.0.1"] = is_local or nil, ["::1"] = is_local or nil }
  for _, h in ipairs(o.allowed_hosts) do
    hosts[h:lower()] = true
  end
  local origins = {}
  for _, h in ipairs(o.allowed_origins) do
    origins[h] = true
  end
  -- Headers that carry credentials are not passed on.
  local hidden = { authorization = true, ["proxy-authorization"] = true, cookie = true }
  for _, s in pairs(api.schemes) do
    if s.type == "apiKey" and s["in"] == "header" then
      hidden[tostring(s.name):lower()] = true
    end
  end
  local function reject(status, detail, headers)
    ctx.stats.rejected[status] = (ctx.stats.rejected[status] or 0) + 1
    local res = problem(status, detail)
    for k, v in pairs(headers or {}) do
      res.headers[k] = v
    end
    return res
  end

  local function handle(req, read_body)
    -- DNS rebinding: the Host must be this server, the Origin (from browsers) allowed.
    local h = (req.headers.host or ""):lower():gsub(":%d+$", ""):gsub("^%[(.*)%]$", "%1")
    if not hosts[h] then
      return reject(403, "this Host is not allowed")
    end
    local origin = req.headers.origin
    if origin and not origins[origin] then
      return reject(403, "this Origin is not allowed")
    end
    local op, path_values, allow = api:match(req.method, req.path)
    if not op then
      if path_values == 405 then
        return reject(405, "method not allowed", { Allow = table.concat(allow, ", ") })
      end
      return reject(404, "no such path")
    end
    local authorized, challenge = api:authorize(op, req.headers)
    if not authorized then
      return reject(401, "authentication required", challenge and { ["WWW-Authenticate"] = challenge } or nil)
    end
    local pok, params = pcall(api.parameters, api, op, req, path_values)
    if not pok then
      if type(params) == "table" and params.http_status then
        return reject(params.http_status, params.detail)
      end
      error(params, 0)
    end
    local headers = {}
    for k, v in pairs(req.headers) do
      if not hidden[k] then
        headers[k] = v
      end
    end
    local content_type = req.headers["content-type"]
    local vars = {
      params = params,
      request = { method = req.method, path = req.path, operation_id = op.id, content_type = content_type, headers = headers },
    }
    local has_body = (tonumber(req.headers["content-length"] or "0") or 0) > 0 or (req.headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) ~= nil
    local count = 0
    local function emit(v)
      count = count + 1
      ctx.emit(v, vars)
    end
    local function params_item()
      local m = map.new()
      for _, where in ipairs({ "path", "query", "header", "cookie" }) do
        for k, v in map.pairs(params[where]) do
          map.set(m, k, v)
        end
      end
      emit(m)
    end
    local bok, berr = pcall(function()
      if not op.body then
        if has_body then
          read_body(function() end, max_body) -- (ignored: the operation takes no body)
        end
        params_item()
        return
      end
      if not has_body then
        if op.body.required == true then
          server.error(400, "a request body is required")
        end
        params_item()
        return
      end
      local mt, media, mdoc, ct = api:media(op, content_type)
      if not mt then
        server.error(415, ("unsupported media type %s"):format(tostring(content_type)))
      end
      local kind = openapi.kind(ct ~= "" and ct or tostring(mt), o.stream_types)
      if kind:match("^stream") then
        local delimiter = ct == "application/json-seq" and "\30" or o.delimiter
        local n = 0
        local write, flush = require("dbdash.db").splitter(delimiter, max_body, function(piece)
          n = n + 1
          local value = piece
          if kind == "stream-json" then
            local v, err = openapi.decode_json(vim.trim(piece))
            if v == nil and err then
              server.error(400, ("item %d: invalid JSON (%s)"):format(n, err))
            end
            value = v
          end
          if media.schema ~= nil then
            local e = api:validate(media.schema, value, mdoc)
            if e then
              server.error(400, ("item %d%s: %s"):format(n, e.path ~= "/" and (" " .. e.path) or "", e.message))
            end
          end
          emit(value)
        end, ctx.stats)
        read_body(write, max_body)
        flush()
        return
      end
      local parts = {}
      read_body(function(data)
        parts[#parts + 1] = data
      end, max_body)
      local body = table.concat(parts)
      local value
      if kind == "json" then
        local v, err = openapi.decode_json(body)
        if v == nil and err then
          server.error(400, ("invalid JSON (%s)"):format(err))
        end
        value = v
      elseif kind == "form" then
        value = api:form(body, media, mdoc)
      elseif kind == "multipart" then
        value = api:multipart(body, content_type, media, mdoc)
      else
        value = body
      end
      if media.schema ~= nil then
        local e = api:validate(media.schema, value, mdoc)
        if e then
          server.error(400, ("request body%s: %s"):format(e.path ~= "/" and (" " .. e.path) or "", e.message))
        end
      end
      emit(value)
    end)
    if not bok then
      if type(berr) == "table" and berr.http_status then
        local detail = berr.detail
        if count > 0 then
          detail = ("%s (%d item(s) before it were accepted)"):format(detail, count)
        end
        return reject(berr.http_status, detail)
      end
      error(berr, 0)
    end
    if op.example then
      local body = type(op.example.value) == "string" and op.example.value or vim.json.encode(op.example.value)
      return { status = op.status or 202, headers = { ["Content-Type"] = op.example.type }, body = body }
    end
    return { status = op.status or 202, headers = { ["Content-Type"] = "application/json" }, body = vim.json.encode({ queued = count }) }
  end

  local lok, srv = pcall(server.listen, bind, info.port, {
    max_connections = o.max_connections,
    timeout = require("dbdash.util.duration").parse(o.timeout),
    on_error = function(status, detail)
      return reject(status, detail or "")
    end,
  }, handle)
  if not lok then
    dberr.raise("connect", tostring(srv))
  end
  ctx.on_stop(function()
    srv:close()
  end)
  ctx.set_status(("listening %s:%d"):format(host:find(":", 1, true) and ("[" .. host .. "]") or host, srv.port))
  -- Serve until stopped.
  require("dbdash.util.async").await(function(cb)
    ctx.cancel:on_cancel(function()
      cb()
    end)
  end)
end

return M
