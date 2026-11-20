-- TLS 1.3 for driver sockets (design §9). After starttls() the socket's read/write go
-- through the record layer transparently.
--
-- Known risk (documented in :h dbdash-tls): the pure Lua primitives are not constant-time,
-- so timing side channels exist in theory; acceptable for periodic dashboard reads.
local handshake = require("dbdash.net.tls.handshake")
local record = require("dbdash.net.tls.record")

local M = {}

local TYPE = record.TYPE

---@class dbdash.tls.Filter
local Filter = {}
Filter.__index = Filter

---Encrypt application data into records.
function Filter:wrap(data)
  local out = {}
  for off = 1, math.max(#data, 1), record.MAX_PLAINTEXT do
    out[#out + 1] = self.session.write:seal(TYPE.application_data, data:sub(off, off + record.MAX_PLAINTEXT - 1))
  end
  return table.concat(out)
end

---Read one record and return its application data ("" for handshake/other records).
function Filter:unwrap(sock)
  local s = self.session
  local typ, hdr, body = record.read(sock)
  if typ == TYPE.change_cipher_spec then
    return ""
  elseif typ ~= TYPE.application_data then
    if typ == TYPE.alert then
      record.alert(body)
    end
    record.fail("unexpected plaintext record type %d", typ)
  end
  local inner, content = s.read:open(hdr, body)
  if inner == TYPE.application_data then
    return content
  elseif inner == TYPE.alert then
    record.alert(content)
  elseif inner == TYPE.handshake then
    self:post_handshake(sock, content)
    return ""
  end
  record.fail("unexpected record type %d", inner)
end

---Post-handshake messages: session tickets are ignored; KeyUpdate rotates keys.
function Filter:post_handshake(sock, content)
  self.hbuf = (self.hbuf or "") .. content
  while #self.hbuf >= 4 do
    local t = self.hbuf:byte(1)
    local len = self.hbuf:byte(2) * 65536 + self.hbuf:byte(3) * 256 + self.hbuf:byte(4)
    if #self.hbuf < 4 + len then
      return
    end
    local body = self.hbuf:sub(5, 4 + len)
    self.hbuf = self.hbuf:sub(5 + len)
    if t == handshake.HS.key_update then
      local s = self.session
      s.s_secret = handshake.update_secret(s.s_secret)
      s.read = handshake.traffic(s.suite, s.s_secret)
      if body:byte(1) == 1 then -- update_requested: answer, then rotate our keys
        sock:raw_write(s.write:seal(TYPE.handshake, "\24\0\0\1\0"))
        s.c_secret = handshake.update_secret(s.c_secret)
        s.write = handshake.traffic(s.suite, s.c_secret)
      end
    end
  end
end

function Filter:close(sock)
  pcall(function()
    sock:raw_write(self.session.write:seal(TYPE.alert, "\1\0")) -- close_notify
  end)
end

---Upgrade a connected socket to TLS 1.3.
---@param sock dbdash.net.Socket
---@param opts { host: string, mode: "require"|"pin", fingerprint: string? }
---@return dbdash.tls.Session
function M.starttls(sock, opts)
  -- Bytes already moved to the plaintext buffer belong to the TLS stream.
  if #sock.buf > 0 then
    sock.raw = sock.buf .. (sock.raw or "")
    sock.buf = ""
  end
  local ok, session = pcall(handshake.run, sock, opts)
  if not ok then
    local e = session
    if type(e) == "table" and e.phase == "connect" and not e.tls_closed then
      e.phase = "tls"
      e.message = "handshake failed: " .. e.message
    end
    error(e, 0)
  end
  local filter = setmetatable({ session = session }, Filter)
  sock:set_filter(filter)
  if session.leftover and #session.leftover > 0 then
    filter:post_handshake(sock, session.leftover)
  end
  sock.tls = session
  return session
end

---Upgrade using a parsed connection URL's tls/fingerprint settings.
---@param sock dbdash.net.Socket
---@param info dbdash.db.ConnInfo
function M.from_info(sock, info)
  return M.starttls(sock, { host = info.host, mode = info.tls, fingerprint = info.fingerprint })
end

return M
