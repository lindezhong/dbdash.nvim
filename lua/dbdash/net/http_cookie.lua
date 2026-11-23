-- Cookies for http(s):// queries.
--
-- A jar keeps the cookies servers set (Set-Cookie) in memory, for one dashboard: later
-- requests (refreshes, redirects) send them back. Configured cookies are given in curl's
-- -b forms and are only read, never written back:
--   "a=1; b=2"      a Cookie header value
--   "cookies.txt"   (no "=") a Netscape cookie file, as written by curl -c or browser add-ons
--   { a = "1" }     a table
-- When the jar holds a cookie with the same name, the server's value wins.
local M = {}

local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }

---Seconds since the epoch for a UTC date (days-from-civil, independent of the local zone).
local function utc_time(y, mo, d, h, mi, s)
  y = mo <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + h * 3600 + mi * 60 + s
end

---Parse an HTTP date ("Wed, 21 Oct 2015 07:28:00 GMT" and the usual variants).
---@return integer? epoch seconds
function M.parse_date(s)
  local d, mon, y, h, mi, sec = s:match("(%d%d?)[ %-](%a%a%a)%a*[ %-](%d%d%d?%d?) (%d%d?):(%d%d):(%d%d)")
  if not d then
    return nil
  end
  local mo = MONTHS[mon:lower()]
  if not mo then
    return nil
  end
  y = tonumber(y)
  if y < 100 then
    y = y + (y < 70 and 2000 or 1900)
  end
  return utc_time(y, mo, tonumber(d), tonumber(h), tonumber(mi), tonumber(sec))
end

---True when `host` is `domain` or a subdomain of it.
local function domain_match(host, domain)
  host, domain = host:lower(), domain:lower()
  return host == domain or (#host > #domain and host:sub(-#domain - 1) == "." .. domain)
end

---True when the request path is within the cookie path.
local function path_match(path, cpath)
  if path == cpath then
    return true
  end
  if path:sub(1, #cpath) == cpath then
    return cpath:sub(-1) == "/" or path:sub(#cpath + 1, #cpath + 1) == "/"
  end
  return false
end

---The default cookie path: the request path up to its last "/".
local function default_path(path)
  local dir = path:match("^(/.*)/[^/]*$")
  return (dir and dir ~= "") and dir or "/"
end

---@class dbdash.http.Cookie
---@field name string
---@field value string
---@field domain string
---@field host_only boolean
---@field path string
---@field secure boolean
---@field expires number? epoch seconds; nil: until the jar is dropped

---@class dbdash.http.Jar
---@field cookies table<string, dbdash.http.Cookie>
local Jar = {}
Jar.__index = Jar

function M.new()
  return setmetatable({ cookies = {}, seq = 0 }, Jar)
end

local function key(c)
  return c.domain .. "\0" .. c.path .. "\0" .. c.name
end

---Parse one Set-Cookie header value into a cookie for a request to host/path.
---@return dbdash.http.Cookie? cookie, boolean? delete
function M.parse_set_cookie(header, host, path, now)
  local parts = vim.split(header, ";", { plain = true })
  local name, value = parts[1]:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
  if not name or name == "" then
    return nil
  end
  local c = { name = name, value = value, domain = host:lower(), host_only = true, path = default_path(path), secure = false }
  local max_age
  for i = 2, #parts do
    local k, v = parts[i]:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
    k = (k or vim.trim(parts[i])):lower()
    if k == "domain" and v and v ~= "" then
      local d = v:gsub("^%.", ""):lower()
      if not domain_match(host, d) then
        return nil -- a server cannot set cookies for another domain
      end
      c.domain, c.host_only = d, false
    elseif k == "path" and v and v:sub(1, 1) == "/" then
      c.path = v
    elseif k == "secure" then
      c.secure = true
    elseif k == "max-age" and v then
      max_age = tonumber(v)
    elseif k == "expires" and v and not c.expires then
      c.expires = M.parse_date(v)
    end
  end
  if max_age then
    c.expires = now + max_age -- Max-Age wins over Expires
  end
  return c, c.expires ~= nil and c.expires <= now
end

---Store the Set-Cookie headers of a response to `url` (a parsed http.Url).
---@param headers string[]
function Jar:store(headers, url, now)
  now = now or os.time()
  for _, h in ipairs(headers) do
    local c, delete = M.parse_set_cookie(h, url.host, url.path, now)
    if c then
      local k = key(c)
      if delete then
        self.cookies[k] = nil
      else
        local old = self.cookies[k]
        if old then
          c.seq = old.seq -- replacing keeps the creation order
        else
          self.seq = self.seq + 1
          c.seq = self.seq
        end
        self.cookies[k] = c
      end
    end
  end
end

---Cookies of a list that apply to `url`: longest path first, then in creation order.
local function matching(list, url, now)
  local out = {}
  for i, c in ipairs(list) do
    c.seq = c.seq or i
    local host_ok = c.host_only and c.domain == url.host:lower() or (not c.host_only and domain_match(url.host, c.domain))
    if
      host_ok
      and path_match(url.path, c.path)
      and (not c.secure or url.scheme == "https")
      and (not c.expires or c.expires > now)
    then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b)
    if #a.path ~= #b.path then
      return #a.path > #b.path
    end
    return a.seq < b.seq
  end)
  return out
end

---Netscape cookie file lines -> cookies (the "#HttpOnly_" prefix is kept as a cookie).
---@return dbdash.http.Cookie[]
function M.parse_netscape(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local http_only = line:match("^#HttpOnly_(.*)$")
    if http_only then
      line = http_only
    end
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local f = vim.split(line, "\t", { plain = true })
      if #f >= 7 then
        local domain = f[1]:gsub("^%.", ""):lower()
        local expires = tonumber(f[5])
        out[#out + 1] = {
          name = f[6],
          value = f[7],
          domain = domain,
          host_only = f[2]:upper() ~= "TRUE",
          path = f[3] ~= "" and f[3] or "/",
          secure = f[4]:upper() == "TRUE",
          expires = (expires and expires > 0) and expires or nil,
        }
      end
    end
  end
  return out
end

---Configured cookies (curl -b forms) as cookies for the request's host.
---@param spec string|table|nil
---@param host string the host of the base URL (string and table cookies go only there)
---@param base_dir string? where relative cookie file paths start
---@return dbdash.http.Cookie[]? cookies, string? error
function M.configured(spec, host, base_dir)
  if spec == nil or spec == vim.NIL then
    return {}
  end
  local out = {}
  local function add(name, value)
    out[#out + 1] = { name = name, value = value, domain = host:lower(), host_only = true, path = "/", secure = false }
  end
  if type(spec) == "table" then
    local names = vim.tbl_keys(spec)
    table.sort(names)
    for _, n in ipairs(names) do
      add(tostring(n), tostring(spec[n]))
    end
    return out
  elseif type(spec) ~= "string" then
    return nil, "cookies must be a string or an object"
  end
  if spec:find("=", 1, true) then
    for pair in spec:gmatch("[^;]+") do
      local n, v = pair:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
      if n and n ~= "" then
        add(n, v)
      end
    end
    return out
  end
  local path = vim.fn.expand(spec)
  if base_dir and not (path:match("^/") or path:match("^%a:[/\\]") or path:match("^\\\\")) then
    path = vim.fs.joinpath(base_dir, path)
  end
  local f = io.open(path, "rb")
  if not f then
    return nil, ("cannot read the cookie file %s"):format(path)
  end
  local text = f:read("*a")
  f:close()
  return M.parse_netscape(text)
end

---The Cookie header for a request to `url`: configured cookies, overridden by name with the
---cookies the server set (the jar). nil when there are none.
---@param configured dbdash.http.Cookie[]
function Jar:header(url, configured, now)
  now = now or os.time()
  local stored = {}
  for _, c in pairs(self.cookies) do
    stored[#stored + 1] = c
  end
  local pairs_out, seen = {}, {}
  for _, list in ipairs({ matching(stored, url, now), matching(configured or {}, url, now) }) do
    for _, c in ipairs(list) do
      if not seen[c.name] then
        seen[c.name] = true
        pairs_out[#pairs_out + 1] = c.name .. "=" .. c.value
      end
    end
  end
  return #pairs_out > 0 and table.concat(pairs_out, "; ") or nil
end

return M
