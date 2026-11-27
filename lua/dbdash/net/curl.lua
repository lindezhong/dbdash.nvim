-- A curl command line as an HTTP request description (the query of http:// and https://
-- databases, :help dbdash-http). The URL is a path, joined to database.url.
--
--   curl -X POST /search -G --data-urlencode "q=neovim" -H 'Accept: application/json' \
--     -b .cookies.txt -c .cookies.txt --json '{"limit": 5}' -L
--
-- The words follow shell quoting (POSIX sh, as curl commands are written): '...' is
-- literal, "..." takes \" \\ \$ \` and a backslash-newline, $'...' takes C escapes
-- (\n \t \' \\ \xHH \uHHHH), a backslash outside quotes escapes the next character and a
-- backslash-newline continues the line; # starts a comment at the start of a word. No
-- variables, globs or command substitution: they are kept as written.
local M = {}

---@return any (it raises: `x or fail(...)` keeps x's type)
local function fail(msg, ...)
  require("dbdash.util.error").raise("query", msg:format(...), { kind = "value" })
end

local C_ESC = {
  n = "\n",
  t = "\t",
  r = "\r",
  a = "\a",
  b = "\b",
  e = "\27",
  E = "\27",
  f = "\f",
  v = "\v",
  ["\\"] = "\\",
  ["'"] = "'",
  ['"'] = '"',
  ["?"] = "?",
}

---Split a command line into words (shell quoting).
---@param text string
---@return string[]
function M.words(text)
  local words, cur, has = {}, {}, false
  local i, n = 1, #text
  local function push()
    if has then
      words[#words + 1] = table.concat(cur)
    end
    cur, has = {}, false
  end
  while i <= n do
    local c = text:sub(i, i)
    if c == "\\" then
      local d = text:sub(i + 1, i + 1)
      if d == "\n" then
        i = i + 2 -- line continuation
      elseif d == "\r" and text:sub(i + 2, i + 2) == "\n" then
        i = i + 3
      else
        cur[#cur + 1], has = d, true
        i = i + 2
      end
    elseif c:match("%s") then
      push()
      i = i + 1
    elseif c == "#" and not has then
      local e = text:find("\n", i, true) -- a comment to the end of the line
      i = e and e or n + 1
    elseif c == "'" then
      local e = text:find("'", i + 1, true)
      if not e then
        fail("the curl command has an unterminated ' quote")
      end
      cur[#cur + 1], has = text:sub(i + 1, e - 1), true
      i = e + 1
    elseif c == "$" and text:sub(i + 1, i + 1) == "'" then
      i = i + 2
      has = true
      while true do
        local ch = text:sub(i, i)
        if ch == "" then
          fail("the curl command has an unterminated $' quote")
        elseif ch == "'" then
          i = i + 1
          break
        elseif ch == "\\" then
          local d = text:sub(i + 1, i + 1)
          if d == "x" then
            local hex = text:match("^%x%x?", i + 2)
            cur[#cur + 1] = string.char(tonumber(hex or "0", 16))
            i = i + 2 + #(hex or "")
          elseif d == "u" or d == "U" then
            local hex = text:match(d == "u" and "^%x%x?%x?%x?" or "^%x%x?%x?%x?%x?%x?%x?%x?", i + 2)
            cur[#cur + 1] = vim.fn.nr2char(tonumber(hex or "0", 16))
            i = i + 2 + #(hex or "")
          elseif d:match("[0-7]") then
            local oct = text:match("^[0-7][0-7]?[0-7]?", i + 1)
            cur[#cur + 1] = string.char(tonumber(oct, 8) % 256)
            i = i + 1 + #oct
          else
            cur[#cur + 1] = C_ESC[d] or ("\\" .. d)
            i = i + 2
          end
        else
          cur[#cur + 1] = ch
          i = i + 1
        end
      end
    elseif c == '"' then
      i = i + 1
      has = true
      while true do
        local ch = text:sub(i, i)
        if ch == "" then
          fail('the curl command has an unterminated " quote')
        elseif ch == '"' then
          i = i + 1
          break
        elseif ch == "\\" and text:sub(i + 1, i + 1):match('["\\$`\n]') then
          local d = text:sub(i + 1, i + 1)
          if d ~= "\n" then
            cur[#cur + 1] = d
          end
          i = i + 2
        else
          cur[#cur + 1] = ch
          i = i + 1
        end
      end
    else
      cur[#cur + 1], has = c, true
      i = i + 1
    end
  end
  push()
  return words
end

-- Options: name -> { key, takes an argument? }; aliases share the key.
local OPTS = {
  ["-X"] = { "method", true },
  ["--request"] = { "method", true },
  ["-H"] = { "header", true },
  ["--header"] = { "header", true },
  ["-d"] = { "data", true },
  ["--data"] = { "data", true },
  ["--data-ascii"] = { "data", true },
  ["--data-binary"] = { "data_binary", true },
  ["--data-raw"] = { "data_raw", true },
  ["--data-urlencode"] = { "data_urlencode", true },
  ["--json"] = { "json", true },
  ["-G"] = { "get", false },
  ["--get"] = { "get", false },
  ["-b"] = { "cookie", true },
  ["--cookie"] = { "cookie", true },
  ["-c"] = { "cookie_jar", true },
  ["--cookie-jar"] = { "cookie_jar", true },
  ["-j"] = { "junk_session", false },
  ["--junk-session-cookies"] = { "junk_session", false },
  ["-u"] = { "user", true },
  ["--user"] = { "user", true },
  ["-A"] = { "agent", true },
  ["--user-agent"] = { "agent", true },
  ["-e"] = { "referer", true },
  ["--referer"] = { "referer", true },
  ["-L"] = { "location", false },
  ["--location"] = { "location", false },
  ["--max-redirs"] = { "max_redirs", true },
  ["-k"] = { "insecure", false },
  ["--insecure"] = { "insecure", false },
  ["-m"] = { "max_time", true },
  ["--max-time"] = { "max_time", true },
  ["--connect-timeout"] = { "connect_timeout", true },
  ["-I"] = { "head", false },
  ["--head"] = { "head", false },
  ["--url"] = { "url", true },
  -- output and transport options without a meaning here: accepted, ignored
  ["-s"] = { "ignore", false },
  ["--silent"] = { "ignore", false },
  ["-S"] = { "ignore", false },
  ["--show-error"] = { "ignore", false },
  ["-v"] = { "ignore", false },
  ["--verbose"] = { "ignore", false },
  ["-i"] = { "ignore", false },
  ["--include"] = { "ignore", false },
  ["-f"] = { "ignore", false },
  ["--fail"] = { "ignore", false },
  ["--fail-with-body"] = { "ignore", false },
  ["-g"] = { "ignore", false },
  ["--globoff"] = { "ignore", false },
  ["--compressed"] = { "ignore", false },
  ["--http1.1"] = { "ignore", false },
  ["--no-progress-meter"] = { "ignore", false },
  ["-#"] = { "ignore", false },
  ["--progress-bar"] = { "ignore", false },
}

-- Options curl has that a request here cannot honor: named in the error.
local UNSUPPORTED = {
  ["-F"] = "multipart forms (-F) are not supported; use -d or --data-urlencode",
  ["--form"] = "multipart forms (--form) are not supported; use -d or --data-urlencode",
  ["-o"] = "the response is the query's result: drop -o",
  ["--output"] = "the response is the query's result: drop --output",
  ["-O"] = "the response is the query's result: drop -O",
  ["-T"] = "uploads (-T) are not supported; use --data-binary @file",
  ["-x"] = "proxies (-x) are not supported",
  ["--proxy"] = "proxies (--proxy) are not supported",
}

local function seconds(v, opt)
  local s = tonumber(v)
  if not s or s < 0 then
    fail("curl %s needs a number of seconds, not %q", opt, v)
  end
  return math.floor(s * 1000)
end

---Read `@file` (relative to `base_dir`); `strip`: drop CR and LF (-d does).
local function file_data(name, base_dir, strip)
  local path = name
  if not path:match("^/") and not path:match("^%a:[/\\]") and base_dir then
    path = base_dir .. "/" .. path
  end
  local f = io.open(path, "rb") or fail("curl: cannot read the data file %s", name)
  local s = f:read("*a")
  f:close()
  return strip and (s:gsub("[\r\n]", "")) or s
end

local urlencode = require("dbdash.util.url").encode

---curl --data-urlencode: content, =content, name=content, @file, name@file.
local function data_urlencode(v, base_dir)
  local name, content = v:match("^([^=@]*)=(.*)$")
  if name then
    return name == "" and urlencode(content) or (name .. "=" .. urlencode(content))
  end
  local fname, file = v:match("^([^=@]*)@(.*)$")
  if fname then
    local s = urlencode(file_data(file, base_dir, false))
    return fname == "" and s or (fname .. "=" .. s)
  end
  return urlencode(v)
end

---@class dbdash.curl.Request
---@field method string?
---@field url string? the URL argument as written (a path, or a full URL)
---@field headers { [1]: string, [2]: string }[] name, value in order
---@field body string?
---@field query string? data moved to the URL by -G
---@field cookie_strings string[] -b values with "=" (sent as they are)
---@field cookie_files string[] -b values without "=" (Netscape cookie files)
---@field cookie_jar string? -c: the file the cookies are written to after the request
---@field cookie_engine boolean -b or -c given: cookies the server sets are used (redirects)
---@field junk_session boolean -j: session cookies of -b files are dropped
---@field user string? user:password
---@field follow boolean -L
---@field max_redirs integer?
---@field insecure boolean -k
---@field timeout integer? ms (-m)
---@field connect_timeout integer? ms

local NO_URL =
  "curl: write the path only (e.g. /search): the scheme, host and port are database.url's, not %s"

---Data of -d, --data-binary, --data-raw, --data-urlencode.
local function add_data(p, v)
  p.data[#p.data + 1] = v
  p.has_data = true
end

---What each option does to the request being parsed (`p`: { r, data, json, get, head,
---has_data, base_dir }).
local APPLY = {
  method = function(p, v)
    p.r.method = v:upper()
  end,
  header = function(p, v, opt)
    local name, value = v:match("^([^:]+):%s*(.*)$")
    if not name then
      fail("curl %s needs 'Name: value', not %q", opt, v)
    end
    p.r.headers[#p.r.headers + 1] = { vim.trim(name), value }
  end,
  data = function(p, v)
    add_data(p, v:sub(1, 1) == "@" and file_data(v:sub(2), p.base_dir, true) or v)
  end,
  data_binary = function(p, v)
    add_data(p, v:sub(1, 1) == "@" and file_data(v:sub(2), p.base_dir, false) or v)
  end,
  data_raw = add_data,
  data_urlencode = function(p, v)
    add_data(p, data_urlencode(v, p.base_dir))
  end,
  json = function(p, v)
    p.json[#p.json + 1] = v:sub(1, 1) == "@" and file_data(v:sub(2), p.base_dir, false) or v
    p.has_data = true
  end,
  get = function(p)
    p.get = true
  end,
  head = function(p)
    p.head = true
  end,
  -- as curl: a value with "=" is cookies, else a file to read; either starts the cookie
  -- engine (-b '' only starts it)
  cookie = function(p, v)
    local r = p.r
    r.cookie_engine = true
    if v:find("=", 1, true) then
      r.cookie_strings[#r.cookie_strings + 1] = v
    elseif v ~= "" then
      r.cookie_files[#r.cookie_files + 1] = v
    end
  end,
  cookie_jar = function(p, v)
    if v == "-" then
      fail("curl -c - writes to the standard output, which has no meaning here: give a file")
    end
    p.r.cookie_jar, p.r.cookie_engine = v, true
  end,
  junk_session = function(p)
    p.r.junk_session = true
  end,
  user = function(p, v)
    p.r.user = v
  end,
  agent = function(p, v)
    p.r.headers[#p.r.headers + 1] = { "User-Agent", v }
  end,
  referer = function(p, v)
    p.r.headers[#p.r.headers + 1] = { "Referer", v }
  end,
  location = function(p)
    p.r.follow = true
  end,
  max_redirs = function(p, v)
    p.r.max_redirs = tonumber(v) or fail("curl --max-redirs needs a number, not %q", v)
  end,
  insecure = function(p)
    p.r.insecure = true
  end,
  max_time = function(p, v, opt)
    p.r.timeout = seconds(v, opt)
  end,
  connect_timeout = function(p, v, opt)
    p.r.connect_timeout = seconds(v, opt)
  end,
  ignore = function() end, -- -s, -S, -v ...: about curl's own output
  url = function(p, v)
    if v:match("^%a[%w+.-]*://") then
      fail(NO_URL, v)
    end
    if p.r.url then
      fail("curl: one URL per request (%s and %s)", p.r.url, v)
    end
    p.r.url = v
  end,
}

---The definition of option `opt`, or an error.
local function option(opt)
  if UNSUPPORTED[opt] then
    fail("curl %s", UNSUPPORTED[opt])
  end
  local def = OPTS[opt]
  if not def then
    fail("curl option %s is not supported here (:help dbdash-http lists those that are)", opt)
  end
  return def
end

---The value of option `opt`: the next word.
local function next_word(p, opt)
  p.i = p.i + 1
  local v = p.words[p.i]
  if v == nil then
    fail("curl %s needs a value", opt)
  end
  return v
end

---A long option (--name value, --name=value, --flag).
local function long_option(p, w)
  local name, value = w:match("^(%-%-[^=]+)=(.*)$")
  name = name or w
  local def = option(name)
  APPLY[def[1]](p, def[2] and (value or next_word(p, name)) or nil, name)
end

---Short options: clustered flags (-sSL), the last one may take the rest or the next word
---as its value (-XPOST, -H 'a: b').
local function short_options(p, w)
  local k = 2
  while k <= #w do
    local opt = "-" .. w:sub(k, k)
    local def = option(opt)
    if def[2] then
      local rest = w:sub(k + 1)
      APPLY[def[1]](p, rest ~= "" and rest or next_word(p, opt), opt)
      return
    end
    APPLY[def[1]](p, nil, opt)
    k = k + 1
  end
end

-----json: the data as is, sent and accepted as JSON (unless the headers say otherwise).
local function json_data(p)
  local r = p.r
  p.data[#p.data + 1] = table.concat(p.json)
  local function has(name)
    for _, h in ipairs(r.headers) do
      if h[1]:lower() == name then
        return true
      end
    end
  end
  if not has("content-type") then
    r.headers[#r.headers + 1] = { "Content-Type", "application/json" }
  end
  if not has("accept") then
    r.headers[#r.headers + 1] = { "Accept", "application/json" }
  end
end

---Parse a curl command (the leading word `curl` is optional).
---@param text string
---@param base_dir string? where @file and cookie files are read
---@return dbdash.curl.Request
function M.parse(text, base_dir)
  local words = M.words(text)
  if #words == 0 then
    fail("the request is empty: write a curl command (curl alone GETs database.url)")
  end
  if words[1] == "curl" then
    table.remove(words, 1)
  end
  local r = {
    headers = {},
    follow = false,
    insecure = false,
    cookie_strings = {},
    cookie_files = {},
    cookie_engine = false,
    junk_session = false,
  }
  local p = { r = r, words = words, i = 1, data = {}, json = {}, base_dir = base_dir }
  while p.i <= #words do
    local w = words[p.i]
    if w:sub(1, 2) == "--" and #w > 2 then
      long_option(p, w)
    elseif w:sub(1, 1) == "-" and #w > 1 then
      short_options(p, w)
    else
      if r.url then
        fail("curl: one URL per request (%s and %s)", r.url, w)
      end
      r.url = w
    end
    p.i = p.i + 1
  end
  if r.url and r.url:match("^%a[%w+.-]*://") then
    fail(NO_URL, r.url)
  end
  if #p.json > 0 then
    json_data(p)
  end
  if p.has_data then
    local joined = #p.json > 0 and #p.data == 1 and p.data[1] or table.concat(p.data, "&")
    if p.get then
      r.query = joined
    else
      r.body = joined
    end
  end
  r.method = r.method or (p.head and "HEAD") or ((r.body and not p.get) and "POST" or "GET")
  return r
end

return M
