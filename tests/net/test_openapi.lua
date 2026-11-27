-- OpenAPI for webhook://: routing, parameters (every style / explode of the specification's
-- "Style Examples" table), request bodies by media type, security, $ref.
local openapi = require("dbdash.net.openapi")
local map = require("dbdash.util.map")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

---Plain Lua data of a value (maps as tables) to compare.
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

local function api_of(paths, extra)
  return openapi.load(
    "openapi: 3.1.0\ninfo: {title: t, version: '1'}\npaths:\n" .. paths .. (extra or ""),
    {
      base_dir = vim.fn.getcwd(),
      tokens = { tok = "s3cret", basic = "u:p", key = { "k1", "k2" }, ck = "c1" },
    }
  )
end

local function err_of(fn)
  local ok, e = pcall(fn)
  eq(ok, false)
  return e
end

T["routing: templates, concrete paths first, 404, 405 with the allowed methods, base path"] = function()
  local api = openapi.load(
    [[
openapi: 3.1.0
info: {title: t, version: "1"}
paths:
  /items/{id}: { get: { operationId: one }, delete: { operationId: del } }
  /items/latest: { get: { operationId: latest } }
  /a/{x}/b/{y}: { post: { operationId: two } }
]],
    { base_path = "/api" }
  )
  local op = assert(api:match("GET", "/api/items/latest"))
  eq(op.id, "latest")
  local values
  op, values = assert(api:match("GET", "/api/items/42"))
  eq({ op.id, values.id }, { "one", "42" })
  op, values = assert(api:match("POST", "/api/a/1/b/2"))
  eq({ op.id, values.x, values.y }, { "two", "1", "2" })
  eq({ api:match("GET", "/items/42") }, { nil, 404 }) -- the base path is part of it
  eq({ api:match("GET", "/api/items/1/x") }, { nil, 404 })
  local _, status, allow = api:match("PUT", "/api/items/1")
  eq({ status, allow }, { 405, { "DELETE", "GET" } })
  eq(api:match("HEAD", "/api/items/1").id, "one")
end

-- The specification's Style Examples: color = "blue", ["blue", "black", "brown"] or
-- { R = 100, G = 200, B = 150 }.
local STYLES = {
  -- location, style, explode, type, raw, expected
  { "path", "matrix", false, "string", ";color=blue", "blue" },
  { "path", "matrix", false, "array", ";color=blue,black,brown", { "blue", "black", "brown" } },
  {
    "path",
    "matrix",
    true,
    "array",
    ";color=blue;color=black;color=brown",
    { "blue", "black", "brown" },
  },
  { "path", "matrix", false, "object", ";color=R,100,G,200,B,150", { R = 100, G = 200, B = 150 } },
  { "path", "matrix", true, "object", ";R=100;G=200;B=150", { R = 100, G = 200, B = 150 } },
  { "path", "label", false, "string", ".blue", "blue" },
  { "path", "label", false, "array", ".blue,black,brown", { "blue", "black", "brown" } },
  { "path", "label", true, "array", ".blue.black.brown", { "blue", "black", "brown" } },
  { "path", "label", false, "object", ".R,100,G,200,B,150", { R = 100, G = 200, B = 150 } },
  { "path", "label", true, "object", ".R=100.G=200.B=150", { R = 100, G = 200, B = 150 } },
  { "path", "simple", false, "string", "blue", "blue" },
  { "path", "simple", false, "array", "blue,black,brown", { "blue", "black", "brown" } },
  { "path", "simple", true, "array", "blue,black,brown", { "blue", "black", "brown" } },
  { "path", "simple", false, "object", "R,100,G,200,B,150", { R = 100, G = 200, B = 150 } },
  { "path", "simple", true, "object", "R=100,G=200,B=150", { R = 100, G = 200, B = 150 } },
  { "query", "form", false, "string", "color=blue", "blue" },
  { "query", "form", false, "array", "color=blue,black,brown", { "blue", "black", "brown" } },
  {
    "query",
    "form",
    true,
    "array",
    "color=blue&color=black&color=brown",
    { "blue", "black", "brown" },
  },
  { "query", "form", false, "object", "color=R,100,G,200,B,150", { R = 100, G = 200, B = 150 } },
  { "query", "form", true, "object", "R=100&G=200&B=150", { R = 100, G = 200, B = 150 } },
  {
    "query",
    "spaceDelimited",
    false,
    "array",
    "color=blue%20black%20brown",
    { "blue", "black", "brown" },
  },
  {
    "query",
    "spaceDelimited",
    false,
    "object",
    "color=R%20100%20G%20200%20B%20150",
    { R = 100, G = 200, B = 150 },
  },
  {
    "query",
    "pipeDelimited",
    false,
    "array",
    "color=blue|black|brown",
    { "blue", "black", "brown" },
  },
  {
    "query",
    "pipeDelimited",
    false,
    "object",
    "color=R|100|G|200|B|150",
    { R = 100, G = 200, B = 150 },
  },
  {
    "query",
    "deepObject",
    true,
    "object",
    "color[R]=100&color[G]=200&color[B]=150",
    { R = 100, G = 200, B = 150 },
  },
  { "header", "simple", false, "array", "blue,black,brown", { "blue", "black", "brown" } },
  { "header", "simple", true, "object", "R=100,G=200,B=150", { R = 100, G = 200, B = 150 } },
  { "cookie", "form", false, "array", "color=blue,black,brown", { "blue", "black", "brown" } },
}

local SCHEMAS = {
  string = "{type: string}",
  array = "{type: array, items: {type: string}}",
  object = "{type: object, properties: {R: {type: integer}, G: {type: integer}, B: {type: integer}}}",
}

T["parameters: every style and explode of the specification's examples"] = function()
  local wrong = {}
  for _, c in ipairs(STYLES) do
    local where, style, explode, t, raw, want = unpack(c)
    local key = where == "path" and "/c/{color}" or "/c"
    local api = api_of(
      ("  %s:\n    get:\n      parameters:\n        - {name: color, in: %s, required: true, style: %s, explode: %s, schema: %s}\n"):format(
        key,
        where,
        style,
        tostring(explode),
        SCHEMAS[t]
      )
    )
    local req = { headers = {}, query = "" }
    local path = "/c"
    if where == "path" then
      path = "/c/" .. raw
    elseif where == "query" then
      req.query = raw
    elseif where == "header" then
      req.headers.color = raw
    else
      req.headers.cookie = raw
    end
    local op, values = api:match("GET", path)
    local ok, params = pcall(api.parameters, api, op, req, values)
    local got = ok and plain(params[where].color) or ("error: " .. vim.inspect(params))
    if not vim.deep_equal(got, want) then
      wrong[#wrong + 1] = ("%s %s explode=%s %s %q -> %s"):format(
        where,
        style,
        tostring(explode),
        t,
        raw,
        vim.inspect(got)
      )
    end
  end
  eq(wrong, {})
end

T["parameters: types, defaults, required, validation, empty values, content"] = function()
  local api = api_of([[
  /p/{id}:
    get:
      parameters:
        - {name: id, in: path, required: true, schema: {type: integer}}
        - {name: limit, in: query, schema: {type: integer, default: 10, maximum: 100}}
        - {name: flag, in: query, schema: {type: boolean}}
        - {name: tags, in: query, schema: {type: array, items: {type: number}}}
        - {name: q, in: query, required: true, schema: {type: string, minLength: 2}}
        - {name: X-Trace, in: header, schema: {type: string, format: uuid}}
        - {name: filter, in: query, content: {application/json: {schema: {type: object, required: [a]}}}}
        - {name: e, in: query, allowEmptyValue: true, schema: {type: [integer, "null"]}}
]])
  local op, values = api:match("GET", "/p/7")
  local p = api:parameters(
    op,
    { query = "q=ab&flag=true&tags=1.5&tags=2&filter=%7B%22a%22%3A1%7D&e=", headers = {} },
    values
  )
  eq(plain(p.path), { id = 7 })
  eq(
    plain(p.query),
    { limit = 10, flag = true, tags = { 1.5, 2 }, q = "ab", filter = { a = 1 }, e = vim.NIL }
  )
  local function e400(query, headers, path)
    local o, v = api:match("GET", path or "/p/7")
    local e = err_of(function()
      api:parameters(o, { query = query, headers = headers or {} }, v)
    end)
    eq(e.http_status, 400)
    return e.detail
  end
  eq(e400("", {}), "missing required query parameter q")
  eq(e400("q=a"), "query parameter q: must be at least 2 characters long")
  eq(e400("q=ab&limit=500"), "query parameter limit: must be <= 100")
  eq(e400("q=ab&limit=x"), "query parameter limit: must be integer, got string")
  eq(e400("q=ab", {}, "/p/x"), "path parameter id: must be integer, got string")
  eq(e400("q=ab", { ["x-trace"] = "nope" }), "header parameter X-Trace: must be a valid uuid")
  eq(e400("q=ab&filter=%7B%7D"), 'query parameter filter: missing required property "a"')
  eq(e400("q=ab&limit="), "query parameter limit: an empty value is not allowed")
end

T["security: bearer, basic, apiKey in a header or cookie; or / and of requirements"] = function()
  local api = api_of(
    [[
  /a: { get: { security: [ {tok: []} ] } }
  /b: { get: { security: [ {basic: []} ] } }
  /c: { get: { security: [ {key: []} ] } }
  /d: { get: { security: [ {tok: []}, {key: []} ] } }
  /e: { get: { security: [ {tok: [], ck: []} ] } }
  /f: { get: { security: [] } }
  /g: { get: {} }
]],
    [[
security: [ {tok: []} ]
components:
  securitySchemes:
    tok: {type: http, scheme: bearer}
    basic: {type: http, scheme: basic}
    key: {type: apiKey, in: header, name: X-Key}
    ck: {type: apiKey, in: cookie, name: session}
]]
  )
  local function auth(path, headers)
    return (api:authorize(api:match("GET", path), headers))
  end
  eq(auth("/a", { authorization = "Bearer s3cret" }), true)
  eq(auth("/a", { authorization = "Bearer wrong" }), false)
  eq(auth("/a", {}), false)
  eq(select(2, api:authorize(api:match("GET", "/a"), {})), 'Bearer realm="dbdash"')
  eq(auth("/b", { authorization = "Basic " .. vim.base64.encode("u:p") }), true)
  eq(auth("/b", { authorization = "Basic " .. vim.base64.encode("u:x") }), false)
  eq(auth("/c", { ["x-key"] = "k2" }), true) -- one of several tokens
  eq(auth("/c", { ["x-key"] = "k3" }), false)
  eq(auth("/d", { ["x-key"] = "k1" }), true) -- either requirement
  eq(auth("/e", { authorization = "Bearer s3cret" }), false) -- both schemes needed
  eq(auth("/e", { authorization = "Bearer s3cret", cookie = "a=1; session=c1" }), true)
  eq(auth("/f", {}), true) -- security: [] turns the default off
  eq(auth("/g", {}), false) -- the document's default applies
end

T["security: refused schemes and missing credentials are config errors"] = function()
  local function load_err(schemes, sec)
    local e = err_of(function()
      openapi.load(
        ("openapi: 3.1.0\ninfo: {title: t, version: '1'}\npaths:\n  /a: { get: { security: [ {s: []} ] } }\ncomponents:\n  securitySchemes:\n    s: %s\n"):format(
          schemes
        ),
        { tokens = sec }
      )
    end)
    eq(e.phase, "config")
    return e.message
  end
  eq(
    load_err("{type: apiKey, in: query, name: k}", { s = "x" }):find("must not be in URLs", 1, true)
      ~= nil,
    true
  )
  eq(load_err("{type: oauth2, flows: {}}", { s = "x" }):find("not supported", 1, true) ~= nil, true)
  eq(
    load_err("{type: http, scheme: digest}", { s = "x" }):find("not supported", 1, true) ~= nil,
    true
  )
  eq(
    load_err("{type: http, scheme: bearer}", {}):find(
      "no credentials for security scheme s",
      1,
      true
    ) ~= nil,
    true
  )
end

T["request bodies: media type choice, forms, multipart, kinds"] = function()
  local api = api_of([[
  /b:
    post:
      requestBody:
        content:
          application/json: {schema: {type: object}}
          text/*: {}
          application/x-www-form-urlencoded:
            schema: {type: object, properties: {n: {type: integer}, tags: {type: array, items: {type: string}}, meta: {type: object}}}
            encoding: {meta: {contentType: application/json}}
          multipart/form-data:
            schema: {type: object, properties: {n: {type: integer}, doc: {type: object}}}
]])
  local op = api:match("POST", "/b")
  eq(api:media(op, "application/json; charset=utf-8"), "application/json")
  eq(api:media(op, "text/csv"), "text/*")
  eq(api:media(op, "image/png"), nil)
  local _, m, mdoc = api:media(op, "application/x-www-form-urlencoded")
  eq(
    plain(api:form("n=3&tags=a&tags=b&meta=%7B%22k%22%3A1%7D", m, mdoc)),
    { n = 3, tags = { "a", "b" }, meta = { k = 1 } }
  )
  local ct = "multipart/form-data; boundary=XyZ"
  local _, mm, mmdoc = api:media(op, ct)
  local body = table.concat({
    "--XyZ",
    'Content-Disposition: form-data; name="n"',
    "",
    "5",
    "--XyZ",
    'Content-Disposition: form-data; name="doc"; filename="d.json"',
    "Content-Type: application/json",
    "",
    '{"a": [1]}',
    "--XyZ--",
    "",
  }, "\r\n")
  eq(plain(api:multipart(body, ct, mm, mmdoc)), { n = 5, doc = { a = { 1 } } })
  eq({
    openapi.kind("application/x-ndjson"),
    openapi.kind("text/csv"),
    openapi.kind("application/vnd.x+json"),
    openapi.kind("application/xml"),
    openapi.kind("application/x-custom", { "application/x-custom" }),
  }, { "stream-json", "stream-text", "json", "raw", "stream-text" })
end

T["$ref: in the document and to other files (relative to the document)"] = function()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir .. "/schemas", "p")
  vim.fn.writefile({
    "Order:",
    "  type: object",
    "  required: [id]",
    "  properties:",
    "    id: {$ref: 'common.yaml#/Id'}",
  }, dir .. "/schemas/order.yaml")
  vim.fn.writefile({ "Id: {type: integer}" }, dir .. "/schemas/common.yaml")
  local api = openapi.load(
    [[
openapi: 3.1.0
info: {title: t, version: "1"}
paths:
  /o:
    $ref: "#/components/pathItems/o"
components:
  parameters:
    lim: {name: limit, in: query, schema: {type: integer}}
  pathItems:
    o:
      post:
        parameters: [ {$ref: "#/components/parameters/lim"} ]
        requestBody: {$ref: "#/components/requestBodies/order"}
  requestBodies:
    order:
      content:
        application/json: {schema: {$ref: "schemas/order.yaml#/Order"}}
]],
    { base_dir = dir }
  )
  local op = assert(api:match("POST", "/o"))
  eq(plain(api:parameters(op, { query = "limit=3", headers = {} }, {}).query), { limit = 3 })
  local _, m, mdoc = api:media(op, "application/json")
  assert(m)
  eq(api:validate(m.schema, openapi.decode_json('{"id": 1}'), mdoc), nil)
  eq(
    assert(api:validate(m.schema, openapi.decode_json('{"id": "x"}'), mdoc)).message,
    "must be integer, got string"
  )
  eq(#api.files, 2) -- the files it read (for trust)
  eq(err_of(function()
    openapi.load(
      "openapi: 3.1.0\ninfo: {title: t, version: '1'}\npaths:\n  /a: {$ref: 'nope.yaml#/x'}\n",
      { base_dir = dir }
    )
  end).message:find("missing file", 1, true) ~= nil, true)
end

T["versions: 3.1 and 3.0 (nullable); others are errors"] = function()
  local doc30 =
    "openapi: 3.0.3\ninfo: {title: t, version: '1'}\npaths:\n  /a:\n    get:\n      parameters: [{name: x, in: header, schema: {type: integer, nullable: true}}]\n"
  local api = openapi.load(doc30, {})
  eq(api.v30, true)
  eq(api:validate(api.doc.paths["/a"].get.parameters[1].schema, vim.NIL, api.doc), nil)
  eq(err_of(function()
    openapi.load("swagger: '2.0'\npaths: {}\n", {})
  end).message:find("unsupported version", 1, true) ~= nil, true)
end

return T
