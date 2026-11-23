-- A small HTTP/1.1 client for http(s):// queries, on dbdash's sockets and TLS. One request
-- per connection (Connection: close); bodies by Content-Length, chunked or until close;
-- redirects followed with the cookie jar. Must run inside a util.async task.
local dberr = require("dbdash.db.error")
local socket = require("dbdash.net.socket")

local M = {}

M.MAX_BODY = 64 * 1024 * 1024
M.MAX_REDIRECTS = 5
local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

---@class dbdash.http.Url
---@field scheme "http"|"https"
---@field host string
---@field port integer
---@field path string
---@field query string? without "?"

---Parse an absolute http(s) URL.
---@return dbdash.http.Url
function M.parse_url(s)
  local scheme, rest = s:match("^(%a[%w+.-]*)://(.*)$")
  scheme = scheme and scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    dberr.raise("query", ("not an http(s) URL: %s"):format(s))
  end
  local authority, path = rest:match("^([^/?#]*)([^#]*)")
  authority = authority:gsub("^.*@", "")
  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^%[([^%]]+)%]:?(%d*)$")
  else
    host, port = authority:match("^([^:]*):?(%d*)$")
  end
  if not host or host == "" then
    dberr.raise("query", ("no host in URL: %s"):format(s))
  end
  local p, q = path:match("^([^?]*)%??(.*)$")
  return {
    scheme = scheme,
    host = host,
    port = tonumber(port) or (scheme == "https" and 443 or 80),
    path = p ~= "" and p or "/",
    query = q ~= "" and q or nil,
  }
end

---Resolve a Location header against the URL it came from.
function M.resolve(base, ref)
  if ref:match("^%a[%w+.-]*://") then
    return M.parse_url(ref)
  elseif ref:sub(1, 2) == "//" then
    return M.parse_url(base.scheme .. ":" .. ref)
  end
  local u = vim.deepcopy(base)
  local p, q = ref:match("^([^?#]*)%??([^#]*)")
  if p == "" then
    u.query = q ~= "" and q or base.query
    return u
  end
  if p:sub(1, 1) ~= "/" then
    p = base.path:gsub("[^/]*$", "") .. p
  end
  u.path, u.query = p, q ~= "" and q or nil
  return u
end

function M.format_url(u)
  local default = (u.scheme == "https" and 443 or 80)
  local host = u.host:find(":", 1, true) and ("[" .. u.host .. "]") or u.host
  return ("%s://%s%s%s%s"):format(
    u.scheme,
    host,
    u.port ~= default and (":" .. u.port) or "",
    u.path,
    u.query and ("?" .. u.query) or ""
  )
end

---Percent-encode a query component (application/x-www-form-urlencoded style).
function M.encode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

---Encode a table as name=value pairs (sorted by name; list values repeat the name).
function M.encode_pairs(t)
  local names = vim.tbl_keys(t)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local out = {}
  for _, n in ipairs(names) do
    local v = t[n]
    local values = (type(v) == "table" and vim.islist(v)) and v or { v }
    for _, x in ipairs(values) do
      if x ~= vim.NIL then
        out[#out + 1] = M.encode(n) .. "=" .. M.encode(type(x) == "table" and vim.json.encode(x) or tostring(x))
      end
    end
  end
  return table.concat(out, "&")
end

---Read the response head; returns status, reason, headers (lower-case names, repeated
---headers joined with ", "), set_cookie (every Set-Cookie value).
local function read_head(sock)
  while true do
    local line = sock:read_until("\r\n"):sub(1, -3)
    local status, reason = line:match("^HTTP/%d[%.%d]* (%d%d%d) ?(.*)$")
    if not status then
      dberr.raise("query", ("not an HTTP response: %q"):format(line:sub(1, 80)))
    end
    local headers, set_cookie = {}, {}
    while true do
      local h = sock:read_until("\r\n"):sub(1, -3)
      if h == "" then
        break
      end
      local name, value = h:match("^([^:]+):%s*(.-)%s*$")
      if name then
        name = name:lower()
        if name == "set-cookie" then
          set_cookie[#set_cookie + 1] = value
        end
        headers[name] = headers[name] and (headers[name] .. ", " .. value) or value
      end
    end
    status = tonumber(status)
    if status >= 200 or status == 101 then
      return status, reason, headers, set_cookie
    end
    -- 1xx (100 Continue, 103 Early Hints): another head follows.
  end
end

local function read_body(sock, method, status, headers, limit)
  if method == "HEAD" or status == 204 or status == 304 then
    return ""
  end
  local te = (headers["transfer-encoding"] or ""):lower()
  if te:find("chunked", 1, true) then
    local parts, size = {}, 0
    while true do
      local line = sock:read_until("\r\n")
      local n = tonumber(line:match("^%s*(%x+)"), 16)
      if not n then
        dberr.raise("query", ("bad chunk size %q"):format(line:sub(1, 40)))
      end
      if n == 0 then
        repeat -- trailers
          local t = sock:read_until("\r\n")
        until t == "\r\n"
        break
      end
      size = size + n
      if size > limit then
        dberr.raise("query", ("response larger than %d bytes"):format(limit))
      end
      parts[#parts + 1] = sock:read_exact(n + 2):sub(1, n)
    end
    return table.concat(parts)
  end
  local len = headers["content-length"]
  if len then
    local n = tonumber(len:match("^%s*(%d+)"))
    if not n then
      dberr.raise("query", ("bad Content-Length %q"):format(len))
    end
    if n > limit then
      dberr.raise("query", ("response larger than %d bytes"):format(limit))
    end
    return n > 0 and sock:read_exact(n) or ""
  end
  return sock:read_to_eof(limit)
end

---@class dbdash.http.Request
---@field method string
---@field url dbdash.http.Url
---@field headers table<string, string> name -> value (as given; Host etc. are added)
---@field body string?
---@field auth string? Authorization value, sent only to the first origin
---@field cookies dbdash.http.Cookie[]? configured cookies

---@class dbdash.http.Response
---@field status integer
---@field reason string
---@field headers table<string, string>
---@field body string
---@field url string the final URL (after redirects)

---scheme://host:port: credentials, pinned fingerprints and tls_host stay with this origin.
local function origin(u)
  return ("%s://%s:%d"):format(u.scheme, u.host:lower(), u.port)
end

---Send one request on a new connection.
local function send_once(req, url, o)
  local first = origin(url) == o.first_origin
  local sock = socket.connect(url.host, url.port, { connect_timeout = o.connect_timeout, timeout = o.timeout })
  local ok, res = pcall(function()
    if url.scheme == "https" then
      local tls = o.tls or {}
      require("dbdash.net.tls").starttls(sock, {
        host = (first and tls.host) or url.host,
        mode = tls.mode or "verify-full",
        fingerprint = first and tls.fingerprint or nil,
        ca = tls.ca,
        base_dir = tls.base_dir,
        alpn = { "http/1.1" },
      })
    end
    local lines = { ("%s %s%s HTTP/1.1"):format(req.method, url.path, url.query and ("?" .. url.query) or "") }
    local have = {}
    for name, value in pairs(req.headers) do
      have[name:lower()] = true
    end
    local function add(name, value)
      if value and not have[name:lower()] then
        lines[#lines + 1] = name .. ": " .. value
      end
    end
    local default_port = url.scheme == "https" and 443 or 80
    add("Host", url.port == default_port and url.host or (url.host .. ":" .. url.port))
    add("User-Agent", "dbdash.nvim")
    add("Accept", "application/json, */*;q=0.5")
    add("Accept-Encoding", "identity")
    add("Connection", "close")
    if first then
      add("Authorization", req.auth)
    end
    add("Cookie", o.jar and o.jar:header(url, req.cookies) or nil)
    if req.body or req.method == "POST" or req.method == "PUT" or req.method == "PATCH" then
      add("Content-Length", tostring(#(req.body or "")))
    end
    local names = vim.tbl_keys(req.headers)
    table.sort(names)
    for _, name in ipairs(names) do
      if first or name:lower() ~= "authorization" then
        lines[#lines + 1] = name .. ": " .. tostring(req.headers[name])
      end
    end
    sock:write(table.concat(lines, "\r\n") .. "\r\n\r\n" .. (req.body or ""))
    local status, reason, headers, set_cookie = read_head(sock)
    if o.jar then
      o.jar:store(set_cookie, url)
    end
    if (headers["content-encoding"] or "identity"):lower() ~= "identity" then
      dberr.raise("query", ("compressed responses (%s) are not supported"):format(headers["content-encoding"]))
    end
    local body = read_body(sock, req.method, status, headers, o.max_body or M.MAX_BODY)
    return { status = status, reason = reason, headers = headers, body = body, url = M.format_url(url) }
  end)
  sock:close()
  if not ok then
    error(res, 0)
  end
  return res
end

---Send a request, following redirects.
---@param req dbdash.http.Request
---@param o { jar: dbdash.http.Jar?, tls: table?, timeout: integer?, connect_timeout: integer?, redirects: integer?, max_body: integer? }
---@return dbdash.http.Response
function M.request(req, o)
  o = vim.tbl_extend("keep", { first_origin = origin(req.url) }, o or {})
  local url = req.url
  local max = o.redirects or M.MAX_REDIRECTS
  for hop = 0, max do
    local res = send_once(req, url, o)
    local loc = res.headers.location
    if not (REDIRECT[res.status] and loc) or hop == max then
      if REDIRECT[res.status] and loc and max > 0 then
        dberr.raise("query", ("too many redirects (more than %d)"):format(max))
      end
      return res
    end
    url = M.resolve(url, loc)
    if res.status == 303 or ((res.status == 301 or res.status == 302) and req.method == "POST") then
      req = vim.tbl_extend("force", req, { method = req.method == "HEAD" and "HEAD" or "GET", body = false })
      req.body = nil
      local headers = {}
      for k, v in pairs(req.headers) do
        if k:lower() ~= "content-type" then
          headers[k] = v
        end
      end
      req.headers = headers
    end
  end
end

return M
