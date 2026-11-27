-- JSON Schema 2020-12 validation: the official JSON-Schema-Test-Suite cases for the supported
-- keywords (tests/fixtures/jsonschema_suite.json, made by tests/util/jsonschema_gen.py), and
-- formats, OpenAPI's nullable, error paths.
local js = require("dbdash.util.jsonschema")
local json = require("dbdash.db.json")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function decode(s)
  return json.decode(s)
end

T["JSON-Schema-Test-Suite (draft 2020-12, supported keywords)"] = function()
  local text = table.concat(vim.fn.readfile("tests/fixtures/jsonschema_suite.json"), "\n")
  -- Decode each schema and instance on its own so that maps stay maps (dbdash.db.json).
  local cases = vim.json.decode(text)
  local wrong, total = {}, 0
  for _, c in ipairs(cases) do
    local schema = decode(vim.json.encode(c.schema))
    if type(c.schema) == "boolean" then
      schema = c.schema
    end
    for _, t in ipairs(c.tests) do
      total = total + 1
      local data = t.data
      if type(data) == "table" then
        data = decode(vim.json.encode(data))
      end
      local e = js.validate(schema, data)
      if (e == nil) ~= t.valid then
        wrong[#wrong + 1] = ("%s: %s / %s: expected %s%s"):format(
          c.file,
          c.description,
          t.description,
          tostring(t.valid),
          e and (" (" .. e.message .. ")") or ""
        )
      end
    end
  end
  eq(wrong, {})
  eq(total > 700, true)
end

local function check(schema, value, opts)
  local e = js.validate(decode(schema), value, opts)
  return e and (e.path .. ": " .. e.message) or "ok"
end

T["errors name the place of the problem"] = function()
  local s =
    [[{"type": "object", "properties": {"items": {"type": "array", "items": {"type": "integer", "minimum": 0}}}}]]
  eq(check(s, decode('{"items": [1, -2]}')), "/items/1: must be >= 0")
  eq(check(s, decode('{"items": "x"}')), "/items: must be array, got string")
  eq(check('{"required": ["id"]}', decode("{}")), '/: missing required property "id"')
  eq(
    check('{"additionalProperties": false, "properties": {"a": {}}}', decode('{"a": 1, "b/c": 2}')),
    '/b~1c: property "b/c" is not allowed'
  )
end

T["formats are checked with opts.formats"] = function()
  local cases = {
    ["date-time"] = {
      { "2024-02-29T10:20:30Z", true },
      { "2023-02-29T10:20:30Z", false },
      { "2024-01-01T25:00:00+01:00", false },
      { "2024-01-01t10:00:00.5-05:00", true },
    },
    date = { { "2024-12-31", true }, { "2024-13-01", false } },
    time = { { "23:59:60Z", true }, { "12:00:00", false } },
    email = { { "joe@example.com", true }, { "joe@", false }, { ".joe@example.com", false } },
    uri = { { "https://example.com/a?b", true }, { "no scheme", false } },
    uuid = {
      { "2eb8aa08-aa98-11ea-b4aa-73b441d16380", true },
      { "2eb8aa08-aa98-11ea-b4aa-73b441d1638", false },
    },
    ipv4 = { { "192.168.0.1", true }, { "256.1.1.1", false }, { "01.1.1.1", false } },
    ipv6 = {
      { "::1", true },
      { "2001:db8::8a2e:370:7334", true },
      { "::ffff:192.0.2.1", true },
      { "1::2::3", false },
      { "12345::", false },
    },
    hostname = {
      { "www.example.com", true },
      { "-bad.com", false },
      { ("a"):rep(64) .. ".com", false },
    },
  }
  for fmt, list in pairs(cases) do
    for _, c in ipairs(list) do
      local schema = map_of({ format = fmt })
      eq({ fmt, c[1], js.validate(schema, c[1], { formats = true }) == nil }, { fmt, c[1], c[2] })
      eq(js.validate(schema, c[1]), nil) -- an annotation without opts.formats
    end
  end
end

function _G.map_of(t)
  return decode(vim.json.encode(t))
end

T["OpenAPI 3.0 nullable"] = function()
  local s = decode('{"type": "string", "nullable": true, "enum": ["a"]}')
  eq(js.validate(s, vim.NIL, { nullable = true }), nil)
  eq(js.validate(s, vim.NIL) ~= nil, true)
  eq(js.validate(s, "b", { nullable = true }) ~= nil, true)
end

T["$ref into the document and through resolve; bad schemas are reported"] = function()
  local doc = decode('{"components": {"schemas": {"Id": {"type": "integer"}}}}')
  local s = decode('{"$ref": "#/components/schemas/Id"}')
  eq(js.validate(s, 3, nil, doc), nil)
  eq(js.validate(s, "x", nil, doc).message, "must be integer, got string")
  local ext = decode('{"type": "string"}')
  local r = js.validate(decode('{"$ref": "other.yaml#/x"}'), 1, {
    resolve = function(ref)
      eq(ref, "other.yaml#/x")
      return ext, ext
    end,
  })
  eq(r.message, "must be string, got integer")
  eq(js.validate(decode('{"$ref": "#/nope"}'), 1).schema_error, true)
  eq(
    js.validate(decode('{"pattern": "(?=x)"}'), "x").message:find("invalid pattern", 1, true) ~= nil,
    true
  )
  -- A $ref loop stops.
  eq(
    js.validate(decode('{"$defs": {"a": {"$ref": "#/$defs/a"}}, "$ref": "#/$defs/a"}'), 1).schema_error,
    true
  )
end

return T
