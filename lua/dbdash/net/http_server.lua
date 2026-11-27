-- A small HTTP/1.1 server for webhook:// (one request per connection: responses close
-- it). Requests are read in a util.async task each: the request line and headers (at most
-- 64 KB), then the body (Content-Length or chunked) handed to the handler in pieces.
--
--   local srv = server.listen(host, port, {
--     max_connections = 16, timeout = 10000, -- ms for the headers and for each body read
--   }, function(req, body) ... return { status = 202, headers = {...}, body = "..." } end)
--   srv:close()
--
-- req: { method, target, path (decoded only by the caller), query (raw string), version,
-- headers (lower-case names; repeated ones joined with ", "), peer }. body(on_chunk, limit)
-- reads the body, calling on_chunk(data) for each piece; it raises { status = 413 } past
-- `limit` bytes and { status = 400 } for malformed chunked bodies.
local async = require("dbdash.util.async")
local socket = require("dbdash.net.socket")

local M = {}

local MAX_HEAD = 65536

local REASONS = {
  [200] = "OK",
  [201] = "Created",
  [202] = "Accepted",
  [204] = "No Content",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [408] = "Request Timeout",
  [411] = "Length Required",
  [413] = "Content Too Large",
  [415] = "Unsupported Media Type",
  [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
  [501] = "Not Implemented",
  [503] = "Service Unavailable",
}
M.REASONS = REASONS

local function http_error(status, detail)
  error({ http_status = status, detail = detail }, 0)
end
M.error = http_error

---Read the request line and headers.
local function read_head(sock)
  while true do
    local i = sock.buf:find("\r\n\r\n", sock.bpos, true)
    if i then
      break
    end
    if sock:buffered() > MAX_HEAD then
      http_error(431, "the request headers are too large")
    end
    sock:fill()
  end
  local head = sock:read_until("\r\n\r\n")
  local lines = vim.split(head:sub(1, -5), "\r\n", { plain = true })
  local method, target, version = lines[1]:match("^(%u+) (%S+) HTTP/(%d%.%d)$")
  if not method then
    http_error(400, "malformed request line")
  end
  local headers = {}
  for i = 2, #lines do
    local name, value = lines[i]:match("^([!#$%%&'*+.^_`|~%w-]+):[ \t]*(.-)[ \t]*$")
    if not name then
      http_error(400, "malformed header line")
    end
    name = name:lower()
    headers[name] = headers[name] and (headers[name] .. ", " .. value) or value
  end
  local path, query = target:match("^([^?#]*)%??([^#]*)")
  return {
    method = method,
    target = target,
    path = path,
    query = query,
    version = version,
    headers = headers,
  }
end

---The body reader of a request.
local function body_reader(sock, req)
  return function(on_chunk, limit)
    local te = (req.headers["transfer-encoding"] or ""):lower()
    local total = 0
    local function take(data)
      total = total + #data
      if total > limit then
        http_error(413, ("the request body is larger than %d bytes"):format(limit))
      end
      on_chunk(data)
    end
    if te:find("chunked", 1, true) then
      while true do
        local line = sock:read_until("\r\n")
        local size = tonumber((line:match("^(%x+)")), 16)
        if not size then
          http_error(400, "malformed chunked body")
        end
        if size == 0 then
          -- Trailers until an empty line.
          while sock:read_until("\r\n") ~= "\r\n" do
          end
          return
        end
        if total + size > limit then
          http_error(413, ("the request body is larger than %d bytes"):format(limit))
        end
        local left = size
        while left > 0 do
          local piece = sock:read_some(math.min(left, 65536))
          if piece == "" then
            http_error(400, "the request body ended early")
          end
          left = left - #piece
          take(piece)
        end
        if sock:read_exact(2) ~= "\r\n" then
          http_error(400, "malformed chunked body")
        end
      end
    elseif te ~= "" and te ~= "identity" then
      http_error(501, "unsupported Transfer-Encoding " .. te)
    end
    local cl = req.headers["content-length"]
    if not cl then
      return -- no body
    end
    local n = tonumber(cl:match("^%s*(%d+)%s*$") or "")
    if not n then
      http_error(400, "invalid Content-Length")
    end
    if n > limit then
      http_error(413, ("the request body is larger than %d bytes"):format(limit))
    end
    local left = n
    while left > 0 do
      local piece = sock:read_some(math.min(left, 65536))
      if piece == "" then
        http_error(400, "the request body ended early")
      end
      left = left - #piece
      take(piece)
    end
  end
end

---Response bytes.
local function response(res)
  local status = res.status or 200
  local lines = { ("HTTP/1.1 %d %s"):format(status, REASONS[status] or "Status") }
  local body = res.body or ""
  local headers = res.headers or {}
  for k, v in pairs(headers) do
    lines[#lines + 1] = k .. ": " .. v
  end
  lines[#lines + 1] = "Content-Length: " .. #body
  lines[#lines + 1] = "Connection: close"
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end
M.response = response

---Listen on host:port. `handler(req, body)` runs in a task per request and returns the
---response; errors { http_status, detail } become that status (`opts.on_error(status,
---detail)` makes the response, default plain text), others 500.
---@return { close: fun(self), port: integer, host: string }
function M.listen(host, port, opts, handler)
  opts = opts or {}
  local tcp = vim.uv.new_tcp()
  local ok, err = tcp:bind(host, port)
  if ok then
    ok, err = tcp:listen(128, function(lerr)
      if lerr then
        return
      end
      local client = vim.uv.new_tcp()
      if not tcp:accept(client) then
        client:close()
        return
      end
      M.serve(client, opts, handler)
    end)
  end
  if not ok then
    if not tcp:is_closing() then
      tcp:close()
    end
    error(("cannot listen on %s:%d: %s"):format(host, port, tostring(err)), 0)
  end
  local srv = { host = host, port = tcp:getsockname().port, clients = {} }
  function srv.close()
    if not tcp:is_closing() then
      tcp:close()
    end
    for c in pairs(srv.clients) do
      pcall(c.close, c)
    end
  end
  opts.srv = srv
  return srv
end

---Handle one accepted connection.
function M.serve(client, opts, handler)
  local srv = opts.srv
  local active = 0
  for _ in pairs(srv and srv.clients or {}) do
    active = active + 1
  end
  if active >= (opts.max_connections or 16) then
    client:close() -- too many at once
    return
  end
  local peer = client:getpeername() or {}
  local sock = socket.wrap(client, peer.ip or "?", peer.port or 0, opts.timeout or 10000)
  if srv then
    srv.clients[sock] = true
  end
  async.run(function()
    local status, res
    local ok, out = pcall(function()
      local req = read_head(sock)
      req.peer = peer.ip
      return handler(req, body_reader(sock, req))
    end)
    if ok then
      res = out
    else
      if type(out) == "table" and out.http_status then
        status = out.http_status
      elseif type(out) == "table" and out.phase == "timeout" then
        status = 408
        out = { detail = "the request was not received in time" }
      elseif type(out) == "table" and out.phase == "connect" then
        return -- the client went away
      else
        status = 500
        out = { detail = "internal error" }
      end
      res = opts.on_error and opts.on_error(status, out.detail)
        or {
          status = status,
          headers = { ["Content-Type"] = "text/plain" },
          body = (out.detail or "") .. "\n",
        }
    end
    pcall(sock.write, sock, response(res))
  end, function()
    if srv then
      srv.clients[sock] = nil
    end
    sock:close()
  end)
end

return M
