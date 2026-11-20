-- TCP sockets for drivers, in coroutine style (design §9.1). Every call must run inside a
-- dbdash.util.async task; operations suspend the task instead of blocking.
--
-- A transport filter (TLS, M4) can be installed with set_filter(): outgoing bytes pass
-- through filter:wrap() and incoming bytes through filter:unwrap().
local async = require("dbdash.util.async")
local dberr = require("dbdash.db.error")

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
    dberr.raise(err == "timeout" and "timeout" or "connect", ("cannot resolve %s: %s"):format(host, err))
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
        buf = "",
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
    ("cannot connect to %s:%d: %s"):format(host, port, last == "timeout" and "timed out" or tostring(last or "no address"))
  )
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
      self.raw = (self.raw or "") .. chunk
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
    dberr.raise("timeout", ("no response from %s:%d within %.1fs"):format(self.host, self.port, self.timeout / 1000))
  end
end

---Raw bytes received but not yet consumed (used by the TLS filter).
function Socket:take_raw()
  local r = self.raw or ""
  self.raw = nil
  return r
end

---Read at least `n` raw (unfiltered) bytes.
function Socket:raw_read_exact(n)
  while #(self.raw or "") < n do
    if self.err then
      dberr.raise("connect", "read failed: " .. tostring(self.err))
    elseif self.eof then
      dberr.raise("connect", "connection closed by the server")
    end
    self:wait_raw()
  end
  local s = self.raw:sub(1, n)
  self.raw = self.raw:sub(n + 1)
  return s
end

---Make plaintext bytes available in self.buf (through the filter if any).
function Socket:fill()
  if self.filter then
    local got = self.filter:unwrap(self)
    if got and #got > 0 then
      self.buf = self.buf .. got
      return
    end
    return
  end
  if #(self.raw or "") == 0 then
    if self.err then
      dberr.raise("connect", "read failed: " .. tostring(self.err))
    elseif self.eof then
      dberr.raise("connect", "connection closed by the server")
    end
    self:wait_raw()
  end
  self.buf = self.buf .. self:take_raw()
end

---Read exactly `n` bytes.
---@param n integer
---@return string
function Socket:read_exact(n)
  while #self.buf < n do
    self:fill()
  end
  local s = self.buf:sub(1, n)
  self.buf = self.buf:sub(n + 1)
  return s
end

---Read up to and including `delim`.
---@param delim string
---@return string
function Socket:read_until(delim)
  while true do
    local i = self.buf:find(delim, 1, true)
    if i then
      local s = self.buf:sub(1, i + #delim - 1)
      self.buf = self.buf:sub(i + #delim)
      return s
    end
    self:fill()
  end
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
