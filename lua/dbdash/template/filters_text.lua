-- Jinja's text filters: capitalize, center, escape (e), forceescape, filesizeformat,
-- format, indent, pprint, striptags, title, truncate, urlencode, urlize, wordcount,
-- wordwrap, xmlattr.
--
-- In SQL templates, escape / e / forceescape write a literal of the database (what
-- autoescape writes), not HTML; urlize and xmlattr give plain text there, so the SQL
-- autoescape still applies to them.
local R = require("dbdash.template.runtime")
local map = require("dbdash.util.map")
local errors = require("dbdash.template.errors")

local M = {}

local raise = errors.raise
local NONE = R.NONE

local function bind(...)
  return require("dbdash.template.bind").bind(...)
end

local function str_method(name, s, args, kw)
  local _, out = require("dbdash.template.methods").call(s, name, args, kw)
  return out
end

local function ulen(s)
  return #R.chars(s)
end

---Escaping for escape / forceescape: the dialect's literal in SQL templates, else HTML.
local function escape(env, v)
  if env.escape then
    return R.safe(env.escape(v))
  end
  return R.safe(R.html_escape(R.str(v)))
end

---Markup with HTML autoescape (descriptions); plain text in SQL templates.
local function html_result(env, s)
  if env.autoescape and not env.escape then
    return R.safe(s)
  end
  return s
end

local F = {}

F.capitalize = function(_, v, args, kw)
  bind("capitalize", args, kw, {})
  return str_method("capitalize", R.str(v), {}, {})
end

F.center = function(_, v, args, kw)
  local width = bind("center", args, kw, { { "width", 80 } })
  return str_method("center", R.str(v), { width }, {})
end

F.escape = function(env, v, args, kw)
  bind("escape", args, kw, {})
  if R.is_safe(v) then
    return v
  end
  return escape(env, v)
end
F.e = F.escape

F.forceescape = function(env, v, args, kw)
  bind("forceescape", args, kw, {})
  return escape(env, R.is_safe(v) and v.s or v)
end

F.filesizeformat = function(_, v, args, kw)
  local binary = bind("filesizeformat", args, kw, { { "binary", false } })
  local bytes = R.num(R.filters.float({}, v, {}, {}))
  local base = R.truthy(binary) and 1024 or 1000
  local prefixes = R.truthy(binary) and { "KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB" }
    or { "kB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB" }
  if bytes == 1 then
    return "1 Byte"
  elseif bytes < base then
    return ("%d Bytes"):format(bytes >= 0 and math.floor(bytes) or math.ceil(bytes))
  end
  local unit, prefix
  for i, p in ipairs(prefixes) do
    unit, prefix = base ^ (i + 1), p
    if bytes < unit then
      break
    end
  end
  return ("%.1f %s"):format(base * bytes / unit, prefix)
end

F.format = function(_, v, args, kw)
  if #args > 0 and next(kw) then
    raise("value", "can't handle positional and keyword arguments at the same time")
  end
  local values
  if next(kw) then
    values = map.new()
    for _, k in ipairs(R.kw_keys(kw)) do
      map.set(values, k, kw[k])
    end
  else
    values = R.tuple(vim.list_extend({}, args))
  end
  return require("dbdash.template.pyformat").percent(R.str(v), values)
end

F.indent = function(_, v, args, kw)
  local width, first, blank =
    bind("indent", args, kw, { { "width", 4 }, { "first", false }, { "blank", false } })
  local ind = (type(width) == "string" or R.is_safe(width)) and R.str(width)
    or (" "):rep((R.num(width)))
  local s = R.str(v) .. "\n"
  local lines = str_method("splitlines", s, {}, {})
  local rv
  if R.truthy(blank) then
    rv = table.concat(lines, "\n" .. ind)
  else
    rv = table.remove(lines, 1) or ""
    if #lines > 0 then
      local parts = {}
      for i, l in ipairs(lines) do
        parts[i] = l ~= "" and (ind .. l) or l
      end
      rv = rv .. "\n" .. table.concat(parts, "\n")
    end
  end
  if R.truthy(first) then
    rv = ind .. rv
  end
  return R.is_safe(v) and R.safe(rv) or rv
end

-- pprint: Python's pprint.pformat (width 80, sorted mapping keys) --------------------------

local function prepr(v)
  if map.is_map(v) then
    local keys = map.keys(v)
    local ok, sorted = pcall(R.sorted, keys)
    keys = ok and sorted or keys
    local parts = {}
    for i, k in ipairs(keys) do
      parts[i] = prepr(k) .. ": " .. prepr(v[k])
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif R.is_list(v) and (R.typename(v) == "list" or R.typename(v) == "tuple") then
    local parts = {}
    for i = 1, #v do
      parts[i] = prepr(v[i])
    end
    if R.is_tuple(v) then
      return "(" .. table.concat(parts, ", ") .. (#v == 1 and ",)" or ")")
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return R.repr(v)
end

local WIDTH = 80

local format

local function format_items(items, out, indent, allowance)
  indent = indent + 1
  local delim = ""
  for i, ent in ipairs(items) do
    local last = i == #items
    out[#out + 1] = delim
    delim = ",\n" .. (" "):rep(indent)
    format(ent, out, indent, last and allowance or 1)
  end
end

format = function(v, out, indent, allowance)
  local rep = prepr(v)
  if ulen(rep) > WIDTH - indent - allowance then
    if map.is_map(v) and next(v) ~= nil then
      out[#out + 1] = "{"
      local keys = map.keys(v)
      local ok, sorted = pcall(R.sorted, keys)
      keys = ok and sorted or keys
      local ind = indent + 1
      for i, k in ipairs(keys) do
        local last = i == #keys
        local kr = prepr(k)
        out[#out + 1] = kr .. ": "
        format(v[k], out, ind + ulen(kr) + 2, last and allowance + 1 or 1)
        if not last then
          out[#out + 1] = ",\n" .. (" "):rep(ind)
        end
      end
      out[#out + 1] = "}"
      return
    elseif R.is_list(v) and #v > 0 and (R.typename(v) == "list" or R.typename(v) == "tuple") then
      local close = R.is_tuple(v) and (#v == 1 and ",)" or ")") or "]"
      out[#out + 1] = R.is_tuple(v) and "(" or "["
      format_items(v, out, indent, allowance + #close)
      out[#out + 1] = close
      return
    end
  end
  out[#out + 1] = rep
end

F.pprint = function(_, v, args, kw)
  bind("pprint", args, kw, {})
  local out = {}
  format(v, out, 0, 0)
  return table.concat(out)
end

-- striptags ---------------------------------------------------------------------------------

local ENTITIES = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = "\194\160",
  raquo = "»",
  laquo = "«",
  copy = "©",
  reg = "®",
  hellip = "…",
  mdash = "—",
  ndash = "–",
}

local function unescape(s)
  return (
    s:gsub("&(#?[xX]?)(%w+);", function(kind, body)
      if kind == "" then
        return ENTITIES[body]
      end
      local n = kind:lower() == "#x" and tonumber(body, 16) or tonumber(body)
      if n then
        return require("dbdash.util.utf8").char(n)
      end
    end)
  )
end

F.striptags = function(_, v, args, kw)
  bind("striptags", args, kw, {})
  local s = R.str(v)
  while true do
    local a = s:find("<!--", 1, true)
    local b = a and s:find("-->", a, true)
    if not b then
      break
    end
    s = s:sub(1, a - 1) .. s:sub(b + 3)
  end
  while true do
    local a = s:find("<", 1, true)
    local b = a and s:find(">", a, true)
    if not b then
      break
    end
    s = s:sub(1, a - 1) .. s:sub(b + 1)
  end
  local words = {}
  for w in s:gmatch("%S+") do
    words[#words + 1] = w
  end
  return unescape(table.concat(words, " "))
end

-- title, truncate, wordcount, wordwrap ------------------------------------------------------

F.title = function(_, v, args, kw)
  bind("title", args, kw, {})
  -- Words start after spaces, "-", "(", "{", "[" and "<" (Jinja, not str.title()).
  local out = {}
  for sep, word in (" " .. R.str(v)):gmatch("([-%s({%[<]*)([^-%s({%[<]*)") do
    out[#out + 1] = sep
    if word ~= "" then
      local cs = R.chars(word)
      out[#out + 1] = R.upper(cs[1]) .. vim.fn.tolower(table.concat(cs, "", 2))
    end
  end
  return table.concat(out):sub(2)
end

F.truncate = function(_, v, args, kw)
  local length, killwords, ending, leeway = bind(
    "truncate",
    args,
    kw,
    { { "length", 255 }, { "killwords", false }, { "end", "..." }, { "leeway", NONE } }
  )
  local s = R.str(v)
  length = (R.num(length))
  ending = R.str(ending)
  leeway = leeway == NONE and 5 or (R.num(leeway))
  local cs = R.chars(s)
  if length < ulen(ending) then
    raise("value", "expected length >= %d, got %d", ulen(ending), length)
  end
  if #cs <= length + leeway then
    return s
  end
  local head = table.concat(cs, "", 1, length - ulen(ending))
  if R.truthy(killwords) then
    return head .. ending
  end
  local cut = head:match("^(.*) [^ ]*$") or head
  return cut .. ending
end

F.wordcount = function(_, v, args, kw)
  bind("wordcount", args, kw, {})
  local n = 0
  for _ in R.str(v):gmatch("[%w_\128-\255]+") do
    n = n + 1
  end
  return n
end

---Python's textwrap.wrap(line, width, expand_tabs=False, replace_whitespace=False, ...).
local function wrap(text, width, break_long, break_hyphens)
  -- Chunks: words (split after hyphens between letters), and whitespace runs.
  local chunks = {}
  for ws, word in text:gmatch("(%s*)(%S*)") do
    if ws ~= "" then
      chunks[#chunks + 1] = ws
    end
    if word ~= "" then
      if break_hyphens then
        local rest = word
        while true do
          local a, b = rest:match("^(.-%a%-)(%a.*)$")
          if not a then
            break
          end
          chunks[#chunks + 1] = a
          rest = b
        end
        chunks[#chunks + 1] = rest
      else
        chunks[#chunks + 1] = word
      end
    end
  end
  local lines = {}
  local i = 1
  while i <= #chunks do
    local cur, len = {}, 0
    if chunks[i]:match("^%s+$") and #lines > 0 then
      i = i + 1 -- drop whitespace at the start of a line (not the first)
    end
    while i <= #chunks do
      local c = chunks[i]
      local l = ulen(c)
      if len + l <= width then
        cur[#cur + 1] = c
        len = len + l
        i = i + 1
      else
        break
      end
    end
    if i <= #chunks and ulen(chunks[i]) > width and not chunks[i]:match("^%s+$") then
      -- A word longer than the line: break it (or put it alone on a line).
      local c = R.chars(chunks[i])
      local room = math.max(width - len, 1)
      if break_long then
        cur[#cur + 1] = table.concat(c, "", 1, room)
        chunks[i] = table.concat(c, "", room + 1)
      elseif #cur == 0 then
        cur[#cur + 1] = chunks[i]
        i = i + 1
      end
    end
    while #cur > 0 and cur[#cur]:match("^%s+$") do
      table.remove(cur) -- drop whitespace at the end of a line
    end
    if #cur > 0 then
      lines[#lines + 1] = table.concat(cur)
    end
  end
  return lines
end

F.wordwrap = function(_, v, args, kw)
  local width, break_long, wrapstring, break_hyphens = bind("wordwrap", args, kw, {
    { "width", 79 },
    { "break_long_words", true },
    { "wrapstring", NONE },
    { "break_on_hyphens", true },
  })
  local sep = wrapstring == NONE and "\n" or R.str(wrapstring)
  local paragraphs = {}
  for _, line in ipairs(str_method("splitlines", R.str(v), {}, {})) do
    paragraphs[#paragraphs + 1] =
      table.concat(wrap(line, (R.num(width)), R.truthy(break_long), R.truthy(break_hyphens)), sep)
  end
  return table.concat(paragraphs, sep)
end

-- URLs and attributes ----------------------------------------------------------------------

---urllib.parse.quote: unreserved characters and `safe` stay, other bytes become %XX.
local function url_quote(v, for_qs)
  local s = (type(v) == "string" or R.is_safe(v)) and R.str(v) or R.str(v)
  local safe = for_qs and "" or "/"
  local out = s:gsub("[^%w_.~-]", function(c)
    if safe:find(c, 1, true) then
      return c
    end
    return ("%%%02X"):format(c:byte())
  end)
  if for_qs then
    out = out:gsub("%%20", "+")
  end
  return out
end

F.urlencode = function(_, v, args, kw)
  bind("urlencode", args, kw, {})
  if type(v) == "string" or R.is_safe(v) or not (map.is_map(v) or R.is_list(v)) then
    return url_quote(v, false)
  end
  local items = {}
  if map.is_map(v) then
    for k, x in map.pairs(v) do
      items[#items + 1] = { k, x }
    end
  else
    for _, kv in ipairs(v) do
      items[#items + 1] = { R.unpack(kv, 2) }
    end
  end
  local parts = {}
  for i, kv in ipairs(items) do
    parts[i] = url_quote(kv[1], true) .. "=" .. url_quote(kv[2], true)
  end
  return table.concat(parts, "&")
end

local BASIC_TLD = {
  com = true,
  net = true,
  int = true,
  edu = true,
  gov = true,
  org = true,
  info = true,
  mil = true,
}

---Jinja's _http_re: http(s)://host or www.host, or a bare domain with a basic TLD; then
---an optional port, path, query and fragment.
local function is_http(s)
  local scheme, rest = s:match("^(https?://)(.*)$")
  local host_and_more = rest or s
  local host, tail = host_and_more:match("^([^:/?#]+)(.*)$")
  if not host then
    return false
  end
  local ok = false
  if scheme or s:sub(1, 4) == "www." then
    local h = scheme and host or host
    local tld = h:match("%.([^.]+)$") or (scheme and nil)
    if
      tld
      and (tld:match("^%a%a+$") and #tld <= 63 or tld:match("^xn%-%-"))
      and h:match("^[%w%%%-%.]+$")
    then
      ok = true
    elseif scheme and h:match("^%d+%.%d+%.%d+%.%d+$") then
      ok = true
    end
  else
    local tld = host:match("%.(%a+)$")
    ok = tld ~= nil and BASIC_TLD[tld] and host:match("^[%w%%%-%.]+$") ~= nil
  end
  if not ok then
    return false
  end
  local port_rest = tail:match("^:%d%d?%d?%d?%d?(.*)$")
  if port_rest then
    tail = port_rest
  end
  return tail == "" or (tail:match("^[/?#]") ~= nil and not tail:find("%s"))
end

local function is_email(s)
  return s:match("^%S+@[%w_][%w_.-]*%.[%w_]+$") ~= nil
end

F.urlize = function(env, v, args, kw)
  local limit, nofollow, target, rel, extra = bind("urlize", args, kw, {
    { "trim_url_limit", NONE },
    { "nofollow", false },
    { "target", NONE },
    { "rel", NONE },
    { "extra_schemes", NONE },
  })
  local rels = {}
  for r in (rel ~= NONE and R.str(rel) or ""):gmatch("%S+") do
    rels[r] = true
  end
  if R.truthy(nofollow) then
    rels.nofollow = true
  end
  rels.noopener = true -- the urlize.rel policy
  local rel_list = vim.tbl_keys(rels)
  table.sort(rel_list)
  local rel_attr = (' rel="%s"'):format(R.html_escape(table.concat(rel_list, " ")))
  local target_attr = target ~= NONE and (' target="%s"'):format(R.html_escape(R.str(target))) or ""
  local function trim(x)
    if limit ~= NONE and ulen(x) > R.num(limit) then
      return table.concat(R.chars(x), "", 1, (R.num(limit))) .. "..."
    end
    return x
  end
  local text = R.is_safe(v) and v.s or R.html_escape(R.str(v))
  local out = {}
  for space, word in text:gmatch("(%s*)(%S*)") do
    out[#out + 1] = space
    if word ~= "" then
      local head, middle, tail = "", word, ""
      local h = middle:match("^([(<]+)") or middle:match("^(&lt;)")
      while h do
        head = head .. h
        middle = middle:sub(#h + 1)
        h = middle:match("^([(<]+)") or middle:match("^(&lt;)")
      end
      while true do
        local t = middle:match("([)>.,\n])$") or (middle:sub(-4) == "&gt;" and "&gt;" or nil)
        if not t or #t >= #middle then
          break
        end
        tail = t .. tail
        middle = middle:sub(1, #middle - #t)
      end
      -- Balance parentheses: take closing ones back from the tail.
      for _, pair in ipairs({ { "(", ")" }, { "<", ">" }, { "&lt;", "&gt;" } }) do
        local function count(s, c)
          local n, pos = 0, 1
          while true do
            local i = s:find(c, pos, true)
            if not i then
              return n
            end
            n, pos = n + 1, i + #c
          end
        end
        local starts = count(middle, pair[1])
        if starts > count(middle, pair[2]) then
          for _ = 1, math.min(starts, count(tail, pair[2])) do
            local i = tail:find(pair[2], 1, true)
            local e = i + #pair[2] - 1
            middle = middle .. tail:sub(1, e)
            tail = tail:sub(e + 1)
          end
        end
      end
      if is_http(middle) then
        local href = (middle:match("^https?://") and "" or "https://") .. middle
        middle = ('<a href="%s"%s%s>%s</a>'):format(href, rel_attr, target_attr, trim(middle))
      elseif middle:sub(1, 7) == "mailto:" and is_email(middle:sub(8)) then
        middle = ('<a href="%s">%s</a>'):format(middle, middle:sub(8))
      elseif
        middle:find("@", 1, true)
        and middle:sub(1, 4) ~= "www."
        and middle:sub(1, 1) ~= "@"
        and not middle:find(":", 1, true)
        and is_email(middle)
      then
        middle = ('<a href="mailto:%s">%s</a>'):format(middle, middle)
      elseif extra ~= NONE then
        for _, scheme in ipairs(R.iter(extra)) do
          scheme = R.str(scheme)
          if middle ~= scheme and middle:sub(1, #scheme) == scheme then
            middle = ('<a href="%s"%s%s>%s</a>'):format(middle, rel_attr, target_attr, middle)
          end
        end
      end
      out[#out + 1] = head .. middle .. tail
    end
  end
  return html_result(env, table.concat(out))
end

F.xmlattr = function(env, v, args, kw)
  local autospace = bind("xmlattr", args, kw, { { "autospace", true } })
  if not map.is_map(v) then
    raise("type", "xmlattr: expected a mapping, got '%s'", R.typename(v))
  end
  local items = {}
  for k, x in map.pairs(v) do
    if x ~= NONE and not R.is_undef(x) then
      local key = R.str(k)
      if key:find("[%s/>=]") then
        raise("value", "Invalid character in attribute name: %s", R.repr(key))
      end
      items[#items + 1] = ('%s="%s"'):format(R.html_escape(key), R.html_escape(R.str(x)))
    end
  end
  local rv = table.concat(items, " ")
  if R.truthy(autospace) and rv ~= "" then
    rv = " " .. rv
  end
  return html_result(env, rv)
end

function M.install()
  for k, fn in pairs(F) do
    R.filters[k] = fn
  end
end

return M
