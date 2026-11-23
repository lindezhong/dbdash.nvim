-- http(s):// "database": query.sql is a JSON object describing the request (after the
-- template); the response body is the query's result, a raw value that query.transform
-- reshapes or that is checked as rows directly (db/lua_result.lua). :help dbdash-http.
--
--   { "method": "POST", "path": "search", "query": {...}, "headers": {...},
--     "cookies": "a=1; b=2" | "cookies.txt" | {...}, "body": {...} | "text", "form": {...},
--     "redirects": 5 }
local dberr = require("dbdash.db.error")
local http = require("dbdash.net.http")
local cookie = require("dbdash.net.http_cookie")

local M = {
  name = "http",
  schemes = { "http", "https" },
  capabilities = { tls = true, sql = false, query_language = "http-json" },
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

local FIELDS = {
  method = "string",
  path = "string",
  query = "table",
  headers = "table",
  cookies = true,
  body = true,
  form = "table",
  redirects = "number",
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
    local k = require("dbdash.db.url").decode(pair:match("^([^=]*)"))
    if not OWN_PARAMS[k] then
      keep[#keep + 1] = pair
    end
  end
  info.base_path = path ~= "" and path or "/"
  info.base_query = #keep > 0 and table.concat(keep, "&") or nil
  return info
end

local Conn = {}
Conn.__index = Conn

function M.connect(info)
  return setmetatable({ info = info }, Conn)
end

---The request URL: `path` appended to the base path (or absolute with a leading "/" or a
---scheme), then the base, path and `query` parameters.
local function request_url(info, spec)
  local base = {
    scheme = info.scheme,
    host = info.host,
    port = info.port or (info.scheme == "https" and 443 or 80),
    path = info.base_path,
    query = info.base_query,
  }
  local u = base
  local path = spec.path
  if path and path ~= "" then
    if path:match("^%a[%w+.-]*://") then
      u = http.parse_url(path)
    else
      local p, q = path:match("^([^?]*)%??(.*)$")
      u = vim.deepcopy(base)
      if p:sub(1, 1) == "/" then
        u.path = p
      elseif p ~= "" then
        u.path = base.path:gsub("/$", "") .. "/" .. p
      end
      if q ~= "" then
        u.query = u.query and (u.query .. "&" .. q) or q
      end
    end
  end
  if spec.query and next(spec.query) then
    local extra = http.encode_pairs(spec.query)
    u.query = u.query and (u.query .. "&" .. extra) or extra
  end
  return u
end

---Decode the request description (JSON text; empty means a GET of the URL).
local function parse_spec(text, opts)
  if vim.trim(text) == "" then
    return {}
  end
  local ok, spec = pcall(vim.json.decode, text, { luanil = { object = true } })
  if not ok then
    dberr.raise("query", ("the request is not valid JSON (%s)"):format(tostring(spec):gsub("^.-:%d+: ", "")))
  end
  if type(spec) ~= "table" or vim.islist(spec) and next(spec) ~= nil then
    dberr.raise("query", "the request must be a JSON object")
  end
  for k, v in pairs(spec) do
    local want = FIELDS[k]
    if not want then
      local names = vim.tbl_keys(FIELDS)
      table.sort(names)
      dberr.raise("query", ("unknown request field %q (known: %s)"):format(k, table.concat(names, ", ")))
    end
    if want ~= true and type(v) ~= want then
      dberr.raise("query", ("request field %q must be a %s"):format(k, want == "table" and "object" or want))
    end
  end
  if spec.body ~= nil and spec.form ~= nil then
    dberr.raise("query", "request: give body or form, not both")
  end
  return spec
end

---Decode a response body: JSON (by Content-Type, or when it looks like JSON and no type is
---given) becomes Lua data, null becoming NULL; anything else stays a string.
function M.decode_body(res)
  local ctype = (res.headers["content-type"] or ""):lower()
  local json = ctype:find("json", 1, true) ~= nil or (ctype == "" and res.body:match("^%s*[%[{]") ~= nil)
  if not json then
    return res.body
  end
  local ok, v = pcall(vim.json.decode, res.body, { luanil = { object = true } })
  if not ok then
    dberr.raise("query", ("the response is not valid JSON (%s)"):format(tostring(v):gsub("^.-:%d+: ", "")))
  end
  return v
end

---@param text string the rendered request description
---@param opts { timeout: integer, cookie_jar: dbdash.http.Jar? }
function Conn:execute(text, opts)
  local info = self.info
  local spec = parse_spec(text, opts)
  local url = request_url(info, spec)
  local headers = {}
  for k, v in pairs(spec.headers or {}) do
    headers[k] = tostring(v)
  end
  local function has(name)
    for k in pairs(headers) do
      if k:lower() == name then
        return true
      end
    end
  end
  local body
  if spec.form then
    body = http.encode_pairs(spec.form)
    if not has("content-type") then
      headers["Content-Type"] = "application/x-www-form-urlencoded"
    end
  elseif type(spec.body) == "table" then
    body = vim.json.encode(spec.body)
    if not has("content-type") then
      headers["Content-Type"] = "application/json"
    end
  elseif spec.body ~= nil then
    body = tostring(spec.body)
  end
  local cookies, cerr = cookie.configured(spec.cookies, info.host, info.base_dir)
  if not cookies then
    dberr.raise("query", cerr)
  end
  local auth
  if info.user and info.user ~= "" and not has("authorization") then
    auth = "Basic " .. vim.base64.encode(info.user .. ":" .. (info.password or ""))
  end
  local res = http.request({
    method = (spec.method or (body and "POST" or "GET")):upper(),
    url = url,
    headers = headers,
    body = body,
    auth = auth,
    cookies = cookies,
  }, {
    jar = opts.cookie_jar,
    tls = {
      mode = info.scheme == "https" and info.tls or nil,
      host = info.params.tls_host,
      fingerprint = info.fingerprint,
      ca = info.params.ca,
      base_dir = info.base_dir,
    },
    timeout = opts.timeout,
    connect_timeout = info.connect_timeout,
    redirects = spec.redirects,
  })
  if res.status < 200 or res.status > 299 then
    local excerpt = vim.trim(res.body:sub(1, 300):gsub("%s+", " "))
    dberr.raise(
      (res.status == 401 or res.status == 403) and "auth" or "query",
      ("HTTP %d %s from %s%s"):format(res.status, res.reason, res.url, excerpt ~= "" and (": " .. excerpt) or "")
    )
  end
  local response = { status = res.status, reason = res.reason, headers = res.headers, body = res.body, url = res.url }
  return require("dbdash.db.lua_result").raw(M.decode_body(res), { response = response })
end

function Conn:close() end

function Conn:server_version()
  return nil
end

return M
