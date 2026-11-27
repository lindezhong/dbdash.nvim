local socket = require("dbdash.net.socket")
local async = require("dbdash.util.async")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

---Start a local TCP server; `on_conn(client)` handles each connection.
local function server(on_conn)
  local srv = assert(vim.uv.new_tcp())
  srv:bind("127.0.0.1", 0)
  srv:listen(8, function()
    local c = assert(vim.uv.new_tcp())
    srv:accept(c)
    on_conn(c)
  end)
  return srv, assert(srv:getsockname()).port
end

local function run(fn)
  local res
  async.run(fn, function(err, ...)
    res = { err = err, ... }
  end)
  vim.wait(3000, function()
    return res ~= nil
  end, 5)
  assert(res, "task did not finish")
  return res
end

T["echo: write, read_exact across chunks, read_until"] = function()
  local srv, port = server(function(c)
    c:read_start(function(_, data)
      if data then
        -- echo back in two separate writes to force chunked reads
        c:write(data:sub(1, 3))
        vim.defer_fn(function()
          c:write(data:sub(4))
        end, 10)
      else
        c:close()
      end
    end)
  end)
  local r = run(function()
    local s = socket.connect("127.0.0.1", port, { timeout = 1000 })
    s:write("hello\r\nworld")
    local a = s:read_until("\r\n")
    local b = s:read_exact(5)
    s:close()
    return a, b
  end)
  srv:close()
  eq(r, { err = nil, "hello\r\n", "world" })
end

T["connection refused is a connect error"] = function()
  local srv, port = server(function() end)
  srv:close()
  local r = run(function()
    socket.connect("127.0.0.1", port, { connect_timeout = 1000 })
  end)
  eq(r.err.phase, "connect")
  eq(r.err.message:find("cannot connect to 127.0.0.1") ~= nil, true)
end

T["read timeout"] = function()
  local srv, port = server(function() end)
  local r = run(function()
    local s = socket.connect("127.0.0.1", port, { timeout = 100 })
    s:read_exact(1)
  end)
  srv:close()
  eq(r.err.phase, "timeout")
end

T["server closing mid-read"] = function()
  local srv, port = server(function(c)
    c:write("ab", function()
      c:close()
    end)
  end)
  local r = run(function()
    local s = socket.connect("127.0.0.1", port, { timeout = 1000 })
    s:read_exact(4)
  end)
  srv:close()
  eq({ r.err.phase, r.err.message }, { "connect", "connection closed by the server" })
end

T["unresolvable host"] = function()
  local r = run(function()
    socket.connect("no-such-host.invalid", 1, { connect_timeout = 3000 })
  end)
  eq(r.err.message:find("cannot resolve") ~= nil, true)
end

return T
