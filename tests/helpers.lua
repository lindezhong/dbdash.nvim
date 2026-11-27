-- Shared test helpers.
local M = {}

---Serialize render output as text + highlight markers, readable in diffs:
---  each output line is written as "│<text>", followed by "  ^ <s>-<e> <Group>" lines.
---@param out dbdash.render.Output
---@return string
function M.serialize(out)
  local by_row = {}
  for _, h in ipairs(out.hl) do
    by_row[h.row] = by_row[h.row] or {}
    table.insert(by_row[h.row], h)
  end
  local buf = {}
  for i, line in ipairs(out.lines) do
    buf[#buf + 1] = "│" .. line
    local hs = by_row[i - 1] or {}
    table.sort(hs, function(a, b)
      return a.col_s < b.col_s or (a.col_s == b.col_s and a.group < b.group)
    end)
    for _, h in ipairs(hs) do
      buf[#buf + 1] = ("  ^ %d-%d %s"):format(h.col_s, h.col_e, h.group)
    end
  end
  return table.concat(buf, "\n") .. "\n"
end

---Compare output with tests/golden/<name>.txt. UPDATE_GOLDEN=1 rewrites the file.
---On mismatch the actual output is saved next to it as .actual.
function M.golden(name, out)
  local path = "tests/golden/" .. name .. ".txt"
  local actual = M.serialize(out)
  if vim.env.UPDATE_GOLDEN == "1" or vim.fn.filereadable(path) == 0 then
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(vim.split(actual, "\n", { plain = true }), path, "b")
    if vim.env.UPDATE_GOLDEN ~= "1" then
      error("golden file created, review and re-run: " .. path)
    end
    return
  end
  local expected = table.concat(vim.fn.readfile(path, "b"), "\n")
  if expected ~= actual then
    vim.fn.writefile(vim.split(actual, "\n", { plain = true }), path:gsub("%.txt$", ".actual"), "b")
    error(
      ("golden mismatch for %s (see %s, update with UPDATE_GOLDEN=1)"):format(
        path,
        path:gsub("%.txt$", ".actual")
      )
    )
  end
end

---True when integration tests should run (make it).
function M.it()
  return vim.env.DBDASH_IT == "1"
end

---Skip the current case unless integration tests are enabled.
function M.require_it()
  if not M.it() then
    MiniTest.skip("integration test (run with make it)")
  end
end

---Run a query through the DriverManager and wait for the result.
---@return { err: dbdash.Error?, rs: dbdash.db.ResultSet? }
function M.query(url, q, opts)
  local res
  require("dbdash.db").query(url, q, opts or {}, function(err, rs)
    res = { err = err, rs = rs }
  end)
  vim.wait(20000, function()
    return res ~= nil
  end, 5)
  assert(res, "query did not complete: " .. q)
  return res
end

---Like query() but fails the test on error.
function M.ok(url, q, opts)
  local r = M.query(url, q, opts)
  if r.err then
    error(tostring(r.err), 2)
  end
  return r.rs
end

---Fake socket reading from a fixed byte string (protocol unit tests).
function M.fake_socket(bytes)
  local s = { buf = bytes, written = {} }
  function s:read_exact(n)
    assert(#self.buf >= n, "fake socket: out of data")
    local r = self.buf:sub(1, n)
    self.buf = self.buf:sub(n + 1)
    return r
  end
  function s:read_until(d)
    local i = assert(self.buf:find(d, 1, true), "fake socket: delimiter not found")
    local r = self.buf:sub(1, i + #d - 1)
    self.buf = self.buf:sub(i + #d)
    return r
  end
  function s:write(data)
    self.written[#self.written + 1] = data
  end
  return s
end

local function u16(n)
  return string.char(math.floor(n / 256), n % 256)
end
---Build a response for a query with SRV / TXT answers (names compressed to the question).
function M.dns_respond(query, records)
  local id = query:sub(1, 2)
  local qname_end = query:find("\0", 13, true)
  local question = query:sub(13, qname_end + 4)
  local qtype = query:byte(qname_end + 1) * 256 + query:byte(qname_end + 2)
  local answers = {}
  for _, r in ipairs(records) do
    if r.type == qtype then
      local rdata
      if r.type == 33 then
        local target = ""
        for label in r.target:gmatch("[^.]+") do
          target = target .. string.char(#label) .. label
        end
        rdata = u16(r.priority) .. u16(r.weight) .. u16(r.port) .. target .. "\0"
      else
        rdata = ""
        for _, part in ipairs(r.parts) do
          rdata = rdata .. string.char(#part) .. part
        end
      end
      answers[#answers + 1] = "\192\12"
        .. u16(r.type)
        .. u16(1)
        .. "\0\0\0\60"
        .. u16(#rdata)
        .. rdata
    end
  end
  return id
    .. u16(0x8180)
    .. u16(1)
    .. u16(#answers)
    .. u16(0)
    .. u16(0)
    .. question
    .. table.concat(answers)
end

---Fake UDP DNS server answering every query with `records`. Returns server, port.
function M.fake_dns(records)
  local udp = assert(vim.uv.new_udp())
  udp:bind("127.0.0.1", 0)
  udp:recv_start(function(_, data, addr)
    if data and addr then
      udp:send(M.dns_respond(data, records), addr.ip, addr.port, function() end)
    end
  end)
  return udp, assert(udp:getsockname()).port
end

local http_servers = {}

---Start a local HTTP server. `handle(req)` gets { method, target, headers (lower-case),
---body } and returns the raw response bytes (a string) or a list of chunks written with
---a pause between them. Every request is recorded in the returned list.
function M.http_server(handle)
  local seen = {}
  local srv = assert(vim.uv.new_tcp())
  srv:bind("127.0.0.1", 0)
  srv:listen(8, function()
    local c = assert(vim.uv.new_tcp())
    srv:accept(c)
    local buf = ""
    c:read_start(function(err, chunk)
      if err or not chunk then
        if not c:is_closing() then
          c:close()
        end
        return
      end
      buf = buf .. chunk
      local head_end = buf:find("\r\n\r\n", 1, true)
      if not head_end then
        return
      end
      local head = buf:sub(1, head_end - 1)
      local lines = vim.split(head, "\r\n", { plain = true })
      local method, target = lines[1]:match("^(%u+) (%S+) HTTP/1.1$")
      local headers = {}
      for i = 2, #lines do
        local k, v = lines[i]:match("^([^:]+):%s*(.*)$")
        headers[assert(k):lower()] = v
      end
      local need = tonumber(headers["content-length"] or "0") or 0
      if #buf - head_end - 3 < need then
        return
      end
      local req = {
        method = method,
        target = target,
        headers = headers,
        body = buf:sub(head_end + 4, head_end + 3 + need),
      }
      seen[#seen + 1] = req
      c:read_stop()
      local out = handle(req, #seen)
      local parts = type(out) == "table" and out or { out }
      local function write(i)
        if i > #parts then
          return c:shutdown(function()
            if not c:is_closing() then
              c:close()
            end
          end)
        end
        c:write(parts[i], function()
          vim.defer_fn(function()
            write(i + 1)
          end, 5)
        end)
      end
      vim.schedule(function()
        write(1)
      end)
    end)
  end)
  http_servers[#http_servers + 1] = srv
  return "http://127.0.0.1:" .. assert(srv:getsockname()).port, seen
end

---Close the servers started by http_server (post_case hook).
function M.close_http_servers()
  for _, s in ipairs(http_servers) do
    if not s:is_closing() then
      s:close()
    end
  end
  http_servers = {}
end

return M
