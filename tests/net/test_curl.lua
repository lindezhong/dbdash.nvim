-- curl commands as request descriptions (net/curl.lua): shell words, options, errors.
local curl = require("dbdash.net.curl")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function err(text, base_dir)
  local ok, e = pcall(curl.parse, text, base_dir)
  eq(ok, false)
  return e.message
end

T["words: quotes, $'..', escapes, line continuations, comments"] = function()
  eq(curl.words([[curl 'a b' "c \"d\" \$e" f\ g]]), { "curl", "a b", 'c "d" $e', "f g" })
  eq(curl.words("curl $'x\\ny\\t\\'z\\x41\\u00e9'"), { "curl", "x\ny\t'zAé" })
  eq(curl.words("curl -H 'A: 1' \\\n  -H 'B: 2'"), { "curl", "-H", "A: 1", "-H", "B: 2" })
  eq(curl.words("curl /x # a comment\n  -L"), { "curl", "/x", "-L" })
  eq(curl.words("a'b'\"c\"d"), { "abcd" }) -- adjacent quoted pieces are one word
  eq(curl.words("x ''"), { "x", "" }) -- an empty quoted word stays
  eq(curl.words("{% if x %}"), { "{%", "if", "x", "%}" }) -- no special meaning
end

T["the URL is a path; the leading curl is optional"] = function()
  eq(curl.parse("curl /items").url, "/items")
  eq(curl.parse("/items").url, "/items")
  eq(curl.parse("curl").url, nil) -- database.url itself
  eq(curl.parse("curl --url '/a?b=1'").url, "/a?b=1")
  eq(curl.parse("curl").method, "GET")
end

T["methods, headers, data, --json, -G"] = function()
  local r = curl.parse("curl -XPOST /s -H 'X-A: 1' -H 'X-B:2'")
  eq({ r.method, r.headers }, { "POST", { { "X-A", "1" }, { "X-B", "2" } } })
  r = curl.parse("curl /s -d a=1 --data b=2 --data-raw '@c'")
  eq({ r.method, r.body }, { "POST", "a=1&b=2&@c" })
  r = curl.parse("curl /s --data-urlencode 'q=a b&c' --data-urlencode =x/y --data-urlencode plain")
  eq(r.body, "q=a%20b%26c&x%2Fy&plain")
  r = curl.parse([[curl /s --json '{"a": 1}' --json ', "b": 2}']])
  eq(r.body, '{"a": 1}, "b": 2}') -- --json pieces are joined as they are
  eq(
    { r.headers[1], r.headers[2] },
    { { "Content-Type", "application/json" }, { "Accept", "application/json" } }
  )
  r = curl.parse("curl /s --json '{}' -H 'Content-Type: application/vnd.x+json'")
  eq(#r.headers, 2) -- the given Content-Type stays, Accept is added
  r = curl.parse("curl /s -G -d a=1 -d b=2")
  eq({ r.method, r.query, r.body }, { "GET", "a=1&b=2", nil })
  eq(curl.parse("curl -I /s").method, "HEAD")
  eq(curl.parse("curl -X delete /s -d x").method, "DELETE")
end

T["@file data relative to the config's directory"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "a=1", "b=2" }, dir .. "/body.txt")
  eq(curl.parse("curl -d @body.txt /s", dir).body, "a=1b=2") -- -d drops newlines
  eq(curl.parse("curl --data-binary @body.txt /s", dir).body, "a=1\nb=2\n")
  eq(curl.parse("curl --data-urlencode name@body.txt /s", dir).body, "name=a%3D1%0Ab%3D2%0A")
  eq(
    err("curl -d @missing.txt", dir):find("cannot read the data file missing.txt", 1, true) ~= nil,
    true
  )
end

T["short options in clusters, values attached or next, --opt=value"] = function()
  local r = curl.parse("curl -sSLk -m 2.5 --connect-timeout=3 --max-redirs 4 /x")
  eq(
    { r.follow, r.insecure, r.timeout, r.connect_timeout, r.max_redirs },
    { true, true, 2500, 3000, 4 }
  )
  r = curl.parse("curl -Lu me:pw -A agent -e ref /x")
  eq({ r.user, r.headers }, { "me:pw", { { "User-Agent", "agent" }, { "Referer", "ref" } } })
  -- output options mean nothing here: accepted
  r = curl.parse(
    "curl -s -S -v -i -f -g --compressed --http1.1 --no-progress-meter --fail-with-body /x"
  )
  eq(r.url, "/x")
end

T["cookies: -b strings and files, -b '', -c, -j"] = function()
  local r = curl.parse("curl /x")
  eq(r.cookie_engine, false)
  r = curl.parse("curl -b 'a=1; b=2' -b jar.txt -b '' -c jar.txt -j /x")
  eq(
    { r.cookie_strings, r.cookie_files, r.cookie_jar, r.cookie_engine, r.junk_session },
    { { "a=1; b=2" }, { "jar.txt" }, "jar.txt", true, true }
  )
  eq(curl.parse("curl -b '' /x").cookie_engine, true)
end

T["errors: unsupported and unknown options, URLs, quotes"] = function()
  eq(
    err("curl -F a=1 /x"),
    "curl multipart forms (-F) are not supported; use -d or --data-urlencode"
  )
  eq(err("curl -o out.json /x"), "curl the response is the query's result: drop -o")
  eq(err("curl --proxy p /x"), "curl proxies (--proxy) are not supported")
  eq(err("curl -c - /x"):find("standard output", 1, true) ~= nil, true)
  eq(
    err("curl --frobnicate /x"),
    "curl option --frobnicate is not supported here (:help dbdash-http lists those that are)"
  )
  eq(
    err("curl -Q /x"),
    "curl option -Q is not supported here (:help dbdash-http lists those that are)"
  )
  eq(err("curl https://api.example.com/x"):find("write the path only", 1, true) ~= nil, true)
  eq(err("curl --url http://h/x"):find("write the path only", 1, true) ~= nil, true)
  eq(err("curl /a /b"), "curl: one URL per request (/a and /b)")
  eq(err("curl -H"), "curl -H needs a value")
  eq(err("curl -H nocolon"), [[curl -H needs 'Name: value', not "nocolon"]])
  eq(err("curl -m soon"), [[curl -m needs a number of seconds, not "soon"]])
  eq(err("curl 'open"), "the curl command has an unterminated ' quote")
  eq(err('curl "open'), 'the curl command has an unterminated " quote')
  eq(err("   \n  "), "the request is empty: write a curl command (curl alone GETs database.url)")
end

T["quote: any text back as one word"] = function()
  for _, s in ipairs({ "plain", "it's", "a b", "'", "", '$HOME `x` \\ "q"', "line\nbreak" }) do
    eq(curl.words("curl " .. curl.quote(s)), { "curl", s })
  end
end

return T
