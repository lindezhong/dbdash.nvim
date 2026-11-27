-- Connection URL parsing (:help dbdash-databases):
--   <scheme>://[user[:password]@]host[:port][/database][?param=value&...]
--   sqlite:///absolute/path.db   sqlite:///:memory:   sqlite://relative/path.db
local dberr = require("dbdash.util.error")
local duration = require("dbdash.util.duration")

local pct = require("dbdash.util.url")

local M = {}

---@class dbdash.db.Url
---@field raw string
---@field scheme string lower-case scheme as written (e.g. "postgresql")
---@field user string?
---@field password string?
---@field host string?
---@field port integer?
---@field hosts { host: string?, port: integer? }[] all hosts of a seed list
---@field database string? path for sqlite, database name otherwise
---@field params table<string, string> all query parameters, decoded
---@field tls "disable"|"require"|"pin"|"verify-ca"|"verify-full"
---@field fingerprint string? 32 raw bytes of the SHA-256 certificate pin
---@field connect_timeout integer ms
---@field timeout integer ms
---@field application_name string

---@return any (it raises: `x or fail(...)` keeps x's type)
local function fail(msg, ...)
  dberr.raise("config", msg:format(...))
end

---Parse "sha256:AB:CD:..." (or plain hex) into 32 raw bytes.
function M.parse_fingerprint(s)
  local hex = s:gsub("^[sS][hH][aA]256:", ""):gsub("[:%s]", "")
  if #hex ~= 64 or not hex:match("^%x+$") then
    fail("fingerprint must be a SHA-256 digest like sha256:AB:CD:... (32 bytes)")
  end
  return (hex:gsub("%x%x", function(h)
    return string.char(tonumber(h, 16))
  end))
end

---Parse a connection URL. Raises a DbError with phase "config" when invalid.
---@param raw string
---@return dbdash.db.Url
function M.parse(raw)
  local scheme, rest = raw:match("^([%a][%w+.-]*)://(.*)$")
  if not scheme then
    fail("invalid database url %q (expected scheme://...)", raw)
  end
  local u = { raw = raw, scheme = scheme:lower(), params = {} }

  local query
  rest, query = rest:match("^([^?]*)%??(.*)$")
  for pair in query:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    u.params[pct.decode(k)] = pct.decode(v)
  end

  if u.scheme == "sqlite" then
    -- Everything after "sqlite://" is a path: "/abs.db", "/:memory:" or "rel/path.db".
    local path = pct.decode(rest)
    if path == "/:memory:" or path == ":memory:" or path == "" then
      path = ":memory:"
    end
    u.database = path
  else
    local authority, path = rest:match("^([^/]*)(.*)$")
    local userinfo, hostport = authority:match("^(.*)@([^@]*)$")
    hostport = hostport or authority
    if userinfo then
      local user, pass = userinfo:match("^([^:]*):(.*)$")
      u.user = pct.decode(user or userinfo)
      u.password = pass and pct.decode(pass) or nil
    end
    -- Seed lists ("h1:27017,h2:27018") give several hosts; u.host/u.port are the first.
    u.hosts = {}
    for part in (hostport .. ","):gmatch("([^,]*),") do
      local host, port
      if part:sub(1, 1) == "[" then
        host, port = part:match("^%[([^%]]+)%]:?(%d*)$")
        if not host then
          fail("invalid IPv6 host in %q", raw)
        end
      else
        host, port = part:match("^([^:]*):?(%d*)$")
        if not host then
          fail("invalid host:port %q", part)
        end
      end
      local entry = { host = host ~= "" and pct.decode(host) or nil }
      if port ~= "" then
        entry.port = tonumber(port)
        -- (0 only for webhook://: listen on any free port)
        if entry.port < (u.scheme == "webhook" and 0 or 1) or entry.port > 65535 then
          fail("port out of range: %s", port)
        end
      end
      u.hosts[#u.hosts + 1] = entry
    end
    u.host, u.port = u.hosts[1].host, u.hosts[1].port
    local db = path:gsub("^/", "")
    u.database = db ~= "" and pct.decode(db) or nil
  end

  -- Common parameters.
  local p = u.params
  u.tls = (p.tls or "disable"):lower()
  local MODES =
    { disable = true, require = true, pin = true, ["verify-ca"] = true, ["verify-full"] = true }
  if not MODES[u.tls] then
    fail("tls must be disable, require, pin, verify-ca or verify-full (got %q)", p.tls)
  end
  if u.tls == "pin" then
    if not p.fingerprint then
      fail("tls=pin requires fingerprint=sha256:...")
    end
    u.fingerprint = M.parse_fingerprint(p.fingerprint)
  end
  local err
  local defaults = require("dbdash.db.defaults").current
  u.connect_timeout, err = duration.parse(p.connect_timeout or defaults.connect_timeout)
  if err then
    fail("connect_timeout: %s", err)
  end
  u.timeout, err = duration.parse(p.timeout or defaults.timeout)
  if err then
    fail("timeout: %s", err)
  end
  u.application_name = p.application_name or "dbdash.nvim"
  return u
end

---URL with the password masked, for messages and :DbDashStatus.
---@param raw string
---@return string
function M.redact(raw)
  return (raw:gsub("^([%a][%w+.-]*://[^:/@]*:)[^@]*@", "%1***@"))
end

return M
