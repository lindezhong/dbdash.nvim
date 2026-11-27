-- http(s):// queries against a local HTTP server in this process, and the cookie jar.
local h = require("tests.helpers")
local cookie = require("dbdash.net.http_cookie")
local http = require("dbdash.net.http")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = { post_case = h.close_http_servers } })
local server = h.http_server

local function response(status, headers, body)
  local lines = { "HTTP/1.1 " .. status }
  for _, hdr in ipairs(headers or {}) do
    lines[#lines + 1] = hdr
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")
end

local function json(body, extra)
  return response(
    "200 OK",
    vim.list_extend({ "Content-Type: application/json", "Content-Length: " .. #body }, extra or {}),
    body
  )
end

T["a JSON list of records is rows without a transform"] = function()
  local base, seen = server(function()
    return json('[{"name":"a","n":1},{"name":"b","n":null}]')
  end)
  local rs = h.ok(base .. "/v1/items", "curl")
  eq({ rs.columns[1].name, rs.columns[2].name }, { "n", "name" })
  eq(rs.rows, { { 1, "a" }, { vim.NIL, "b" } })
  eq(
    { seen[1].method, seen[1].target, seen[1].headers.host },
    { "GET", "/v1/items", base:match("//(.*)") }
  )
end

T["other shapes need query.transform; the raw value keeps the response"] = function()
  local base = server(function()
    return json('{"data":{"items":[{"k":"x","v":2}]}}', { "X-Total: 1" })
  end)
  local r = h.query(base, "curl")
  eq(r.err.phase, "query")
  eq(
    r.err.message,
    "the result is an object (data), not rows; add query.transform to reshape it (:help dbdash-transform)"
  )
  local raw = h.ok(base, "curl", { raw = true }) ---@type any (a raw result)
  eq(require("dbdash.db.lua_result").is_raw(raw), true)
  eq(raw.value.data.items[1].k, "x")
  eq({ raw.vars.response.status, raw.vars.response.headers["x-total"] }, { 200, "1" })
  -- text responses stay strings
  base = server(function()
    return response("200 OK", { "Content-Type: text/plain", "Content-Length: 5" }, "hello")
  end)
  eq((h.ok(base, "curl", { raw = true }) --[[@as any]]).value, "hello")
  eq(
    h.query(base, "curl").err.message
      :find("the result is not rows (got string); add query.transform", 1, true) ~= nil,
    true
  )
end

T["curl: method, path, query, headers, JSON body, form, -G, -u"] = function()
  local base, seen = server(function()
    return json("[]")
  end)
  h.ok(
    base .. "/api/v1?key=k%201&tls=disable",
    [[
    curl '/search?x=1&limit=5&tag=a&tag=b%20c' \
      -H 'X-Token: t' \
      --json '{"q": "neovim"}'
  ]]
  )
  local r = seen[1]
  eq({ r.method, r.target }, { "POST", "/api/v1/search?key=k%201&x=1&limit=5&tag=a&tag=b%20c" })
  eq(
    { r.headers["x-token"], r.headers["content-type"], r.headers.accept, vim.json.decode(r.body) },
    { "t", "application/json", "application/json", { q = "neovim" } }
  )
  -- -d: a form by default, as curl; -X sets the method
  h.ok(base .. "/api", "curl -X put /abs -d 'a=1%262'")
  eq({ seen[2].method, seen[2].target, seen[2].body }, { "PUT", "/api/abs", "a=1%262" })
  eq(seen[2].headers["content-type"], "application/x-www-form-urlencoded")
  -- a body of its own type
  h.ok(base, "curl -H 'Content-Type: text/csv' --data-binary 'raw text'")
  eq(
    { seen[3].method, seen[3].body, seen[3].headers["content-type"] },
    { "POST", "raw text", "text/csv" }
  )
  -- -G: the data goes to the query string
  h.ok(base, "curl /s -G --data-urlencode 'q=a b' -d n=1")
  eq({ seen[4].method, seen[4].target, seen[4].body }, { "GET", "/s?q=a%20b&n=1", "" })
  -- -u: Basic auth over the URL's account
  h.ok(base:gsub("^http://", "http://x:y@"), "curl -u 'me:p w'")
  eq(seen[5].headers.authorization, "Basic " .. vim.base64.encode("me:p w"))
end

T["bad curl commands and JSON requests are query errors"] = function()
  local base = server(function()
    return json("[]")
  end)
  local function err(cmd)
    return h.query(base, cmd).err.message
  end
  eq(err('{"path": "/x"}'):find("the request is a curl command, not JSON", 1, true) ~= nil, true)
  eq(
    err("curl --hedaer 'X: 1'"):find("curl option --hedaer is not supported", 1, true) ~= nil,
    true
  )
  eq(err("curl -F a=@x.csv /up"):find("multipart", 1, true) ~= nil, true)
  eq(err("curl /a /b"), "curl: one URL per request (/a and /b)")
  eq(err("   "), "the request is empty: write a curl command (curl alone GETs database.url)")
  eq(err("curl 'unterminated"), "the curl command has an unterminated ' quote")
end

T["bodies: chunked, close-delimited, slow chunks, 1xx first"] = function()
  local base = server(function()
    return {
      "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n",
      'Transfer-Encoding: chunked\r\n\r\n5\r\n[{"a"\r\n',
      '6;ext=1\r\n: 1},{\r\n7\r\n"a": 2}\r\n1\r\n]\r\n0\r\nX-Trailer: y\r\n\r\n',
    }
  end)
  eq(h.ok(base, "curl").rows, { { 1 }, { 2 } })
  base = server(function()
    return { 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n[{"a":', "3}]" }
  end)
  eq(h.ok(base, "curl").rows, { { 3 } })
end

T["errors: HTTP status, auth status, invalid JSON, compressed"] = function()
  local base = server(function(req)
    if req.target == "/missing" then
      return response("404 Not Found", { "Content-Length: 10" }, "no\nsuch  x")
    elseif req.target == "/secret" then
      return response("401 Unauthorized", { "Content-Length: 0" })
    elseif req.target == "/gz" then
      return response("200 OK", { "Content-Encoding: gzip", "Content-Length: 2" }, "xx")
    end
    return json("[{")
  end)
  local e = assert(h.query(base .. "/missing", "curl").err)
  eq(
    { e.phase, e.message },
    { "query", "HTTP 404 Not Found from " .. base .. "/missing: no such x" }
  )
  eq(h.query(base .. "/secret", "curl").err.phase, "auth")
  eq(
    h.query(base .. "/bad", "curl").err.message:find("the response is not valid JSON", 1, true)
      ~= nil,
    true
  )
  -- Errors name the URL (the URL's path and the request's joined).
  eq(
    h.query(base .. "/gz", "curl").err.message,
    "compressed responses (gzip) are not supported (" .. base .. "/gz)"
  )
end

T["Basic auth from the URL; redirects keep it on the same host only"] = function()
  local other, seen_other = server(function()
    return json('[{"where":"other"}]')
  end)
  local base, seen = server(function(req)
    if req.target == "/start" then
      return response("302 Found", { "Location: /next?a=1", "Content-Length: 0" })
    elseif req.target == "/next?a=1" then
      return response(
        "307 Temporary Redirect",
        { "Location: " .. other .. "/final", "Content-Length: 0" }
      )
    end
    return json("[]")
  end)
  local authed = base:gsub("^http://", "http://us%%40er:p%%3Aw@")
  local rs = h.ok(authed .. "/start", "curl -L")
  eq(rs.rows, { { "other" } })
  eq(seen[1].headers.authorization, "Basic " .. vim.base64.encode("us@er:p:w"))
  eq(seen[2].headers.authorization ~= nil, true)
  eq(seen_other[1].headers.authorization, nil) -- another host
  eq(seen_other[1].target, "/final")
  -- 303 turns a POST into a GET without the body
  local b2, seen2 = server(function(req)
    if req.method == "POST" then
      return response("303 See Other", { "Location: /done", "Content-Length: 0" })
    end
    return json("[]")
  end)
  h.ok(b2, [[curl --json '{"x": 1}' -L]])
  eq({ seen2[2].method, seen2[2].body, seen2[2].headers["content-type"] }, { "GET", "", nil })
end

T["redirects: followed with -L only; --max-redirs"] = function()
  local base = server(function()
    return response("302 Found", { "Location: /again", "Content-Length: 0" })
  end)
  -- as curl: not followed
  eq(h.query(base, "curl").err.message:find("^HTTP 302 Found") ~= nil, true)
  eq(
    h.query(base, "curl -L --max-redirs 3").err.message,
    "too many redirects (more than 3) (" .. base .. "/)"
  )
end

T["cookies: curl's engine (-b strings and files, -b '', -c files, -j)"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local base, seen = server(function(req)
    if req.target == "/login" then
      return response(
        "302 Found",
        { "Location: /me", "Set-Cookie: session=new; Path=/; HttpOnly", "Content-Length: 0" }
      )
    end
    return json("[]", { "Set-Cookie: seen=1; Path=/" })
  end)
  local host = base:match("//([^:]+)")
  local opts = { base_dir = dir, allow_writes = true }
  -- no -b / -c: the engine is off, nothing is kept, not even across the redirect
  h.ok(base .. "/login", "curl -L", opts)
  eq({ seen[1].headers.cookie, seen[2].headers.cookie }, { nil, nil })
  -- -b '': the engine is on for this request: the redirect carries the new cookie
  h.ok(base .. "/login", "curl -L -b ''", opts)
  eq(seen[4].headers.cookie, "session=new")
  -- -b "a=1; b=2" is sent; the next request knows nothing of what the server set
  h.ok(base, "curl -b 'session=old; lang=zh'", opts)
  eq(seen[5].headers.cookie, "session=old; lang=zh")
  h.ok(base, "curl -b 'lang=zh'", opts)
  eq(seen[6].headers.cookie, "lang=zh")
  -- a Netscape file (relative to the config's directory); a missing one has no cookies
  local lines = {
    "# Netscape HTTP Cookie File",
    "#HttpOnly_" .. host .. "\tFALSE\t/\tFALSE\t0\tfromfile\tf1",
    host .. "\tFALSE\t/other\tFALSE\t0\telsewhere\tz",
    host .. "\tFALSE\t/\tTRUE\t0\tsecureonly\ts",
    host .. "\tFALSE\t/\tFALSE\t1\texpired\te",
    host .. "\tFALSE\t/\tFALSE\t4102444800\tlasting\tl",
  }
  vim.fn.writefile(lines, dir .. "/in.txt")
  h.ok(base, "curl -b in.txt", opts)
  eq(seen[7].headers.cookie, "fromfile=f1; lasting=l")
  h.ok(base, "curl -b in.txt -j", opts) -- -j: no session cookies
  eq(seen[8].headers.cookie, "lasting=l")
  h.ok(base, "curl -b missing.txt", opts)
  eq(seen[9].headers.cookie, nil)
  eq(vim.fn.readfile(dir .. "/in.txt"), lines) -- -b files are only read
  -- -b jar -c jar: what the server sets is written, and sent by the next refresh
  h.ok(base .. "/login", "curl -L -b jar.txt -c jar.txt", opts)
  local jar = table.concat(vim.fn.readfile(dir .. "/jar.txt"), "\n")
  eq(jar:find("# Netscape HTTP Cookie File", 1, true) == 1, true)
  eq(jar:find("#HttpOnly_" .. host .. "\tFALSE\t/\tFALSE\t0\tsession\tnew", 1, true) ~= nil, true)
  eq(jar:find(host .. "\tFALSE\t/\tFALSE\t0\tseen\t1", 1, true) ~= nil, true)
  if vim.fn.has("win32") == 0 then
    eq(vim.fn.getfperm(dir .. "/jar.txt"), "rw-------")
  end
  h.ok(base, "curl -b jar.txt -c jar.txt -b 'session=old'", opts)
  eq(seen[#seen].headers.cookie, "session=new; seen=1") -- the jar's value wins
end

T["cookies: curl -c is written only in the config's directory, for trusted configs"] = function()
  local base = server(function()
    return json("[]")
  end)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function err(cmd, allow)
    return h.query(base, cmd, { base_dir = dir, allow_writes = allow ~= false }).err.message
  end
  eq(err("curl -c /tmp/x.txt"):find("must be a relative path", 1, true) ~= nil, true)
  eq(err("curl -c ../x.txt"):find("no ..", 1, true) ~= nil, true)
  eq(err("curl -c -"):find("standard output", 1, true) ~= nil, true)
  eq(err("curl -c jar.txt", false):find("so the config is trusted for it", 1, true) ~= nil, true)
  eq(require("dbdash.trust").curl_writes("curl -Lc jar.txt /x"), true)
  eq(require("dbdash.trust").curl_writes("curl --cookie-jar=j /x"), true)
  eq(require("dbdash.trust").curl_writes("curl -b j /x -d 'a=-c'"), false)
end

T["cookie jar: domain, path, secure, expiry, deletion"] = function()
  local jar = cookie.new()
  local u = function(s)
    return http.parse_url(s)
  end
  local now = 1700000000
  jar:store({
    "a=1; Domain=example.com; Path=/",
    "b=2; Path=/app",
    "c=3; Secure",
    "d=4; Max-Age=60",
    "e=5; Expires=Wed, 21 Oct 2015 07:28:00 GMT", -- in the past: not stored
    "evil=1; Domain=other.com",
  }, u("http://www.example.com/app/x"), now)
  eq(jar:header(u("http://api.example.com/"), nil, now), "a=1")
  -- d: default path /app
  eq(jar:header(u("http://www.example.com/app/y"), nil, now), "b=2; d=4; a=1")
  eq(jar:header(u("https://www.example.com/app/y"), nil, now), "b=2; c=3; d=4; a=1")
  eq(jar:header(u("http://www.example.com/application"), nil, now), "a=1") -- not under /app
  eq(jar:header(u("http://www.example.com/app/"), nil, now + 61), "b=2; a=1")
  jar:store({ "a=; Domain=example.com; Path=/; Max-Age=0" }, u("http://www.example.com/"), now)
  eq(jar:header(u("http://www.example.com/app/z"), nil, now), "b=2; d=4")
  eq(cookie.parse_date("Wed, 21 Oct 2015 07:28:00 GMT"), 1445412480)
  eq(cookie.parse_date("Sunday, 06-Nov-94 08:49:37 GMT"), 784111777)
end

T["URLs: resolve redirects, encode"] = function()
  local base = http.parse_url("https://h.example:8443/a/b?x=1")
  eq(
    { base.scheme, base.host, base.port, base.path, base.query },
    { "https", "h.example", 8443, "/a/b", "x=1" }
  )
  eq(http.format_url(http.resolve(base, "c?y=2")), "https://h.example:8443/a/c?y=2")
  eq(http.format_url(http.resolve(base, "/z")), "https://h.example:8443/z")
  eq(http.format_url(http.resolve(base, "//cdn.example/p")), "https://cdn.example/p")
  eq(http.format_url(http.resolve(base, "http://o.example/")), "http://o.example/")
  eq(http.encode_pairs({ b = "x y", a = { 1, 2 } }), "a=1&a=2&b=x%20y")
end

T["http:// cannot use tls; https:// defaults to verify-full"] = function()
  eq(
    h.query("http://127.0.0.1:1/?tls=require", "curl").err.message,
    "http:// URLs cannot use tls (use https://)"
  )
  local info = require("dbdash.db.url").parse("https://api.example.com/v1?tls=require&key=1")
  info = require("dbdash.db.drivers.http").parse_url(info)
  eq({ info.tls, info.base_path, info.base_query }, { "require", "/v1", "key=1" })
  info = require("dbdash.db.drivers.http").parse_url(
    require("dbdash.db.url").parse("https://api.example.com")
  )
  eq({ info.tls, info.base_path, info.base_query }, { "verify-full", "", nil })
  eq(info.port, 443)
  eq(require("dbdash.db.credentials").keys(info)[1], "https://api.example.com:443")
end

T["path: the URL's path and the command's path are joined as they are"] = function()
  local base, seen = server(function()
    return json("[]")
  end)
  for _, c in ipairs({
    { "/v1", "/search", "/v1/search" },
    { "/v1", "search", "/v1search" }, -- no "/" added
    { "/v1/", "/search", "/v1//search" }, -- none removed
    { "", "/search", "/search" },
    { "/v1", "", "/v1" },
    { "", "", "/" },
  }) do
    h.ok(base .. c[1], "curl " .. require("dbdash.util.shell").quote(c[2]))
    eq({ c[1], c[2], seen[#seen].target }, { c[1], c[2], c[3] })
  end
  -- A full URL is refused: the host is database.url's.
  local e = assert(h.query(base .. "/v1", "curl http://other.example/x").err)
  eq(e.message:find("write the path only", 1, true) ~= nil, true)
end

return T
