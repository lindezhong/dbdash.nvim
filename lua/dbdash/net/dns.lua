-- Minimal DNS client for SRV and TXT lookups (mongodb+srv). Runs inside util.async tasks.
--
-- Queries go over UDP to the name servers from /etc/resolv.conf (or an explicit server),
-- retrying over TCP when the answer is truncated. On Windows, DnsQuery_UTF8 (dnsapi, a system
-- DLL) is used instead unless a server is given.
local async = require("dbdash.util.async")
local bit = require("bit")
local dberr = require("dbdash.util.error")

local M = {}

M.TYPE = { A = 1, CNAME = 5, TXT = 16, SRV = 33 }

---@return any (it raises: `x or fail(...)` keeps x's type)
local function fail(msg, ...)
  dberr.raise("connect", "DNS: " .. msg:format(...))
end

local function u16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

local function rd16(s, p)
  return s:byte(p) * 256 + s:byte(p + 1)
end

---Encode a DNS name as labels.
local function encode_name(name)
  local out = {}
  for label in name:gsub("%.$", ""):gmatch("[^.]+") do
    if #label > 63 then
      fail("label too long in %q", name)
    end
    out[#out + 1] = string.char(#label) .. label
  end
  return table.concat(out) .. "\0"
end

---Build a query message.
function M.build_query(id, name, qtype)
  return u16(id)
    .. u16(0x0100)
    .. u16(1)
    .. u16(0)
    .. u16(0)
    .. u16(0)
    .. encode_name(name)
    .. u16(qtype)
    .. u16(1)
end

---Read a (possibly compressed) name at p. Returns name and the position after it.
local function read_name(msg, p)
  local labels, jumped, after = {}, false, nil
  local guard = 0
  while true do
    guard = guard + 1
    if guard > 128 then
      fail("name compression loop")
    end
    local len = msg:byte(p)
    if not len then
      fail("truncated name")
    end
    if len == 0 then
      p = p + 1
      break
    elseif bit.band(len, 0xC0) == 0xC0 then
      local ptr = bit.band(len, 0x3F) * 256 + msg:byte(p + 1)
      if not jumped then
        after = p + 2
      end
      jumped = true
      p = ptr + 1
    else
      labels[#labels + 1] = msg:sub(p + 1, p + len)
      p = p + 1 + len
    end
  end
  return table.concat(labels, "."), jumped and after or p
end
M.read_name = read_name

---@class dbdash.dns.Answer
---@field type integer
---@field name string
---@field ttl integer
---@field srv { priority: integer, weight: integer, port: integer, target: string }?
---@field txt string[]?

---Parse a response message. Returns the header flags and answers.
---@return { id: integer, tc: boolean, rcode: integer, answers: dbdash.dns.Answer[] }
function M.parse_response(msg)
  if #msg < 12 then
    fail("short response")
  end
  local flags = rd16(msg, 3)
  local res = {
    id = rd16(msg, 1),
    tc = bit.band(flags, 0x0200) ~= 0,
    rcode = bit.band(flags, 0x000F),
    answers = {},
  }
  local qd, an = rd16(msg, 5), rd16(msg, 7)
  local p = 13
  for _ = 1, qd do
    local _
    _, p = read_name(msg, p)
    p = p + 4
  end
  for _ = 1, an do
    local name
    name, p = read_name(msg, p)
    local typ, ttl = rd16(msg, p), rd16(msg, p + 4) * 65536 + rd16(msg, p + 6)
    local rdlen = rd16(msg, p + 8)
    local rd = p + 10
    local a = { type = typ, name = name, ttl = ttl }
    if typ == M.TYPE.SRV then
      local target = read_name(msg, rd + 6)
      a.srv = {
        priority = rd16(msg, rd),
        weight = rd16(msg, rd + 2),
        port = rd16(msg, rd + 4),
        target = target,
      }
    elseif typ == M.TYPE.TXT then
      a.txt = {}
      local q = rd
      while q < rd + rdlen do
        local n = msg:byte(q)
        a.txt[#a.txt + 1] = msg:sub(q + 1, q + n)
        q = q + 1 + n
      end
    end
    res.answers[#res.answers + 1] = a
    p = rd + rdlen
  end
  return res
end

---Name servers from /etc/resolv.conf.
function M.nameservers()
  local out = {}
  local f = io.open("/etc/resolv.conf", "r")
  if f then
    for line in f:lines() do
      local ns = line:match("^%s*nameserver%s+(%S+)")
      if ns then
        out[#out + 1] = { host = ns:gsub("%%.*$", ""), port = 53 }
      end
    end
    f:close()
  end
  return out
end

---"host:port", "[v6]:port" or "host" -> { host, port }.
function M.parse_server(s)
  local h, p = s:match("^%[(.+)%]:(%d+)$")
  if not h then
    h, p = s:match("^([^:]+):(%d+)$")
  end
  return { host = h or s, port = tonumber(p) or 53 }
end

local function udp_query(server, packet, timeout)
  return async.await(function(cb)
    local udp = assert(vim.uv.new_udp())
    local done = false
    local timer = assert(vim.uv.new_timer())
    local function finish(err, data)
      if done then
        return
      end
      done = true
      timer:stop()
      timer:close()
      -- (pcall: cleanup: the socket may be closed already)
      pcall(udp.recv_stop, udp)
      udp:close()
      cb(err, data)
    end
    timer:start(timeout, 0, function()
      finish("timeout")
    end)
    udp:recv_start(function(err, data)
      if err then
        finish(err)
      elseif data then
        finish(nil, data)
      end
    end)
    udp:send(packet, server.host, server.port, function(err)
      if err then
        finish(err)
      end
    end)
  end)
end

local function tcp_query(server, packet, timeout)
  local sock = require("dbdash.net.socket").connect(
    server.host,
    server.port,
    { connect_timeout = timeout, timeout = timeout }
  )
  local ok, res = pcall(function()
    sock:write(u16(#packet) .. packet)
    local len = rd16(sock:read_exact(2), 1)
    return sock:read_exact(len)
  end)
  sock:close()
  if not ok then
    error(res, 0)
  end
  return res
end

---Windows: DnsQuery_UTF8 through dnsapi (UTF-8 names in and out).
local function windows_query(name, qtype)
  local ffi = require("ffi")
  -- (pcall: the types may be declared already (ffi.cdef cannot declare twice))
  pcall(
    ffi.cdef,
    [[
    typedef struct DBDASH_DNS_RECORDA {
      struct DBDASH_DNS_RECORDA *pNext; char *pName; uint16_t wType; uint16_t wDataLength;
      uint32_t Flags; uint32_t dwTtl; uint32_t dwReserved;
      union {
        struct { char *pNameTarget; uint16_t wPriority; uint16_t wWeight; uint16_t wPort; uint16_t Pad; } SRV;
        struct { uint32_t dwStringCount; char *pStringArray[1]; } TXT;
      } Data;
    } DBDASH_DNS_RECORDA;
    long DnsQuery_UTF8(const char *name, uint16_t type, uint32_t options, void *extra,
                       DBDASH_DNS_RECORDA **results, void *reserved);
    void DnsRecordListFree(DBDASH_DNS_RECORDA *list, int freetype);
  ]]
  )
  local dnsapi = ffi.load("dnsapi")
  local res = ffi.new("DBDASH_DNS_RECORDA*[1]")
  local rc = tonumber(dnsapi.DnsQuery_UTF8(name, qtype, 0, nil, res, nil))
  if rc == 9003 then -- DNS_ERROR_RCODE_NAME_ERROR
    fail("%s does not exist (NXDOMAIN)", name)
  elseif rc == 9501 then -- DNS_INFO_NO_RECORDS
    return {}
  elseif rc ~= 0 then
    fail("lookup of %s failed (error %d)", name, rc)
  end
  local answers = {}
  local r = res[0]
  while r ~= nil do
    if r.wType == qtype then
      local a = { type = qtype, name = ffi.string(r.pName), ttl = r.dwTtl }
      if qtype == M.TYPE.SRV then
        local d = r.Data.SRV
        a.srv = {
          priority = d.wPriority,
          weight = d.wWeight,
          port = d.wPort,
          target = ffi.string(d.pNameTarget),
        }
      else
        a.txt = {}
        for k = 0, r.Data.TXT.dwStringCount - 1 do
          a.txt[#a.txt + 1] = ffi.string(r.Data.TXT.pStringArray[k])
        end
      end
      answers[#answers + 1] = a
    end
    r = r.pNext
  end
  dnsapi.DnsRecordListFree(res[0], 1)
  return answers
end

---Look up records of a type. Returns the matching answers (empty when the name exists
---without such records).
---@param name string
---@param qtype integer M.TYPE.*
---@param opts { server: string?, timeout: integer? }?
---@return dbdash.dns.Answer[]
function M.query(name, qtype, opts)
  opts = opts or {}
  if jit.os == "Windows" and not opts.server then
    return windows_query(name, qtype)
  end
  local servers = opts.server and { M.parse_server(opts.server) } or M.nameservers()
  if #servers == 0 then
    fail("no name servers configured (pass ?dns=host:port)")
  end
  local timeout = opts.timeout or 5000
  local last
  for _, server in ipairs(servers) do
    for _ = 1, 2 do
      local id = math.random(0, 65535)
      local packet = M.build_query(id, name, qtype)
      local err, data = udp_query(server, packet, timeout)
      if not err then
        local ok, res = pcall(M.parse_response, data)
        if ok and res.id == id then
          if res.tc then
            res = M.parse_response(tcp_query(server, packet, timeout))
          end
          if res.rcode == 3 then
            fail("%s does not exist (NXDOMAIN)", name)
          elseif res.rcode ~= 0 then
            last = ("server %s answered rcode %d"):format(server.host, res.rcode)
            break
          end
          local out = {}
          for _, a in ipairs(res.answers) do
            if a.type == qtype then
              out[#out + 1] = a
            end
          end
          return out
        end
        local e = res ---@type any (the response, or the error)
        last = ok and "mismatched response id" or (type(e) == "table" and e.message or tostring(e))
      else
        last = tostring(err)
      end
    end
  end
  return fail("lookup of %s failed: %s", name, tostring(last))
end

---SRV records sorted by priority, then weight (higher first).
function M.srv(name, opts)
  local out = {}
  for _, a in ipairs(M.query(name, M.TYPE.SRV, opts)) do
    out[#out + 1] = a.srv
  end
  table.sort(out, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    return a.weight > b.weight
  end)
  return out
end

---TXT strings (each record's parts joined).
function M.txt(name, opts)
  local out = {}
  for _, a in ipairs(M.query(name, M.TYPE.TXT, opts)) do
    out[#out + 1] = table.concat(a.txt)
  end
  return out
end

return M
