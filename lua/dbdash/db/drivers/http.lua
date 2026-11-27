-- http(s):// "database": query.sql is a curl command describing the request (after the
-- template; net/curl.lua); the response body is the query's result, a raw value that
-- query.transform reshapes or that is checked as rows directly (db/lua_result.lua).
-- :help dbdash-http.
--
--   curl -X POST /search -H 'X-Token: t' -b .cookies.txt -c .cookies.txt --json '{...}' -L
local dberr = require("dbdash.util.error")
local http = require("dbdash.net.http")
local cookie = require("dbdash.net.http_cookie")

local M = {
  name = "http",
  schemes = { "http", "https" },
  capabilities = { tls = true, sql = false, query_language = "curl" },
  dialect = "http",
}

-- URL parameters dbdash reads itself; the others are sent to the server.
local OWN_PARAMS = {
  tls = true,
  fingerprint = true,
  ca = true,
  tls_host = true,
  connect_timeout = true,
  timeout = true,
  application_name = true,
}

function M.parse_url(info)
  if info.scheme == "https" and not info.params.tls then
    info.tls = "verify-full"
  elseif info.scheme == "http" and info.tls ~= "disable" then
    dberr.raise("config", "http:// URLs cannot use tls (use https://)")
  end
  -- Keep the path and the server's query parameters as written (url.parse decodes them).
  local rest = info.raw:match("^%a[%w+.-]*://[^/?#]*(.*)$") or ""
  local path, query = rest:match("^([^?#]*)%??([^#]*)")
  local keep = {}
  for pair in query:gmatch("[^&]+") do
    local k = require("dbdash.util.url").decode(pair:match("^([^=]*)"))
    if not OWN_PARAMS[k] then
      keep[#keep + 1] = pair
    end
  end
  info.port = info.port or (info.scheme == "https" and 443 or 80) -- as passwords.json keys expect
  info.base_path = path -- joined with the request's path as it is
  info.base_query = #keep > 0 and table.concat(keep, "&") or nil
  return info
end

local Conn = {}
Conn.__index = Conn

function M.connect(info)
  return setmetatable({ info = info }, Conn)
end

---The request URL: the command's path joined to the URL's path as written (plain
---concatenation: "/v1" .. "/search" is "/v1/search", "/v1" .. "search" is "/v1search"),
---then the URL's parameters, the path's and those -G moved there.
local function request_url(info, req)
  local u = {
    scheme = info.scheme,
    host = info.host,
    port = info.port or (info.scheme == "https" and 443 or 80),
    path = info.base_path,
    query = info.base_query,
  }
  local target = req.url
  if target and target ~= "" then
    local p, q = target:match("^([^?#]*)%??([^#]*)$")
    u.path = u.path .. p
    if q ~= "" then
      u.query = u.query and (u.query .. "&" .. q) or q
    end
  end
  if u.path == "" then
    u.path = "/" -- no path at all: the root
  end
  if req.query and req.query ~= "" then
    u.query = u.query and (u.query .. "&" .. req.query) or req.query
  end
  return u
end

---The request: a curl command (net/curl.lua). The JSON descriptions of before are refused
---with the new form.
local function parse_request(text, info)
  local t = vim.trim(text)
  if t:sub(1, 1) == "{" then
    dberr.raise(
      "query",
      "the request is a curl command, not JSON: e.g. curl -X POST /search -H 'Accept: application/json' --json '{\"q\": 1}' (:help dbdash-http)"
    )
  end
  local ok, req = pcall(require("dbdash.net.curl").parse, t, info.base_dir)
  if not ok then
    local e = req ---@type any (the error)
    dberr.raise("query", type(e) == "table" and e.message or tostring(e))
  end
  return req
end

---curl -c FILE: where the cookie file is written. Only inside the config's directory (a
---config cannot write anywhere else), and only for configs trusted with it.
local function cookie_jar_path(name, info, opts)
  if not opts.allow_writes then
    dberr.raise(
      "query",
      "curl -c writes a file: write it in query.sql itself (not only through the template), so the config is trusted for it"
    )
  end
  if name:match("^/") or name:match("^%a:[/\\]") or name:match("^\\\\") or name:match("^~") then
    dberr.raise(
      "query",
      ("curl -c %s: the cookie file must be a relative path in the config's directory"):format(name)
    )
  end
  for part in name:gmatch("[^/\\]+") do
    if part == ".." then
      dberr.raise(
        "query",
        ("curl -c %s: the cookie file must stay in the config's directory (no ..)"):format(name)
      )
    end
  end
  if not info.base_dir then
    dberr.raise("query", "curl -c needs a config file (its directory holds the cookie file)")
  end
  return vim.fs.joinpath(info.base_dir, name)
end

---Decode a response body: JSON (by Content-Type, or when it looks like JSON and no type is
---given) becomes Lua data, null becoming NULL; anything else stays a string.
function M.decode_body(res)
  local ctype = (res.headers["content-type"] or ""):lower()
  local json = ctype:find("json", 1, true) ~= nil
    or (ctype == "" and res.body:match("^%s*[%[{]") ~= nil)
  if not json then
    return res.body
  end
  local ok, v = pcall(vim.json.decode, res.body, { luanil = { object = true } })
  if not ok then
    dberr.raise(
      "query",
      ("the response is not valid JSON (%s)"):format(tostring(v):gsub("^.-:%d+: ", ""))
    )
  end
  return v
end

---The request's headers by name; a body without a Content-Type is a form (as curl -d).
---@return table<string, string> headers, fun(name: string): boolean? has
local function request_headers(req)
  local headers = {}
  for _, h in ipairs(req.headers) do
    headers[h[1]] = h[2]
  end
  local function has(name)
    for k in pairs(headers) do
      if k:lower() == name then
        return true
      end
    end
  end
  if req.body and not has("content-type") then
    headers["Content-Type"] = "application/x-www-form-urlencoded" -- as curl -d sends
  end
  return headers, has
end

---curl's cookie engine: on with -b or -c; the jar lives for this request and its
---redirects, filled from the -b files and written to the -c file afterwards. Returns the
---jar, the cookies given as strings and the file to write.
local function cookie_engine(req, info, opts)
  if not req.cookie_engine then
    return nil
  end
  local jar = cookie.new()
  for _, file in ipairs(req.cookie_files) do
    jar:load(cookie.read_file(file, info.base_dir, req.junk_session))
  end
  local configured = {}
  for _, s in ipairs(req.cookie_strings) do
    vim.list_extend(configured, cookie.from_string(s, info.host))
  end
  local jar_file = req.cookie_jar and cookie_jar_path(req.cookie_jar, info, opts) or nil
  return jar, configured, jar_file
end

---Basic authentication (-u, else the URL's user) unless an Authorization header is given.
local function basic_auth(req, info, has)
  local user, password = info.user, info.password
  if req.user then
    user, password = req.user:match("^([^:]*):?(.*)$")
  end
  if user and user ~= "" and not has("authorization") then
    return "Basic " .. vim.base64.encode(user .. ":" .. (password or ""))
  end
end

---A response that is not 2xx: an error (401 and 403 in the auth phase) with the start of
---its body.
local function check_status(res)
  if res.status >= 200 and res.status <= 299 then
    return
  end
  local excerpt = vim.trim(res.body:sub(1, 300):gsub("%s+", " "))
  dberr.raise(
    (res.status == 401 or res.status == 403) and "auth" or "query",
    ("HTTP %d %s from %s%s"):format(
      res.status,
      res.reason,
      res.url,
      excerpt ~= "" and (": " .. excerpt) or ""
    )
  )
end

---@param text string the rendered curl command
---@param opts { timeout: integer, allow_writes: boolean? }
function Conn:execute(text, opts)
  local info = self.info
  local req = parse_request(text, info)
  local url = request_url(info, req)
  local headers, has = request_headers(req)
  local jar, configured, jar_file = cookie_engine(req, info, opts)
  local tls_mode = info.scheme == "https" and info.tls or nil
  if tls_mode and req.insecure then
    tls_mode = "require" -- curl -k: encrypted, the certificate not verified
  end
  local ok, res = pcall(http.request, {
    method = req.method,
    url = url,
    headers = headers,
    body = req.body,
    auth = basic_auth(req, info, has),
    cookies = configured,
  }, {
    jar = jar,
    tls = {
      mode = tls_mode,
      host = info.params.tls_host,
      fingerprint = info.fingerprint,
      ca = info.params.ca,
      base_dir = info.base_dir,
    },
    timeout = req.timeout or opts.timeout,
    connect_timeout = req.connect_timeout or info.connect_timeout,
    -- as curl: redirects are followed with -L only (at most --max-redirs, default 50)
    redirects = req.follow and (req.max_redirs or 50) or 0,
  })
  if jar and jar_file then
    -- written whether the request succeeded or not, as curl does
    local wok, werr = jar:write(jar_file)
    if not wok then
      dberr.raise("query", werr or "cannot write the cookie file")
    end
  end
  if not ok then
    -- Name the URL that failed (the URL and the request's path joined).
    local e = res ---@type any (the error)
    if type(e) == "table" and e.message then
      e.message = ("%s (%s)"):format(e.message, http.format_url(url))
    end
    error(e, 0)
  end
  check_status(res)
  local response = {
    status = res.status,
    reason = res.reason,
    headers = res.headers,
    body = res.body,
    url = res.url,
  }
  return require("dbdash.db.lua_result").raw(M.decode_body(res), { response = response })
end

function Conn:close() end

function Conn:server_version()
  return nil
end

-- database.options: none (dbdash.db.options)
M.options = {}

return M
