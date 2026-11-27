-- YAML subset parser (:help dbdash-config).
--
-- Supported: block mappings and sequences (including "- key: v" items), plain / single- /
-- double-quoted scalars, block scalars (| > with chomping and indentation indicators),
-- flow collections ([a, b], {k: v}, nested, may span lines), full-line and trailing comments.
-- Scalars resolve like PyYAML's YAML 1.1 resolver (yes/no/on/off booleans, 0x/0b/0o ints,
-- floats require a dot, 1:30 is the sexagesimal integer 90).
--
-- Not supported (reported as errors): anchors/aliases, tags, multiple documents, complex keys,
-- tab indentation, multi-line quoted or plain scalars.
--
-- Mappings are ordered (dbdash.util.map), null is vim.NIL, and `parse` also returns the source
-- position of every value keyed by path ("query.sql", "query.args[1].name").
local map = require("dbdash.util.map")

local M = {}

local NULL = vim.NIL

---@class dbdash.yaml.Error a YAML error with its line and column
---@field message string
---@field line integer
---@field col integer
local Error = {}
Error.__index = Error
Error.__tostring = function(e)
  return ("line %d, col %d: %s"):format(e.line, e.col, e.message)
end

---@return any (it raises: `x or fail(...)` keeps x's type)
local function fail(line, col, msg, ...)
  error(setmetatable({ message = msg:format(...), line = line, col = col }, Error), 0)
end

---@class dbdash.yaml.Rec
---@field raw string original line
---@field ind integer leading spaces
---@field body string text after the indentation
---@field no integer 1-based line number

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_blank(body)
  return body:match("^%s*$") ~= nil or body:match("^%s*#") ~= nil
end

local function is_seq_item(body)
  return body == "-" or body:match("^%-[ \t]") ~= nil
end

-- Scalar resolution ------------------------------------------------------------------------

local BOOL = {
  ["true"] = true,
  True = true,
  TRUE = true,
  yes = true,
  Yes = true,
  YES = true,
  on = true,
  On = true,
  ON = true,
  ["false"] = false,
  False = false,
  FALSE = false,
  no = false,
  No = false,
  NO = false,
  off = false,
  Off = false,
  OFF = false,
}
local NULLS = { [""] = true, ["~"] = true, null = true, Null = true, NULL = true }

---Resolve a plain (unquoted) scalar to its typed value.
---@param s string already trimmed, comment removed
---@return any
local function resolve_plain(s)
  if NULLS[s] then
    return NULL
  end
  local b = BOOL[s]
  if b ~= nil then
    return b
  end
  local sign, rest = s:match("^([-+]?)(.*)$")
  local neg = sign == "-" and -1 or 1
  local digits = rest:gsub("_", "")
  if rest:match("^0b[01_]+$") then
    return neg * tonumber(digits:sub(3), 2)
  elseif rest:match("^0x[%x_]+$") then
    return neg * tonumber(digits:sub(3), 16)
  elseif rest:match("^[1-9][0-9_]*:[0-5]?[0-9]") and rest:match("^[0-9_:]+$") then
    -- YAML 1.1 sexagesimal integer, e.g. 1:30 == 90
    local n, ok = 0, true
    for i, part in ipairs(vim.split(digits, ":", { plain = true })) do
      local d = tonumber(part)
      if not d or (i > 1 and d >= 60) then
        ok = false
      end
      n = n * 60 + (d or 0)
    end
    if ok then
      return neg * n
    end
  elseif rest:match("^0[0-7_]+$") then
    return neg * tonumber(digits, 8)
  elseif rest == "0" or rest:match("^[1-9][0-9_]*$") then
    return neg * tonumber(digits)
  end
  -- Floats: [0-9][0-9_]*.[0-9_]* or .[0-9_]+, optional exponent with mandatory sign.
  local mant = rest:match("^(.-)[eE][-+][0-9]+$") or rest
  if mant:match("^[0-9][0-9_]*%.[0-9_]*$") or mant:match("^%.[0-9_]+$") then
    return neg * tonumber(digits)
  end
  if rest == ".inf" or rest == ".Inf" or rest == ".INF" then
    return neg * math.huge
  end
  if s == ".nan" or s == ".NaN" or s == ".NAN" then
    return 0 / 0
  end
  return s
end

local utf8_char = require("dbdash.util.utf8").char

local ESCAPES = {
  ["0"] = "\0",
  a = "\a",
  b = "\b",
  t = "\t",
  ["\t"] = "\t",
  n = "\n",
  v = "\v",
  f = "\f",
  r = "\r",
  e = "\27",
  [" "] = " ",
  ['"'] = '"',
  ["/"] = "/",
  ["\\"] = "\\",
  N = "\194\133",
  _ = "\194\160",
  L = "\226\128\168",
  P = "\226\128\169",
}
local HEX_LEN = { x = 2, u = 4, U = 8 }

---Scan a quoted scalar starting at s[i] (the quote). Returns value and index after it.
---Returns nil when the closing quote is missing.
---@return string? value, integer after (set with the value)
local function scan_quoted(s, i, line, col)
  local q = s:sub(i, i)
  local out, j = {}, i + 1
  while j <= #s do
    local ch = s:sub(j, j)
    if ch == q then
      if q == "'" and s:sub(j + 1, j + 1) == "'" then
        out[#out + 1] = "'"
        j = j + 2
      else
        return table.concat(out), j + 1
      end
    elseif ch == "\\" and q == '"' then
      local e = s:sub(j + 1, j + 1)
      if ESCAPES[e] then
        out[#out + 1] = ESCAPES[e]
        j = j + 2
      elseif HEX_LEN[e] then
        local hex = s:sub(j + 2, j + 1 + HEX_LEN[e])
        if #hex ~= HEX_LEN[e] or not hex:match("^%x+$") then
          fail(line, col + j - i, "invalid \\%s escape", e)
        end
        out[#out + 1] = utf8_char(tonumber(hex, 16))
        j = j + 2 + HEX_LEN[e]
      else
        fail(line, col + j - i, "invalid escape \\%s", e)
      end
    else
      out[#out + 1] = ch
      j = j + 1
    end
  end
  return nil, j
end

---Remove a trailing comment (" #...") from a plain fragment, then trim.
local function strip_plain_comment(s)
  if s:sub(1, 1) == "#" then
    return ""
  end
  local h = s:find("%s#")
  if h then
    s = s:sub(1, h)
  end
  return trim(s)
end

---Remove a trailing comment while respecting quotes (used for flow text).
local function strip_comment_quoted(s)
  local q, j = nil, 1
  while j <= #s do
    local ch = s:sub(j, j)
    if q then
      if ch == "\\" and q == '"' then
        j = j + 1 -- skip the escaped character
      elseif ch == q then
        q = nil
      end
    elseif ch == '"' or ch == "'" then
      q = ch
    elseif ch == "#" and (j == 1 or s:sub(j - 1, j - 1):match("%s")) then
      return s:sub(1, j - 1)
    end
    j = j + 1
  end
  return s
end

-- Parser ---------------------------------------------------------------------------------

---@class dbdash.yaml.Parser
---@field recs dbdash.yaml.Rec[] the lines
---@field i integer the current line
---@field pos table<string, { line: integer, col: integer }> the position of every path
local P = {}
P.__index = P

local INCOMPLETE = {}

function P:peek()
  while self.i <= #self.recs do
    local r = self.recs[self.i]
    if not is_blank(r.body) then
      if r.raw:match("^ *\t") then
        fail(r.no, r.ind + 1, "tab characters are not allowed for indentation")
      end
      if r.ind == 0 and (r.body:match("^%-%-%-%s*$") or r.body:match("^%-%-%-%s+#")) then
        if self.seen_content then
          fail(r.no, 1, "multiple documents ('---') are not supported")
        end
        self.i = self.i + 1
      elseif r.ind == 0 and r.body:match("^%.%.%.%s*$") then
        fail(r.no, 1, "document end marker ('...') is not supported")
      else
        self.seen_content = true
        return r
      end
    else
      self.i = self.i + 1
    end
  end
end

---Split "key: rest". Returns nil when the body is not a mapping entry.
---@param r dbdash.yaml.Rec
---@param body string
---@return string?, string?
function P:split_key(r, body)
  local c = body:sub(1, 1)
  if c == '"' or c == "'" then
    local key, after = scan_quoted(body, 1, r.no, r.ind + 1)
    if not key then
      return nil
    end
    local rest = body:sub(after)
    local colon = rest:match("^%s*:()")
    if colon and (colon > #rest or rest:sub(colon, colon):match("%s")) then
      return key, rest:sub(colon)
    end
    return nil
  end
  if c == "[" or c == "{" or c == "#" or c == "|" or c == ">" then
    return nil
  end
  if body == "?" or body:match("^%?%s") then
    fail(r.no, r.ind + 1, "complex keys ('? ') are not supported")
  end
  local hash = body:find("%s#")
  local p = 1
  while true do
    local s = body:find(":", p, true)
    if not s or (hash and hash < s) then
      return nil
    end
    local nxt = body:sub(s + 1, s + 1)
    if nxt == "" or nxt:match("%s") then
      return trim(body:sub(1, s - 1)), body:sub(s + 1)
    end
    p = s + 1
  end
end

function P:record(path, line, col)
  self.pos[path] = { line = line, col = col }
end

---Parse a flow collection that starts in `text` and may continue on following lines.
function P:flow(r, text, col, path)
  local src = strip_comment_quoted(text)
  local last = self.i - 1 -- index of the record holding `text`
  while true do
    local ok, v, stop = pcall(self.parse_flow, self, src, r, col)
    if ok then
      local tail = src:sub(stop)
      if not is_blank(tail) then
        fail(r.no, col + stop - 1, "unexpected text after flow collection: %s", trim(tail))
      end
      self.i = last + 1
      self:record(path, r.no, col)
      return v
    elseif v ~= INCOMPLETE then
      error(v, 0)
    end
    last = last + 1
    local nr = self.recs[last]
    if not nr then
      fail(r.no, col, "unterminated flow collection")
    end
    src = src .. " " .. strip_comment_quoted(trim(nr.raw))
  end
end

---@class dbdash.yaml.Flow a flow collection being parsed
---@field src string
---@field i integer the position
---@field no integer the line number
---@field col integer the column of src's first character
local F = {}
F.__index = F

function F:ws()
  self.i = self.src:match("^%s*()", self.i)
end

---Raise INCOMPLETE at the end of the input (the collection goes on on the next line).
function F:at_end()
  if self.i > #self.src then
    error(INCOMPLETE, 0)
  end
end

---Skip whitespace; INCOMPLETE at the end.
function F:next()
  self:ws()
  self:at_end()
  return self.src:sub(self.i, self.i)
end

---A plain scalar up to a character of `stop_pat`, ": " (keys) or " #".
function F:plain(stop_pat)
  local src, j = self.src, self.i
  while j <= #src do
    local ch = src:sub(j, j)
    if ch:match(stop_pat) then
      break
    end
    if ch == ":" and src:sub(j + 1, j + 1):match("^[%s,%]}]?$") and stop_pat:find(":", 1, true) then
      break
    end
    if ch == "#" and j > 1 and src:sub(j - 1, j - 1):match("%s") then
      break
    end
    j = j + 1
  end
  local s = trim(src:sub(self.i, j - 1))
  self.i = j
  return s
end

---A quoted or plain scalar (a key stays text; a value is resolved: numbers, booleans...).
function F:scalar(is_key)
  self:at_end()
  local src, i = self.src, self.i
  local c = src:sub(i, i)
  if c == '"' or c == "'" then
    local s, after = scan_quoted(src, i, self.no, self.col + i - 1)
    if not s then
      error(INCOMPLETE, 0)
    end
    self.i = after
    return s
  end
  if c == "&" or c == "*" then
    fail(self.no, self.col + i - 1, "anchors and aliases are not supported")
  elseif c == "!" then
    fail(self.no, self.col + i - 1, "tags are not supported")
  end
  local s = self:plain(is_key and "[,%[%]{}:]" or "[,%[%]{}]")
  if is_key then
    return s
  end
  return resolve_plain(s)
end

---After an entry: `close` ends the collection (true), "," goes on.
function F:next_or(close, what)
  local d = self:next()
  self.i = self.i + 1
  if d == close then
    return true
  elseif d ~= "," then
    fail(self.no, self.col + self.i - 2, "expected ',' or '%s' in flow %s", close, what)
  end
end

function F:sequence()
  self.i = self.i + 1
  local t = {}
  repeat
    if self:next() == "]" then
      self.i = self.i + 1
      return t
    end
    t[#t + 1] = self:value()
  until self:next_or("]", "sequence")
  return t
end

function F:mapping()
  self.i = self.i + 1
  local t = map.new()
  repeat
    if self:next() == "}" then
      self.i = self.i + 1
      return t
    end
    local k = self:scalar(true)
    local v = NULL ---@type any
    if self:next() == ":" then
      self.i = self.i + 1
      local d = self:next()
      if d ~= "," and d ~= "}" then
        v = self:value()
      end
    end
    map.set(t, k, v)
  until self:next_or("}", "mapping")
  return t
end

function F:value()
  local c = self:next()
  if c == "[" then
    return self:sequence()
  elseif c == "{" then
    return self:mapping()
  end
  return self:scalar(false)
end

---Recursive-descent parser over a flow string. Raises INCOMPLETE at end of input.
---@return any value, integer next_index
function P:parse_flow(src, r, col)
  local f = setmetatable({ src = src, i = 1, no = r.no, col = col }, F)
  local v = f:value()
  return v, f.i
end

---Parse the inline part of a value ("rest" after "key:" or "-").
---@return "empty"|"block"|"value", any
function P:inline(r, rest, path)
  local lead = #rest:match("^%s*")
  local v = rest:sub(lead + 1)
  local col = r.ind + (#r.body - #rest) + lead + 1
  if is_blank(v) then
    return "empty"
  end
  local c = v:sub(1, 1)
  if c == "|" or c == ">" then
    return "block", v
  elseif c == "&" or c == "*" then
    fail(r.no, col, "anchors and aliases are not supported")
  elseif c == "!" then
    fail(r.no, col, "tags are not supported")
  elseif c == "@" or c == "`" or c == "%" then
    fail(r.no, col, "plain scalars cannot start with '%s'", c)
  elseif c == "[" or c == "{" then
    return "value", self:flow(r, v, col, path)
  elseif c == '"' or c == "'" then
    local s, after = scan_quoted(v, 1, r.no, col)
    if not s then
      fail(r.no, col, "unterminated quoted string (multi-line quoted scalars are not supported)")
    end
    if not is_blank(v:sub(after)) then
      fail(r.no, col + after - 1, "unexpected text after quoted string")
    end
    self:record(path, r.no, col)
    return "value", s
  end
  self:record(path, r.no, col)
  return "value", resolve_plain(strip_plain_comment(v))
end

---Parse a block scalar whose header is `header` ("|", ">-", "|2+", ...).
function P:block(r, header, parent_ind, path)
  local style = header:sub(1, 1)
  local chomp, explicit = "clip", nil
  local h = header:sub(2)
  local flags = h:match("^[-+0-9]*")
  for f in flags:gmatch(".") do
    if f == "-" then
      chomp = "strip"
    elseif f == "+" then
      chomp = "keep"
    else
      explicit = tonumber(f)
    end
  end
  if not is_blank(h:sub(#flags + 1)) then
    fail(r.no, r.ind + 1, "invalid block scalar header '%s'", trim(header))
  end

  -- self.i already points past the header line.
  local j = self.i
  local content_ind
  if explicit then
    content_ind = parent_ind + explicit
  else
    for k = j, #self.recs do
      local rec = self.recs[k]
      if not rec.raw:match("^%s*$") then
        content_ind = rec.ind
        break
      end
    end
    if not content_ind or content_ind <= parent_ind then
      content_ind = math.huge
    end
  end

  local lines, first_no = {}, nil
  while j <= #self.recs do
    local rec = self.recs[j]
    if rec.raw:match("^%s*$") then
      lines[#lines + 1] = rec.raw:sub(content_ind + 1)
    elseif rec.ind >= content_ind then
      lines[#lines + 1] = rec.raw:sub(content_ind + 1)
      first_no = first_no or rec.no
    else
      break
    end
    j = j + 1
  end
  self.i = j
  self:record(path, first_no or r.no, content_ind == math.huge and r.ind + 1 or content_ind + 1)

  local last = 0
  for k = #lines, 1, -1 do
    if lines[k] ~= "" then
      last = k
      break
    end
  end
  local trailing = #lines - last

  local text
  if style == "|" then
    text = table.concat(lines, "\n", 1, last)
  else
    local out, prev, blanks = {}, nil, 0
    for k = 1, last do
      local l = lines[k]
      if l == "" then
        blanks = blanks + 1
      else
        local more = l:match("^[ \t]") ~= nil
        if prev == nil then
          out[#out + 1] = string.rep("\n", blanks) .. l
        elseif prev == "normal" and not more then
          out[#out + 1] = (blanks == 0 and " " or string.rep("\n", blanks)) .. l
        else
          out[#out + 1] = "\n" .. string.rep("\n", blanks) .. l
        end
        prev, blanks = more and "more" or "normal", 0
      end
    end
    text = table.concat(out)
  end

  if last == 0 then
    return chomp == "keep" and string.rep("\n", trailing) or ""
  elseif chomp == "strip" then
    return text
  elseif chomp == "keep" then
    return text .. "\n" .. string.rep("\n", trailing)
  end
  return text .. "\n"
end

---Parse the value following "key:" or "-", including nested blocks.
---@param in_map boolean allows "key:\n- item" at the same indentation
function P:value(r, rest, parent_ind, path, in_map)
  local kind, v = self:inline(r, rest, path)
  if kind == "value" then
    return v
  elseif kind == "block" then
    return self:block(r, v, parent_ind, path)
  end
  local nxt = self:peek()
  if nxt and nxt.ind > parent_ind then
    return self:node(nxt.ind, path)
  elseif nxt and in_map and nxt.ind == parent_ind and is_seq_item(nxt.body) then
    return self:seq(parent_ind, path)
  end
  self:record(path, r.no, r.ind + #r.body + 1)
  return NULL
end

function P:mapping(ind, path)
  local t = map.new()
  while true do
    local r = self:peek()
    if not r or r.ind < ind then
      break
    end
    if r.ind > ind then
      fail(r.no, r.ind + 1, "unexpected indentation")
    end
    local k, rest = self:split_key(r, r.body)
    if not k then
      fail(r.no, r.ind + 1, "expected 'key: value'")
    end
    self.i = self.i + 1
    map.set(t, k, self:value(r, rest, ind, path == "" and k or (path .. "." .. k), true))
  end
  return t
end

function P:seq(ind, path)
  local t = {}
  while true do
    local r = self:peek()
    if not r or r.ind < ind then
      break
    elseif r.ind > ind then
      fail(r.no, r.ind + 1, "unexpected indentation")
    elseif not is_seq_item(r.body) then
      break -- the enclosing mapping continues ("key:\n- a\nnext: b")
    end
    local n = #t + 1
    local p = path .. "[" .. n .. "]"
    local rest = r.body:sub(2)
    local sp = #rest:match("^ *")
    local inner = rest:sub(sp + 1)
    if not is_blank(inner) and (is_seq_item(inner) or self:split_key(r, inner)) then
      -- Re-read the item content as a node indented at its own column.
      self.recs[self.i] = { raw = r.raw, ind = ind + 1 + sp, body = inner, no = r.no }
      t[n] = self:node(ind + 1 + sp, p)
    else
      self.i = self.i + 1
      t[n] = self:value(r, rest, ind, p, false)
    end
  end
  return t
end

function P:node(ind, path)
  local r = self:peek()
  if not r or r.ind < ind then
    return NULL
  end
  if is_seq_item(r.body) then
    return self:seq(r.ind, path)
  elseif self:split_key(r, r.body) then
    return self:mapping(r.ind, path)
  end
  self.i = self.i + 1
  local kind, v = self:inline(r, r.body, path)
  if kind == "block" then
    return self:block(r, v, r.ind - 1, path)
  end
  return v
end

---Parse YAML text.
---@param text string
---@return any? value, table|dbdash.yaml.Error? positions_or_error
function M.parse(text)
  local recs = {}
  local no = 0
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    no = no + 1
    local ind = #line:match("^ *")
    recs[no] = { raw = line, ind = ind, body = line:sub(ind + 1), no = no }
  end
  if no > 0 and recs[no].raw == "" then
    recs[no] = nil
  end
  local p = setmetatable({ recs = recs, i = 1, pos = {} }, P)
  local ok, res = pcall(function()
    local v = p:node(0, "")
    local r = p:peek()
    if r then
      fail(r.no, r.ind + 1, "unexpected content")
    end
    return v
  end)
  if not ok then
    if getmetatable(res) ~= Error then
      error(res, 0)
    end
    ---@cast res dbdash.yaml.Error
    return nil, res
  end
  return res, p.pos
end

---Read and parse a file. Errors carry the file name.
---@param path string
---@return any? value, table|dbdash.yaml.Error? positions_or_error
function M.parse_file(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, setmetatable({ message = err, line = 0, col = 0 }, Error)
  end
  local text = f:read("*a")
  f:close()
  return M.parse(text)
end

M.Error = Error

return M
