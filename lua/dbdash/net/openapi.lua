-- OpenAPI 3.1 (and 3.0) for webhook://: load a document, match requests to its operations,
-- deserialize and validate parameters and request bodies, check security requirements.
--
--   local api = openapi.load(text, { base_dir = ..., base_path = "/api", tokens = {...} })
--   local op, path_params = api:match(method, path)   -- nil, status (404 / 405) and Allow
--   local params = api:parameters(op, req, path_params)  -- raises { http_status = 400 }
--   local ok, scheme = api:authorize(op, headers, cookies)
--   local media = api:media(op, content_type)            -- the request body's media type
--
-- Schemas are JSON Schema 2020-12 (util/jsonschema.lua; 3.0 documents get `nullable`).
local map = require("dbdash.util.map")
local js = require("dbdash.util.jsonschema")

local M = {}

local NULL = vim.NIL
local METHODS = { "get", "put", "post", "delete", "patch", "head", "options", "trace" }

local function cfg_error(msg, ...)
  error({ phase = "config", message = "OpenAPI: " .. msg:format(...) }, 0)
end

local function bad(status, msg, ...)
  error({ http_status = status, detail = msg:format(...) }, 0)
end

local function is_map(v)
  return map.is_map(v)
end

---Decode JSON text into dbdash values (ordered maps), or nil and an error.
function M.decode_json(s)
  local ok, v = pcall(vim.json.decode, s)
  if not ok then
    return nil, tostring(v):gsub("^.-:%d+: ", "")
  end
  return require("dbdash.db.json").decode(s), nil
end

-- Documents and $ref ----------------------------------------------------------------------

local Api = {}
Api.__index = Api

---Parse YAML or JSON text (JSON is YAML).
local function parse(text, name)
  local doc, err = require("dbdash.yaml").parse(text)
  if doc == nil and err then
    cfg_error("%s: %s", name, tostring(err.message or err))
  end
  return doc
end

---The document of an external reference (relative to the document's file), cached.
function Api:external(file, from)
  local dir = self.paths[from] and vim.fs.dirname(self.paths[from]) or self.base_dir
  local path = vim.fs.normalize((file:sub(1, 1) == "/" or file:match("^%a:[/\\]")) and file or vim.fs.joinpath(dir, file))
  if self.docs[path] then
    return self.docs[path]
  end
  local f = io.open(path, "rb")
  if not f then
    cfg_error("$ref to a missing file: %s", path)
  end
  local text = f:read("*a")
  f:close()
  local doc = parse(text, path)
  self.docs[path] = doc
  self.paths[doc] = path
  self.files[#self.files + 1] = { path = path, text = text }
  return doc
end

---Resolve `ref` found in document `doc`: the target and the document it is in.
function Api:resolve(ref, doc)
  local file, pointer = ref:match("^([^#]*)#?(.*)$")
  local target_doc = doc
  if file ~= "" then
    target_doc = self:external(file, doc)
  end
  local target = js.pointer(target_doc, pointer)
  if target == nil then
    cfg_error("$ref %s not found", ref)
  end
  return target, target_doc
end

---Follow $ref of a (non-schema) object: the object and its document.
function Api:deref(obj, doc)
  local n = 0
  while is_map(obj) and obj["$ref"] ~= nil do
    n = n + 1
    if n > 50 then
      cfg_error("$ref loop at %s", tostring(obj["$ref"]))
    end
    obj, doc = self:resolve(obj["$ref"], doc)
  end
  return obj, doc
end

---Validate a value against a schema of document `doc`; the first error or nil.
function Api:validate(schema, value, doc)
  local e = js.validate(schema, value, {
    formats = true,
    nullable = self.v30,
    resolve = function(ref, base)
      return self:resolve(ref, base)
    end,
  }, doc)
  if e and e.schema_error then
    cfg_error("%s", e.message)
  end
  return e
end

-- Routes -------------------------------------------------------------------------------------

local function lua_pattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

---Load an OpenAPI document.
---@param text string YAML or JSON
---@param o { base_dir: string?, base_path: string?, tokens: table? }
function M.load(text, o)
  o = o or {}
  local doc = parse(text, "the document")
  if not is_map(doc) then
    cfg_error("the document must be a mapping")
  end
  local version = tostring(doc.openapi or "")
  local self = setmetatable({
    doc = doc,
    base_dir = o.base_dir or vim.fn.getcwd(),
    docs = {},
    paths = {},
    files = {},
    tokens = o.tokens or {},
    routes = {},
  }, Api)
  if version:match("^3%.1") then
    self.v30 = false
  elseif version:match("^3%.0") then
    self.v30 = true
  else
    cfg_error("unsupported version %s (openapi: 3.1.x or 3.0.x)", version ~= "" and version or "(none)")
  end
  local schemes = doc.components and doc.components.securitySchemes or map.new()
  self.schemes = {}
  for name, sch in map.pairs(schemes) do
    local s = self:deref(sch, doc)
    self:check_scheme(name, s)
    self.schemes[name] = s
  end
  local base_path = o.base_path or ""
  for key, item in map.pairs(doc.paths or map.new()) do
    local pi, pdoc = self:deref(item, doc)
    -- Path templates: {name} matches one segment.
    local names, pat, literal = {}, {}, 0
    local full = base_path .. key
    local pos = 1
    while true do
      local a, b, name = full:find("{([^}]+)}", pos)
      if not a then
        pat[#pat + 1] = lua_pattern(full:sub(pos))
        literal = literal + #full - pos + 1
        break
      end
      pat[#pat + 1] = lua_pattern(full:sub(pos, a - 1)) .. "([^/]+)"
      literal = literal + a - pos
      names[#names + 1] = name
      pos = b + 1
    end
    local route = { key = key, path = full, pattern = "^" .. table.concat(pat) .. "$", names = names, literal = literal, ops = {} }
    for _, m in ipairs(METHODS) do
      if pi[m] ~= nil then
        local op = pi[m]
        route.ops[m:upper()] = self:operation(op, pi, pdoc, m, key)
      end
    end
    self.routes[#self.routes + 1] = route
  end
  -- Concrete paths before templated ones, then the longer literal part first.
  table.sort(self.routes, function(a, b)
    if #a.names ~= #b.names then
      return #a.names < #b.names
    end
    return a.literal > b.literal
  end)
  return self
end

function Api:check_scheme(name, s)
  local t = s.type
  if t == "http" then
    local scheme = tostring(s.scheme or ""):lower()
    if scheme ~= "bearer" and scheme ~= "basic" then
      cfg_error("security scheme %s: http scheme %q is not supported (bearer, basic)", name, scheme)
    end
  elseif t == "apiKey" then
    if s["in"] == "query" then
      cfg_error("security scheme %s: an apiKey in the query string is refused: credentials must not be in URLs (MCP / OAuth 2.1); use a header or a cookie", name)
    elseif s["in"] ~= "header" and s["in"] ~= "cookie" then
      cfg_error("security scheme %s: apiKey must be in header or cookie", name)
    end
  elseif t == "oauth2" or t == "openIdConnect" or t == "mutualTLS" then
    cfg_error("security scheme %s: %s is not supported (it needs an authorization server or TLS client certificates); use http bearer, http basic or apiKey", name, t)
  else
    cfg_error("security scheme %s: unknown type %s", name, tostring(t))
  end
end

---Compile an operation: its parameters (path item's merged with its own), request body,
---security and response.
function Api:operation(op, item, doc, method, key)
  local params, order = {}, {}
  for _, list in ipairs({ item.parameters or {}, op.parameters or {} }) do
    for _, p in ipairs(list) do
      local pr, pdoc = self:deref(p, doc)
      local id = tostring(pr["in"]) .. ":" .. tostring(pr.name)
      if not params[id] then
        order[#order + 1] = id
      end
      params[id] = { p = pr, doc = pdoc }
    end
  end
  local out = { id = op.operationId or (method .. " " .. key), method = method:upper(), params = {}, doc = doc }
  for _, id in ipairs(order) do
    local pr = params[id]
    local where = pr.p["in"]
    if where ~= "query" and where ~= "path" and where ~= "header" and where ~= "cookie" then
      cfg_error("%s: parameter %s: unknown location %s", out.id, tostring(pr.p.name), tostring(where))
    end
    out.params[#out.params + 1] = pr
  end
  if op.requestBody ~= nil then
    out.body, out.body_doc = self:deref(op.requestBody, doc)
  end
  local sec = op.security
  if sec == nil then
    sec = self.doc.security
  end
  out.security = sec or {}
  for _, req in ipairs(out.security) do
    for name in map.pairs(req) do
      if not self.schemes[name] then
        cfg_error("%s: security requirement %s is not in components.securitySchemes", out.id, name)
      end
      if self.tokens[name] == nil then
        cfg_error("%s: no credentials for security scheme %s (database.options.tokens.%s)", out.id, name, name)
      end
    end
  end
  -- The first 2xx response (by code; "2XX" counts as 200).
  local codes = {}
  for code, r in map.pairs(op.responses or map.new()) do
    local c = tostring(code):upper()
    local n = c == "2XX" and 200 or tonumber(c)
    if n and n >= 200 and n < 300 then
      codes[#codes + 1] = { n = n, r = r }
    end
  end
  table.sort(codes, function(a, b)
    return a.n < b.n
  end)
  if codes[1] then
    local r, rdoc = self:deref(codes[1].r, doc)
    out.status = codes[1].n
    for mt, media in map.pairs(r.content or map.new()) do
      local m = self:deref(media, rdoc)
      local example = m.example
      if example == nil and is_map(m.examples) then
        for _, ex in map.pairs(m.examples) do
          example = self:deref(ex, rdoc).value
          break
        end
      end
      if example ~= nil then
        out.example = { type = mt, value = example }
      end
      break
    end
  end
  return out
end

---The operation for a request: op, path parameter strings; or nil, status, allowed methods.
function Api:match(method, path)
  for _, r in ipairs(self.routes) do
    local caps = { path:match(r.pattern) }
    if #caps > 0 or (#r.names == 0 and path:match(r.pattern)) then
      local op = r.ops[method] or (method == "HEAD" and r.ops.GET)
      if not op then
        local allow = vim.tbl_keys(r.ops)
        table.sort(allow)
        return nil, 405, allow
      end
      local values = {}
      for i, name in ipairs(r.names) do
        values[name] = caps[i]
      end
      return op, values
    end
  end
  return nil, 404
end

-- Parameters ------------------------------------------------------------------------------

local function unescape(s, plus)
  if plus then
    s = s:gsub("+", " ")
  end
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end
M.unescape = unescape

---Query string pairs in order: { { name, value } } (names and values decoded).
function M.query_pairs(q)
  local out = {}
  for pair in (q or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    out[#out + 1] = { unescape(k, true), unescape(v, true), raw = pair:find("=", 1, true) ~= nil }
  end
  return out
end

---Cookies of a Cookie header: { name = value } (and lists for repeated names).
function M.cookies(header)
  local out = {}
  for part in (header or ""):gmatch("[^;]+") do
    local k, v = vim.trim(part):match("^([^=]+)=(.*)$")
    if k then
      if out[k] == nil then
        out[k] = v
      elseif type(out[k]) == "table" then
        table.insert(out[k], v)
      else
        out[k] = { out[k], v }
      end
    end
  end
  return out
end

---The schema type of a parameter ("array", "object" or a primitive), following $ref.
function Api:schema_type(schema, doc)
  local s = schema
  local n = 0
  while is_map(s) and s["$ref"] ~= nil and n < 20 do
    s, doc = self:resolve(s["$ref"], doc)
    n = n + 1
  end
  if not is_map(s) then
    return nil, s, doc
  end
  local t = s.type
  if type(t) == "table" then
    for _, x in ipairs(t) do
      if x ~= "null" then
        t = x
        break
      end
    end
  end
  if t == nil and (s.properties ~= nil or s.additionalProperties ~= nil) then
    t = "object"
  elseif t == nil and (s.items ~= nil or s.prefixItems ~= nil) then
    t = "array"
  end
  return t, s, doc
end

---A string from the request as a value of `schema` (numbers, booleans and null from text);
---values that do not convert stay strings and fail validation.
function Api:coerce(text, schema, doc)
  local t, s = self:schema_type(schema, doc)
  if type(text) ~= "string" then
    return text
  end
  local function as(tt)
    if tt == "integer" or tt == "number" then
      local n = tonumber(text)
      if n and text:match("^%s*[-+]?[%d.]") then
        return n
      end
    elseif tt == "boolean" then
      if text == "true" then
        return true
      elseif text == "false" then
        return false
      end
    elseif tt == "null" and text == "" then
      return NULL
    end
  end
  local types = is_map(s) and type(s.type) == "table" and s.type or { t }
  for _, tt in ipairs(types) do
    local v = as(tt)
    if v ~= nil then
      return v
    end
  end
  return text
end

---Items and properties of an array / object schema.
function Api:items_schema(schema, doc)
  local _, s, sdoc = self:schema_type(schema, doc)
  return is_map(s) and s.items or true, sdoc
end

function Api:prop_schema(schema, doc, name)
  local _, s, sdoc = self:schema_type(schema, doc)
  if is_map(s) then
    if is_map(s.properties) and s.properties[name] ~= nil then
      return s.properties[name], sdoc
    end
    if s.additionalProperties ~= nil and s.additionalProperties ~= false then
      return s.additionalProperties, sdoc
    end
  end
  return true, sdoc
end

---"a,b,c" -> list of values of the items schema.
function Api:list_of(parts, schema, doc)
  local is, idoc = self:items_schema(schema, doc)
  local out = {}
  for i, p in ipairs(parts) do
    out[i] = self:coerce(p, is, idoc)
  end
  return out
end

---{ k1, v1, k2, v2 } or { "k=v", ... } -> mapping of the object schema.
function Api:object_of(pairs_, schema, doc)
  local out = map.new()
  for _, kv in ipairs(pairs_) do
    local ps, pdoc = self:prop_schema(schema, doc, kv[1])
    map.set(out, kv[1], self:coerce(kv[2], ps, pdoc))
  end
  return out
end

local function split(s, sep)
  if s == "" then
    return {}
  end
  return vim.split(s, sep, { plain = true })
end

local function flat_pairs(list)
  local out = {}
  for i = 1, #list - 1, 2 do
    out[#out + 1] = { list[i], list[i + 1] }
  end
  return out
end

local function kv_pairs(list, sep)
  local out = {}
  for _, item in ipairs(list) do
    local k, v = item:match("^([^" .. sep .. "]*)" .. sep .. "(.*)$")
    out[#out + 1] = { k or item, v or "" }
  end
  return out
end

---Deserialize a "simple"-style string (path, header) of schema type `t`.
function Api:simple(s, explode, schema, doc, t)
  if t == "array" then
    return self:list_of(split(s, ","), schema, doc)
  elseif t == "object" then
    if explode then
      return self:object_of(kv_pairs(split(s, ","), "="), schema, doc)
    end
    return self:object_of(flat_pairs(split(s, ",")), schema, doc)
  end
  return self:coerce(s, schema, doc)
end

---The value of path parameter `p` from its raw (still escaped) segment.
function Api:path_value(raw, style, explode, schema, doc, t, name)
  if style == "label" then
    if raw:sub(1, 1) ~= "." then
      bad(400, "path parameter %s: expected a label (.value)", name)
    end
    local body = unescape(raw:sub(2))
    if t == "array" then
      return self:list_of(split(body, explode and "." or ","), schema, doc)
    elseif t == "object" then
      if explode then
        return self:object_of(kv_pairs(split(body, "."), "="), schema, doc)
      end
      return self:object_of(flat_pairs(split(body, ",")), schema, doc)
    end
    return self:coerce(body, schema, doc)
  elseif style == "matrix" then
    if raw:sub(1, 1) ~= ";" then
      bad(400, "path parameter %s: expected matrix parameters (;name=value)", name)
    end
    local parts = split(raw:sub(2), ";")
    if t == "object" and explode then
      local pairs_ = {}
      for _, part in ipairs(parts) do
        local k, v = part:match("^([^=]*)=?(.*)$")
        pairs_[#pairs_ + 1] = { unescape(k), unescape(v) }
      end
      return self:object_of(pairs_, schema, doc)
    end
    local values = {}
    for _, part in ipairs(parts) do
      local k, v = part:match("^([^=]*)=?(.*)$")
      if unescape(k) == name then
        values[#values + 1] = unescape(v)
      end
    end
    if t == "array" then
      if explode then
        return self:list_of(values, schema, doc)
      end
      return self:list_of(split(values[1] or "", ","), schema, doc)
    elseif t == "object" then
      return self:object_of(flat_pairs(split(values[1] or "", ",")), schema, doc)
    end
    return self:coerce(values[1] or "", schema, doc)
  end
  -- simple (default)
  if t == "array" or t == "object" then
    -- Escaped commas stay values, so split before decoding.
    local parts = split(raw, ",")
    for i, p in ipairs(parts) do
      parts[i] = unescape(p)
    end
    if t == "array" then
      return self:list_of(parts, schema, doc)
    end
    if explode then
      return self:object_of(kv_pairs(parts, "="), schema, doc)
    end
    return self:object_of(flat_pairs(parts), schema, doc)
  end
  return self:coerce(unescape(raw), schema, doc)
end

---Query parameter `p` (a "form", "spaceDelimited", "pipeDelimited" or "deepObject" value)
---from the query pairs; nil when absent.
function Api:query_value(pairs_, name, style, explode, schema, doc, t, allow_empty, used)
  if style == "deepObject" then
    local out, found = map.new(), false
    for i, kv in ipairs(pairs_) do
      local prop = kv[1]:match("^" .. lua_pattern(name) .. "%[([^%]]*)%]$")
      if prop then
        found = true
        used[i] = true
        local ps, pdoc = self:prop_schema(schema, doc, prop)
        map.set(out, prop, self:coerce(kv[2], ps, pdoc))
      end
    end
    return found and out or nil
  end
  if t == "object" and explode and style == "form" then
    -- Each property is a query parameter of its own (those the schema names, or all the
    -- others when it allows additional properties).
    local _, s = self:schema_type(schema, doc)
    local out, found = map.new(), false
    for i, kv in ipairs(pairs_) do
      local named = is_map(s) and is_map(s.properties) and s.properties[kv[1]] ~= nil
      local extra = is_map(s) and s.additionalProperties ~= nil and s.additionalProperties ~= false
      if named or extra then
        found = true
        used[i] = true
        local ps, pdoc = self:prop_schema(schema, doc, kv[1])
        map.set(out, kv[1], self:coerce(kv[2], ps, pdoc))
      end
    end
    return found and out or nil
  end
  local values = {}
  for i, kv in ipairs(pairs_) do
    if kv[1] == name then
      used[i] = true
      if kv[2] == "" and not allow_empty and t ~= "string" and t ~= "array" then
        bad(400, "query parameter %s: an empty value is not allowed", name)
      end
      values[#values + 1] = kv[2]
    end
  end
  if #values == 0 then
    return nil
  end
  local sep = style == "spaceDelimited" and " " or style == "pipeDelimited" and "|" or ","
  if t == "array" then
    if explode then
      return self:list_of(values, schema, doc)
    end
    return self:list_of(split(values[1], sep), schema, doc)
  elseif t == "object" then
    return self:object_of(flat_pairs(split(values[1], sep)), schema, doc)
  end
  return self:coerce(values[1], schema, doc)
end

local DEFAULT_STYLE = { query = "form", path = "simple", header = "simple", cookie = "form" }
local VALID_STYLES = {
  query = { form = true, spaceDelimited = true, pipeDelimited = true, deepObject = true },
  path = { simple = true, label = true, matrix = true },
  header = { simple = true },
  cookie = { form = true },
}

---Deserialize and validate the operation's parameters. Returns { path = {...}, query =
---{...}, header = {...}, cookie = {...} } (mappings by name, defaults filled in); raises
---{ http_status = 400 } for missing or invalid ones.
---@param req { query: string?, headers: table }
function Api:parameters(op, req, path_raw)
  local out = { path = map.new(), query = map.new(), header = map.new(), cookie = map.new() }
  local qpairs = M.query_pairs(req.query)
  local cookies = M.cookies(req.headers.cookie)
  local used = {}
  for _, entry in ipairs(op.params) do
    local p, doc = entry.p, entry.doc
    local name, where = p.name, p["in"]
    local style = p.style or DEFAULT_STYLE[where]
    if not VALID_STYLES[where][style] then
      cfg_error("%s: parameter %s: style %s is not allowed in %s", op.id, name, tostring(style), where)
    end
    local explode = p.explode
    if explode == nil then
      explode = style == "form"
    end
    local schema, sdoc = p.schema, doc
    local value
    if p.content ~= nil then
      -- A parameter described by a media type (e.g. JSON in a query parameter).
      local raw
      if where == "query" then
        for i, kv in ipairs(qpairs) do
          if kv[1] == name then
            raw, used[i] = kv[2], true
          end
        end
      elseif where == "path" then
        raw = path_raw[name] and unescape(path_raw[name])
      elseif where == "header" then
        raw = req.headers[name:lower()]
      else
        raw = cookies[name]
      end
      for mt, media in map.pairs(p.content) do
        local m, mdoc = self:deref(media, doc)
        schema, sdoc = m.schema, mdoc
        if raw ~= nil then
          if mt:find("json", 1, true) then
            local v, err = M.decode_json(raw)
            if v == nil and err then
              bad(400, "%s parameter %s: invalid JSON (%s)", where, name, err)
            end
            value = v
          else
            value = raw
          end
        end
        break
      end
    else
      local t = self:schema_type(schema, doc)
      if where == "query" then
        value = self:query_value(qpairs, name, style, explode, schema, doc, t, p.allowEmptyValue == true, used)
      elseif where == "path" then
        if path_raw[name] ~= nil then
          value = self:path_value(path_raw[name], style, explode, schema, doc, t, name)
        end
      elseif where == "header" then
        local h = req.headers[name:lower()]
        if h ~= nil then
          value = self:simple(h, explode, schema, doc, t)
        end
      else
        local c = cookies[name]
        if c ~= nil then
          if t == "array" then
            value = self:list_of(type(c) == "table" and c or split(c, ","), schema, doc)
          elseif t == "object" then
            value = self:object_of(flat_pairs(split(type(c) == "table" and c[1] or c, ",")), schema, doc)
          else
            value = self:coerce(type(c) == "table" and c[1] or c, schema, doc)
          end
        end
      end
    end
    if value == nil then
      local _, s = self:schema_type(schema, sdoc)
      if is_map(s) and s.default ~= nil then
        value = s.default
      elseif p.required == true or where == "path" then
        bad(400, "missing required %s parameter %s", where, name)
      end
    end
    if value ~= nil then
      if schema ~= nil then
        local e = self:validate(schema, value, sdoc)
        if e then
          bad(400, "%s parameter %s%s: %s", where, name, e.path ~= "/" and e.path or "", e.message)
        end
      end
      map.set(out[where], name, value)
    end
  end
  return out
end

-- Security ----------------------------------------------------------------------------------

---Constant-time string comparison.
local function same(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then
    return false
  end
  local bit = require("bit")
  local diff = #a == #b and 0 or 1
  for i = 1, math.max(#a, #b) do
    diff = bit.bor(diff, bit.bxor(a:byte(i) or 0, b:byte(i) or 0))
  end
  return diff == 0
end
M.same = same

---True when one of `tokens` (a string or a list) equals `given`.
local function any_token(tokens, given)
  local list = type(tokens) == "table" and tokens or { tokens }
  local ok = false
  for _, t in ipairs(list) do
    ok = same(tostring(t), given) or ok -- (no early exit)
  end
  return ok
end

---Check one scheme against the request.
function Api:scheme_ok(name, headers, cookies)
  local s = self.schemes[name]
  local tokens = self.tokens[name]
  if s.type == "http" then
    local auth = headers.authorization or ""
    local scheme, cred = auth:match("^(%S+)%s+(.+)$")
    local want = tostring(s.scheme):lower()
    if not scheme or scheme:lower() ~= want then
      return false
    end
    if want == "basic" then
      local ok, decoded = pcall(vim.base64.decode, vim.trim(cred))
      return ok and any_token(tokens, decoded)
    end
    return any_token(tokens, vim.trim(cred))
  end
  local given = s["in"] == "header" and headers[tostring(s.name):lower()] or cookies[tostring(s.name)]
  return type(given) == "string" and any_token(tokens, given)
end

---Does the request meet the operation's security? Returns true, or false and the
---WWW-Authenticate value to send.
function Api:authorize(op, headers)
  if #op.security == 0 then
    return true
  end
  local cookies = M.cookies(headers.cookie)
  local challenge
  for _, req in ipairs(op.security) do
    local all = true
    for name in map.pairs(req) do
      if not self:scheme_ok(name, headers, cookies) then
        all = false
      end
      local s = self.schemes[name]
      if not challenge and s.type == "http" then
        challenge = (tostring(s.scheme):lower() == "basic" and "Basic" or "Bearer") .. ' realm="dbdash"'
      end
    end
    if all then
      return true
    end
  end
  return false, challenge
end

-- Request bodies ----------------------------------------------------------------------------

local STREAM_TYPES = {
  ["application/x-ndjson"] = "json",
  ["application/jsonl"] = "json",
  ["application/json-seq"] = "json",
  ["text/plain"] = "text",
  ["text/csv"] = "text",
  ["text/event-stream"] = "text",
}

---How a media type turns into items: "stream-json", "stream-text", "json", "form",
---"multipart" or "raw".
function M.kind(media_type, extra_stream)
  local mt = media_type:lower()
  if STREAM_TYPES[mt] then
    return "stream-" .. STREAM_TYPES[mt]
  end
  for _, t in ipairs(extra_stream or {}) do
    if t:lower() == mt then
      return mt:find("json", 1, true) and "stream-json" or "stream-text"
    end
  end
  if mt == "application/json" or mt:match("%+json$") then
    return "json"
  elseif mt == "application/x-www-form-urlencoded" then
    return "form"
  elseif mt == "multipart/form-data" then
    return "multipart"
  end
  return "raw"
end

---The operation's media type for a Content-Type: the media type key, its object and
---document; or nil (415).
function Api:media(op, content_type)
  local body = op.body
  if not body or not is_map(body.content) then
    return nil
  end
  local ct = (content_type or ""):match("^%s*([^;%s]+)") or ""
  ct = ct:lower()
  local exact, wild, any
  for key, media in map.pairs(body.content) do
    local k = tostring(key):lower()
    if k == ct then
      exact = exact or { key, media }
    elseif k:match("/%*$") and ct:sub(1, #k - 1) == k:sub(1, -2) then
      wild = wild or { key, media }
    elseif k == "*/*" then
      any = any or { key, media }
    end
  end
  local hit = exact or wild or any
  if not hit then
    return nil
  end
  local m, mdoc = self:deref(hit[2], op.body_doc)
  return hit[1], m, mdoc, ct
end

---Parse a form body (application/x-www-form-urlencoded) per the media type's schema and
---encoding: a mapping.
function Api:form(text, media, doc)
  local schema = media.schema
  local pairs_ = M.query_pairs(text)
  local out = map.new()
  local seen = {}
  for _, kv in ipairs(pairs_) do
    seen[kv[1]] = seen[kv[1]] or {}
    table.insert(seen[kv[1]], kv[2])
  end
  for name, values in pairs(seen) do
    local ps, pdoc = self:prop_schema(schema, doc, name)
    local t = self:schema_type(ps, pdoc)
    local enc = is_map(media.encoding) and media.encoding[name] or nil
    local style = enc and enc.style or "form"
    local explode = enc and enc.explode
    if explode == nil then
      explode = style == "form"
    end
    if enc and enc.contentType and tostring(enc.contentType):find("json", 1, true) then
      local v, err = M.decode_json(values[1])
      if v == nil and err then
        bad(400, "form field %s: invalid JSON (%s)", name, err)
      end
      map.set(out, name, v)
    elseif t == "array" then
      if explode then
        map.set(out, name, self:list_of(values, ps, pdoc))
      else
        local sep = style == "spaceDelimited" and " " or style == "pipeDelimited" and "|" or ","
        map.set(out, name, self:list_of(split(values[1], sep), ps, pdoc))
      end
    else
      map.set(out, name, self:coerce(values[1], ps, pdoc))
    end
  end
  return out
end

---Parse a multipart/form-data body: a mapping of field values (files as their content).
function Api:multipart(text, content_type, media, doc)
  local boundary = content_type:match('boundary="([^"]+)"') or content_type:match("boundary=([^;%s]+)")
  if not boundary then
    bad(400, "multipart body without a boundary")
  end
  local schema = media.schema
  local out = map.new()
  local delim = "--" .. boundary
  local pos = text:find(delim, 1, true)
  if not pos then
    bad(400, "malformed multipart body")
  end
  local fields = {}
  while true do
    pos = pos + #delim
    if text:sub(pos, pos + 1) == "--" then
      break
    end
    local head_end = text:find("\r\n\r\n", pos, true)
    local next_delim = text:find("\r\n" .. delim, pos, true)
    if not head_end or not next_delim then
      bad(400, "malformed multipart body")
    end
    local head = text:sub(pos, head_end - 1)
    local value = text:sub(head_end + 4, next_delim - 1)
    local name = head:match('[Nn]ame="([^"]*)"')
    local ctype = head:match("\n[Cc]ontent%-[Tt]ype:%s*([^\r\n;]+)")
    if name then
      fields[#fields + 1] = { name = name, value = value, ctype = ctype }
    end
    pos = next_delim + 2
  end
  local grouped, order = {}, {}
  for _, f in ipairs(fields) do
    if not grouped[f.name] then
      grouped[f.name] = {}
      order[#order + 1] = f.name
    end
    table.insert(grouped[f.name], f)
  end
  for _, name in ipairs(order) do
    local list = grouped[name]
    local ps, pdoc = self:prop_schema(schema, doc, name)
    local t = self:schema_type(ps, pdoc)
    local enc = is_map(media.encoding) and media.encoding[name] or nil
    local function value_of(f)
      local ct = (enc and enc.contentType) or f.ctype
      if ct and tostring(ct):find("json", 1, true) then
        local v, err = M.decode_json(f.value)
        if v == nil and err then
          bad(400, "multipart field %s: invalid JSON (%s)", name, err)
        end
        return v
      end
      return f.value
    end
    if t == "array" then
      local is, idoc = self:items_schema(ps, pdoc)
      local vals = {}
      for i, f in ipairs(list) do
        local v = value_of(f)
        vals[i] = type(v) == "string" and self:coerce(v, is, idoc) or v
      end
      map.set(out, name, vals)
    else
      local v = value_of(list[1])
      map.set(out, name, type(v) == "string" and self:coerce(v, ps, pdoc) or v)
    end
  end
  return out
end

return M
