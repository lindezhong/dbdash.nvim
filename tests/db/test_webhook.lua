-- webhook:// end to end: an OpenAPI document served on a local port, requests sent as raw
-- HTTP; items, rejections (problem+json) and the MCP-derived checks.
local db = require("dbdash.db")
local map = require("dbdash.util.map")
local eq = MiniTest.expect.equality

local streams = {}
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      for _, s in ipairs(streams) do
        s.handle:stop("test done")
      end
      streams = {}
      vim.wait(50)
    end,
  },
})

local DOC = [[
openapi: 3.1.0
info: { title: t, version: "1" }
security: [ { bearer: [] } ]
paths:
  /orders/{shop}:
    post:
      operationId: push_orders
      parameters:
        - { name: shop, in: path, required: true, schema: { type: string, enum: [bj, sh] } }
        - { name: limit, in: query, schema: { type: integer, default: 10 } }
        - { name: X-Source, in: header, schema: { type: string } }
      requestBody:
        required: true
        content:
          application/x-ndjson: { schema: { $ref: "#/components/schemas/Order" } }
          application/json: { schema: { type: array, items: { $ref: "#/components/schemas/Order" } } }
          application/x-www-form-urlencoded: { schema: { type: object, properties: { id: { type: integer } } } }
      responses: { "202": { description: queued } }
  /ping:
    get:
      operationId: ping
      security: []
      parameters: [ { name: n, in: query, schema: { type: integer } } ]
      responses:
        "200":
          description: ok
          content: { application/json: { example: { pong: true } } }
components:
  schemas:
    Order: { type: object, required: [id], properties: { id: { type: integer }, amt: { type: number, minimum: 0 } } }
  securitySchemes:
    bearer: { type: http, scheme: bearer }
]]

---Start a webhook stream; returns its state with the port once it listens.
local function start(url, doc, options)
  local st = { items = {} }
  st.handle = db.stream(url, doc or DOC, {
    options = options or { tokens = { bearer = "s3cret" } },
    base_dir = vim.fn.getcwd(),
    on_status = function(s)
      st.status = s
    end,
  }, function(v, vars)
    st.items[#st.items + 1] = { value = v, vars = vars }
  end, function(err)
    st.ended, st.err = true, err
  end)
  streams[#streams + 1] = st
  vim.wait(3000, function()
    return st.status ~= nil or st.ended
  end, 5)
  st.port = st.status and tonumber(st.status:match(":(%d+)$"))
  return st
end

---Send raw request text to the port; returns { status, headers, body, json }.
local function raw(port, text, o)
  o = o or {}
  local res
  local tcp = vim.uv.new_tcp()
  local chunks = {}
  tcp:connect("127.0.0.1", port, function(err)
    if err then
      res = { error = err }
      return
    end
    local function done()
      if not tcp:is_closing() then
        tcp:close()
      end
      local s = table.concat(chunks)
      local head, body = s:match("^(.-)\r\n\r\n(.*)$")
      local status = head and tonumber(head:match("^HTTP/1%.1 (%d+)"))
      local headers = {}
      for k, v in (head or ""):gmatch("\r\n([^:]+): ([^\r]*)") do
        headers[k:lower()] = v
      end
      local ok, j = pcall(vim.json.decode, body or "")
      res = { status = status, headers = headers, body = body, json = ok and j or nil, raw = s }
    end
    tcp:read_start(function(rerr, chunk)
      if rerr or not chunk then
        done()
      else
        chunks[#chunks + 1] = chunk
      end
    end)
    if o.slow then
      tcp:write(text:sub(1, 10)) -- and nothing more
    else
      tcp:write(text)
    end
  end)
  vim.wait(o.wait or 5000, function()
    return res ~= nil
  end, 5)
  if not res and not tcp:is_closing() then
    tcp:close()
  end
  return res or { status = "no response" }
end

local function request(st, method, target, body, headers)
  local lines = { ("%s %s HTTP/1.1"):format(method, target), "Host: 127.0.0.1:" .. st.port }
  for k, v in pairs(headers or {}) do
    lines[#lines + 1] = k .. ": " .. v
  end
  if body then
    lines[#lines + 1] = "Content-Length: " .. #body
  end
  return raw(st.port, table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or ""))
end

local AUTH = { Authorization = "Bearer s3cret" }
local function with(h, extra)
  return vim.tbl_extend("force", {}, h, extra)
end

local function plain(v)
  if map.is_map(v) then
    local out = {}
    for k, x in map.pairs(v) do
      out[k] = plain(x)
    end
    return out
  elseif type(v) == "table" and v ~= vim.NIL then
    return vim.tbl_map(plain, v)
  end
  return v
end

T["items by media type, with params and request"] = function()
  local st = start("webhook://127.0.0.1:0/api")
  eq(st.status:match("^listening 127%.0%.0%.1:%d+$") ~= nil, true)
  local r = request(
    st,
    "POST",
    "/api/orders/bj?limit=5",
    '{"id": 1}\n{"id": 2, "amt": 3.5}\n',
    with(AUTH, { ["Content-Type"] = "application/x-ndjson", ["X-Source"] = "erp" })
  )
  eq({ r.status, r.json.queued }, { 202, 2 })
  r = request(
    st,
    "POST",
    "/api/orders/sh",
    '[{"id": 3}, {"id": 4}]',
    with(AUTH, { ["Content-Type"] = "application/json" })
  )
  eq({ r.status, r.json.queued }, { 202, 1 }) -- a JSON body is one item
  r = request(
    st,
    "POST",
    "/api/orders/sh",
    "id=5",
    with(AUTH, { ["Content-Type"] = "application/x-www-form-urlencoded" })
  )
  eq(r.status, 202)
  r = request(st, "GET", "/api/ping?n=7")
  eq({ r.status, r.json }, { 200, { pong = true } }) -- the documented response and example
  vim.wait(200, function()
    return #st.items == 5
  end, 5)
  local v = vim.tbl_map(function(it)
    return plain(it.value)
  end, st.items)
  eq(v, { { id = 1 }, { id = 2, amt = 3.5 }, { { id = 3 }, { id = 4 } }, { id = 5 }, { n = 7 } })
  local vars = st.items[1].vars
  eq(plain(vars.params), {
    path = { shop = "bj" },
    query = { limit = 5 },
    header = { ["X-Source"] = "erp" },
    cookie = {},
  })
  eq(
    { vars.request.method, vars.request.path, vars.request.operation_id, vars.request.content_type },
    { "POST", "/api/orders/bj", "push_orders", "application/x-ndjson" }
  )
  eq(vars.request.headers.authorization, nil) -- credentials are not passed on
  eq(vars.request.headers["x-source"], "erp")
end

T["rejections are problem+json: 400 401 404 405 413 415"] = function()
  local st =
    start("webhook://127.0.0.1:0/api", nil, { tokens = { bearer = "s3cret" }, max_body = 100 })
  local nd = with(AUTH, { ["Content-Type"] = "application/x-ndjson" })
  local function status(r)
    eq(r.headers["content-type"], "application/problem+json")
    eq(r.json.status, r.status)
    return r.status, r.json.detail
  end
  eq({
    status(
      request(
        st,
        "POST",
        "/api/orders/bj",
        '{"id": 1}',
        with(nd, { Authorization = "Bearer wrong" })
      )
    ),
  }, { 401, "authentication required" })
  eq(
    request(
      st,
      "POST",
      "/api/orders/bj",
      '{"id": 1}',
      { ["Content-Type"] = "application/x-ndjson" }
    ).headers["www-authenticate"],
    'Bearer realm="dbdash"'
  )
  eq({ status(request(st, "POST", "/api/nope", "", AUTH)) }, { 404, "no such path" })
  local r = request(st, "DELETE", "/api/orders/bj", nil, AUTH)
  eq({ status(r) }, { 405, "method not allowed" })
  eq(r.headers.allow, "POST")
  eq(
    { status(request(st, "POST", "/api/orders/xx", '{"id": 1}', nd)) },
    { 400, 'path parameter shop: must be one of ["bj","sh"]' }
  )
  eq({
    status(
      request(st, "POST", "/api/orders/bj", "<x/>", with(AUTH, { ["Content-Type"] = "text/xml" }))
    ),
  }, { 415, "unsupported media type text/xml" })
  eq(
    { status(request(st, "POST", "/api/orders/bj", nil, nd)) },
    { 400, "a request body is required" }
  )
  eq((status(request(st, "POST", "/api/orders/bj", ("x"):rep(200), nd))), 413)
  eq({ status(request(st, "POST", "/api/orders/bj", "{bad", nd)) }, {
    400,
    "item 1: invalid JSON (Expected object key string but found invalid token at character 2)",
  })
  -- A stream with a bad item: the ones before it are taken.
  r = request(st, "POST", "/api/orders/bj", '{"id": 1}\n{"amt": -1}\n{"id": 3}\n', nd)
  eq(
    { status(r) },
    { 400, 'item 2: missing required property "id" (1 item(s) before it were accepted)' }
  )
  vim.wait(100)
  eq(#st.items, 1)
  eq(st.handle.stats.rejected[400] >= 3, true)
end

T["Host and Origin are checked (DNS rebinding)"] = function()
  local st = start("webhook://127.0.0.1:0", "", {})
  local function send(headers)
    local lines = { "POST / HTTP/1.1", "Content-Length: 1" }
    for k, v in pairs(headers) do
      lines[#lines + 1] = k .. ": " .. v
    end
    return raw(st.port, table.concat(lines, "\r\n") .. "\r\n\r\nx")
  end
  eq(send({ Host = "127.0.0.1:" .. st.port }).status, 202)
  eq(send({ Host = "localhost" }).status, 202)
  eq(send({ Host = "evil.example" }).status, 403)
  eq(send({ Host = "127.0.0.1", Origin = "http://evil.example" }).status, 403)
  local st2 = start(
    "webhook://127.0.0.1:0",
    "",
    { allowed_origins = { "http://app.local" }, allowed_hosts = { "dash.local" } }
  )
  st = st2
  eq(send({ Host = "dash.local", Origin = "http://app.local" }).status, 202)
end

T["without a document: POST or PUT of anything at the URL's path"] = function()
  local st = start("webhook://127.0.0.1:0/in", "", {})
  eq(request(st, "POST", "/in", "a\nb\n", { ["Content-Type"] = "text/plain" }).json.queued, 2)
  eq(
    request(st, "PUT", "/in", '{"x": 1}', { ["Content-Type"] = "application/json" }).json.queued,
    1
  )
  eq(request(st, "POST", "/other", "x", {}).status, 404)
  vim.wait(100)
  eq(
    plain(vim.tbl_map(function(it)
      return it.value
    end, st.items)),
    { "a", "b", { x = 1 } }
  )
end

T["chunked bodies, slow requests and the connection limit"] = function()
  local st = start("webhook://127.0.0.1:0", "", { timeout = "300ms", max_connections = 1 })
  local r = raw(
    st.port,
    table.concat({
      "POST / HTTP/1.1",
      "Host: 127.0.0.1",
      "Content-Type: text/plain",
      "Transfer-Encoding: chunked",
      "",
      "4",
      "a\nb\n",
      "2",
      "c\n",
      "0",
      "",
      "",
    }, "\r\n")
  )
  eq({ r.status, r.json.queued }, { 202, 3 })
  -- A request that stops half way gets 408 after the timeout.
  eq(raw(st.port, "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\n", { slow = true }).status, 408)
  -- While one connection is open (max_connections = 1), another is closed at once.
  local held = vim.uv.new_tcp()
  held:connect("127.0.0.1", st.port, function()
    held:write("POST / HTTP/1.1\r\n")
  end)
  vim.wait(100)
  local r2 =
    raw(st.port, "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1\r\n\r\nx", { wait = 250 })
  eq(r2.status, nil) -- closed without a response
  held:close()
end

T["config: non-local addresses need security; credentials never in the URL"] = function()
  local st = start("webhook://0.0.0.0:0", "", {})
  eq(st.err.phase, "config")
  eq(st.err.message:find("needs a security requirement on every operation", 1, true) ~= nil, true)
  st = start(
    "webhook://127.0.0.1:0",
    "openapi: 3.1.0\ninfo: {title: t, version: '1'}\npaths:\n  /a: {get: {security: [{k: []}]}}\ncomponents:\n  securitySchemes:\n    k: {type: apiKey, in: query, name: key}\n",
    { tokens = { k = "x" } }
  )
  eq(st.err.message:find("must not be in URLs", 1, true) ~= nil, true)
  st = start("webhook://127.0.0.1", "", {})
  eq(st.err.message:find("needs a port", 1, true) ~= nil, true)
end

T["tokens: ${NAME} reads the environment; an unset one is a config error"] = function()
  vim.env.DBDASH_TEST_TOKEN = "from-env"
  local st =
    start("webhook://127.0.0.1:0/api", nil, { tokens = { bearer = "${DBDASH_TEST_TOKEN}" } })
  eq(request(st, "GET", "/api/ping").status, 200)
  local nd = { ["Content-Type"] = "application/x-ndjson" }
  eq(
    request(
      st,
      "POST",
      "/api/orders/bj",
      '{"id": 1}',
      with(nd, { Authorization = "Bearer from-env" })
    ).status,
    202
  )
  eq(
    request(
      st,
      "POST",
      "/api/orders/bj",
      '{"id": 1}',
      with(nd, { Authorization = "Bearer ${DBDASH_TEST_TOKEN}" })
    ).status,
    401
  )
  vim.env.DBDASH_TEST_TOKEN = nil
  st = start("webhook://127.0.0.1:0/api", nil, { tokens = { bearer = "${DBDASH_TEST_TOKEN}" } })
  eq(
    st.err.message,
    "database.options.tokens.bearer: environment variable DBDASH_TEST_TOKEN is not set"
  )
end

T["a busy port is an error; stopping frees the port"] = function()
  local a = start("webhook://127.0.0.1:0", "", {})
  local b = start("webhook://127.0.0.1:" .. a.port, "", {})
  eq(b.err.phase, "connect")
  a.handle:stop("x")
  vim.wait(500, function()
    return a.ended
  end, 5)
  local c = start("webhook://127.0.0.1:" .. a.port, "", {})
  eq(c.err, nil)
  eq(c.port, a.port)
end

return T
