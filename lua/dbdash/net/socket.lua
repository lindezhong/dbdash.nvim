-- TCP sockets for drivers, in coroutine style (design §9.1). Every call must run inside a
-- dbdash.util.async task; operations suspend the task instead of blocking.
--
-- A transport filter (TLS, M4) can be installed with set_filter(): outgoing bytes pass
-- through filter:wrap() and incoming bytes through filter:unwrap().
local async = require("dbdash.util.async")
local dberr = require("dbdash.util.error")

local M = {}

---@class dbdash.net.Socket
---@field tcp uv.uv_tcp_t
---@field host string
---@field port integer
---@field timeout integer default per-operation timeout (ms)
local Socket = {}
Socket.__index = Socket

---Run `start(cb)` and wait for cb(err, ...) or the timeout. Returns err, ...
local function with_timeout(ms, start)
  return async.await(function(cb)
    local done = false
    local timer = vim.uv.new_timer()
    timer:start(ms, 0, function()
      if done then
        return
      end
      done = true
      timer:close()
      cb("timeout")
    end)
    start(function(...)
      if done then
        return
      end
      done = true
      timer:stop()
      timer:close()
      cb(...)
    end)
  end)
end

---Connect to host:port, trying every resolved address (IPv4 and IPv6).
---@param host string
---@param port integer
---@param opts { connect_timeout: integer?, timeout: integer? }?
---@return dbdash.net.Socket
function M.connect(host, port, opts)
  opts = opts or {}
  local ctimeout = opts.connect_timeout or 10000
  local err, addrs = with_timeout(ctimeout, function(cb)
    vim.uv.getaddrinfo(host, tostring(port), { socktype = "stream" }, cb)
  end)
  if err then
    dberr.raise(
      err == "timeout" and "timeout" or "connect",
      ("cannot resolve %s: %s"):format(host, err)
    )
  end
  local last
  for _, a in ipairs(addrs or {}) do
    local tcp = vim.uv.new_tcp()
    local cerr = with_timeout(ctimeout, function(cb)
      tcp:connect(a.addr, a.port, cb)
    end)
    if not cerr then
      tcp:nodelay(true)
      local s = setmetatable({
        tcp = tcp,
        host = host,
        port = port,
        timeout = opts.timeout or 30000,
        buf = "", -- plaintext; unread from bpos (see consume)
        bpos = 1,
        raw = "", -- bytes from the network; unread from rpos, then the chunks of rawq
        rpos = 1,
        rawq = {}, -- chunks received since, kept apart until read (no copying on arrival)
        rawq_bytes = 0,
        eof = false,
        closed = false,
      }, Socket)
      return s
    end
    last = cerr
    if not tcp:is_closing() then
      tcp:close()
    end
  end
  dberr.raise(
    last == "timeout" and "timeout" or "connect",
    ("cannot connect to %s:%d: %s"):format(
      host,
      port,
      last == "timeout" and "timed out" or tostring(last or "no address")
    )
  )
end

---A Socket over an accepted connection (the HTTP server's side).
---@param tcp uv.uv_tcp_t
---@param timeout integer ms for each read or write
---@return dbdash.net.Socket
function M.wrap(tcp, host, port, timeout)
  tcp:nodelay(true)
  return setmetatable({
    tcp = tcp,
    host = host,
    port = port,
    timeout = timeout,
    buf = "",
    bpos = 1,
    raw = "",
    rpos = 1,
    rawq = {},
    rawq_bytes = 0,
    eof = false,
    closed = false,
  }, Socket)
end

---Plaintext bytes received and not read yet.
function Socket:buffered()
  return #self.buf - self.bpos + 1
end

---Read whatever arrives next (at least one byte), up to `max` bytes; "" at EOF.
function Socket:read_some(max)
  async.checkpoint()
  if self:buffered() <= 0 then
    local ok, err = pcall(self.fill, self)
    if not ok then
      if self.eof then
        return ""
      end
      error(err, 0)
    end
  end
  local n = math.min(max, self:buffered())
  return self:read_exact(n)
end

---Install a transport filter (TLS). `pending` is plaintext already buffered before.
function Socket:set_filter(filter)
  self.filter = filter
end

function Socket:raw_write(data)
  if self.closed then
    dberr.raise("connect", "write on a closed connection")
  end
  local err = with_timeout(self.timeout, function(cb)
    self.tcp:write(data, cb)
  end)
  if err then
    dberr.raise(err == "timeout" and "timeout" or "connect", "write failed: " .. tostring(err))
  end
end

---Send bytes (through the filter if any).
function Socket:write(data)
  if self.filter then
    data = self.filter:wrap(data)
  end
  self:raw_write(data)
end

function Socket:start_reading()
  if self.reading then
    return
  end
  self.reading = true
  self.tcp:read_start(function(err, chunk)
    if err then
      self.err = err
    elseif chunk then
      self:append_raw(chunk)
    else
      self.eof = true
    end
    local w = self.waiter
    self.waiter = nil
    if w then
      w()
    end
  end)
end

---Wait until more raw bytes, EOF or an error arrive.
function Socket:wait_raw()
  self:start_reading()
  local err = with_timeout(self.timeout, function(cb)
    self.waiter = cb
  end)
  if err == "timeout" then
    self.waiter = nil
    dberr.raise(
      "timeout",
      ("no response from %s:%d within %.1fs"):format(self.host, self.port, self.timeout / 1000)
    )
  end
end

-- Buffers are read through a position instead of cutting the string on every read, which
-- copied the rest of a large buffer for each small message (quadratic on big results).
local COMPACT = 65536

-- Called from the libuv read callback: only queue the chunk. Concatenating it to the
-- unread bytes here copied megabytes per chunk on large results, outside any task.
function Socket:append_raw(chunk)
  self.rawq[#self.rawq + 1] = chunk
  self.rawq_bytes = self.rawq_bytes + #chunk
end

---Unread raw bytes.
function Socket:raw_available()
  return #self.raw - self.rpos + 1 + self.rawq_bytes
end

---Move the queued chunks behind the unread raw bytes (one concatenation).
function Socket:merge_raw()
  if #self.rawq > 0 then
    self.raw = self.raw:sub(self.rpos) .. table.concat(self.rawq)
    self.rpos, self.rawq, self.rawq_bytes = 1, {}, 0
  end
end

---Put bytes back in front of the unread raw bytes (plaintext read before TLS started).
function Socket:unshift_raw(data)
  self:merge_raw()
  self.raw, self.rpos = data .. self.raw:sub(self.rpos), 1
end

---Raw bytes received but not yet consumed (used by the TLS filter).
function Socket:take_raw()
  self:merge_raw()
  local r = self.raw:sub(self.rpos)
  self.raw, self.rpos = "", 1
  return r
end

---Read at least `n` raw (unfiltered) bytes.
function Socket:raw_read_exact(n)
  async.checkpoint()
  while self:raw_available() < n do
    if self.err then
      dberr.raise("connect", "read failed: " .. tostring(self.err))
    elseif self.eof then
      dberr.raise("connect", "connection closed by the server")
    end
    self:wait_raw()
  end
  if #self.raw - self.rpos + 1 < n then
    self:merge_raw()
  end
  local s = self.raw:sub(self.rpos, self.rpos + n - 1)
  self.rpos = self.rpos + n
  if self.rpos > COMPACT and self.rpos * 2 > #self.raw then -- amortized: linear in total
    self.raw, self.rpos = self.raw:sub(self.rpos), 1
  end
  return s
end

---Append plaintext to the read buffer.
function Socket:append_buf(data)
  if self.bpos > 1 then
    self.buf, self.bpos = self.buf:sub(self.bpos), 1
  end
  self.buf = self.buf .. data
end

---Unread plaintext, removed from the buffer (handed to TLS by starttls).
function Socket:take_buffered()
  local s = self.buf:sub(self.bpos)
  self.buf, self.bpos = "", 1
  return s
end

---Make plaintext bytes available in self.buf (through the filter if any).
function Socket:fill()
  if self.filter then
    local got = self.filter:unwrap(self)
    if got and #got > 0 then
      self:append_buf(got)
      return
    end
    return
  end
  if self:raw_available() <= 0 then
    if self.err then
      dberr.raise("connect", "read failed: " .. tostring(self.err))
    elseif self.eof then
      dberr.raise("connect", "connection closed by the server")
    end
    self:wait_raw()
  end
  self:append_buf(self:take_raw())
end

---Read exactly `n` bytes.
---@param n integer
---@return string
function Socket:read_exact(n)
  async.checkpoint()
  while #self.buf - self.bpos + 1 < n do
    self:fill()
  end
  local s = self.buf:sub(self.bpos, self.bpos + n - 1)
  self.bpos = self.bpos + n
  if self.bpos > COMPACT and self.bpos * 2 > #self.buf then
    self.buf, self.bpos = self.buf:sub(self.bpos), 1
  end
  return s
end

---Read up to and including `delim`.
---@param delim string
---@return string
function Socket:read_until(delim)
  async.checkpoint()
  while true do
    local i = self.buf:find(delim, self.bpos, true)
    if i then
      local s = self.buf:sub(self.bpos, i + #delim - 1)
      self.bpos = i + #delim
      if self.bpos > COMPACT and self.bpos * 2 > #self.buf then
        self.buf, self.bpos = self.buf:sub(self.bpos), 1
      end
      return s
    end
    self:fill()
  end
end

---Read everything until the peer closes the connection (or sends TLS close_notify).
---@param limit integer? raise when more bytes than this arrive
---@return string
function Socket:read_to_eof(limit)
  while true do
    async.checkpoint()
    if limit and #self.buf - self.bpos + 1 > limit then
      dberr.raise("query", ("response larger than %d bytes"):format(limit))
    end
    local ok, err = pcall(self.fill, self)
    if not ok then
      if self.eof or (type(err) == "table" and err.tls_closed) then
        break
      end
      error(err, 0)
    end
  end
  return self:take_buffered()
end

function Socket:close()
  if self.closed then
    return
  end
  self.closed = true
  if self.filter and self.filter.close then
    pcall(self.filter.close, self.filter, self)
  end
  if self.reading then
    pcall(self.tcp.read_stop, self.tcp)
  end
  if not self.tcp:is_closing() then
    self.tcp:close()
  end
  local w = self.waiter
  self.waiter = nil
  if w then
    w("closed")
  end
end

M.Socket = Socket

return M
