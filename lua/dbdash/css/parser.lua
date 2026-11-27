-- Style sheets from configs (after Stylo's parser, a subset): a sheet is a mapping of
-- selectors to declarations, written in YAML:
--   style:
--     "panel#trend":            { border: rounded }
--     "table row:nth-child(even)": { background-color: "#2c313a" }
--     "axis, axis-title":       { color: Comment }
-- Selectors: element names or *, #id, .class, [attr] / [attr=value] / [attr="value"],
-- :nth-child(odd|even|N), :first-child, :last-child, the descendant combinator (space)
-- and ::part(name) (the same as a descendant `name`), comma-separated lists.
-- Specificity is (ids, classes + attributes + pseudo-classes, elements), as in CSS.
local properties = require("dbdash.css.properties")

local M = {}

---@class dbdash.css.Compound
---@field tag string? nil for *
---@field id string?
---@field classes string[]
---@field attrs { name: string, value: string? }[]
---@field pseudos { name: string, arg: any }[]

---@class dbdash.css.Selector
---@field parts dbdash.css.Compound[] outermost first
---@field specificity integer[] { ids, classes, tags }
---@field text string

---@class dbdash.css.Rule
---@field selector dbdash.css.Selector
---@field decls table<string, any> parsed values
---@field order integer position in its sheet

local IDENT = "[%a_][%w_-]*"

---Parse one compound selector at `s:sub(i)`; returns it and the next index (and for
---::part(x), the part x, a descendant), or nil and an error.
---@return table? compound, integer|string next_or_err, table? part
local function compound(s, i, text)
  local c = { classes = {}, attrs = {}, pseudos = {} }
  local tag = s:match("^" .. IDENT, i)
  if tag then
    c.tag = tag
    i = i + #tag
  elseif s:sub(i, i) == "*" then
    i = i + 1
  end
  while i <= #s do
    local ch = s:sub(i, i)
    if ch == "#" or ch == "." then
      local name = s:match("^" .. IDENT, i + 1)
      if not name then
        return nil, ("selector %q: a name is needed after '%s'"):format(text, ch)
      end
      if ch == "#" then
        c.id = name
      else
        c.classes[#c.classes + 1] = name
      end
      i = i + 1 + #name
    elseif ch == "[" then
      local close = s:find("]", i, true)
      if not close then
        return nil, ("selector %q: missing ']'"):format(text)
      end
      local inner = vim.trim(s:sub(i + 1, close - 1))
      local name, value = inner:match("^(" .. IDENT .. ")%s*=%s*(.-)$")
      if name then
        value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
        c.attrs[#c.attrs + 1] = { name = name, value = value }
      elseif inner:match("^" .. IDENT .. "$") then
        c.attrs[#c.attrs + 1] = { name = inner }
      else
        return nil, ("selector %q: invalid attribute selector [%s]"):format(text, inner)
      end
      i = close + 1
    elseif s:sub(i, i + 1) == "::" then
      local name, arg = s:match("^::(" .. IDENT .. ")%((" .. IDENT .. ")%)", i)
      if name ~= "part" then
        return nil, ("selector %q: only ::part(name) is supported"):format(text)
      end
      -- ::part(x) is a descendant x of this element
      return c,
        i + #("::part(" .. arg .. ")"),
        { tag = arg, classes = {}, attrs = {}, pseudos = {} }
    elseif ch == ":" then
      local name = s:match("^:(" .. IDENT .. ")", i)
      if not name then
        return nil, ("selector %q: a pseudo-class is needed after ':'"):format(text)
      end
      i = i + 1 + #name
      local arg
      if s:sub(i, i) == "(" then
        local close = s:find(")", i, true)
        if not close then
          return nil, ("selector %q: missing ')'"):format(text)
        end
        arg = vim.trim(s:sub(i + 1, close - 1))
        i = close + 1
      end
      if name == "nth-child" then
        if not (arg == "odd" or arg == "even" or (arg and arg:match("^%d+$"))) then
          return nil, ("selector %q: :nth-child takes odd, even or a number"):format(text)
        end
        arg = tonumber(arg) or arg
      elseif name ~= "first-child" and name ~= "last-child" then
        return nil, ("selector %q: unknown pseudo-class :%s"):format(text, name)
      end
      c.pseudos[#c.pseudos + 1] = { name = name, arg = arg }
    else
      break
    end
  end
  return c, i
end

---Parse one selector (no commas).
---@return dbdash.css.Selector?, string? err
function M.selector(text)
  local s = vim.trim(text)
  if s == "" then
    return nil, "empty selector"
  end
  local parts, i = {}, 1
  while i <= #s do
    local c, nexti, part = compound(s, i, text)
    if not c then
      return nil, tostring(nexti)
    end
    ---@cast nexti integer
    if nexti == i then
      return nil, ("selector %q: unexpected %q"):format(text, s:sub(i, i))
    end
    parts[#parts + 1] = c
    if part then
      parts[#parts + 1] = part
    end
    i = nexti
    local sp = s:match("^%s+", i)
    if sp then
      i = i + #sp
    elseif i <= #s then
      return nil, ("selector %q: unexpected %q"):format(text, s:sub(i, i))
    end
  end
  local spec = { 0, 0, 0 }
  for _, c in ipairs(parts) do
    if c.id then
      spec[1] = spec[1] + 1
    end
    spec[2] = spec[2] + #c.classes + #c.attrs + #c.pseudos
    if c.tag then
      spec[3] = spec[3] + 1
    end
  end
  return { parts = parts, specificity = spec, text = s }
end

---Parse a declaration block { property = value }.
---@return table<string, any>?, string? err, string? property the property at fault
function M.declarations(block)
  if type(block) ~= "table" then
    return nil, "expected a mapping of properties"
  end
  local out = {}
  for name, v in pairs(block) do
    local value, err = properties.parse(name, v)
    if value == nil and err then
      return nil, ("%s: %s"):format(name, err), name
    end
    out[name] = value
  end
  return out
end

---Parse a style sheet (selector -> declarations). Errors carry the selector key so the
---config can report its line.
---@param sheet table<string, table>
---@param keys string[]? the selectors in the order written (default: sorted)
---@return dbdash.css.Rule[]?, { key: string, property: string?, message: string }? err
function M.sheet(sheet, keys)
  if keys == nil then
    keys = vim.tbl_keys(sheet)
    table.sort(keys)
  end
  local rules = {}
  for _, key in ipairs(keys) do
    local decls, derr, prop = M.declarations(sheet[key])
    if not decls then
      return nil, { key = key, property = prop, message = derr }
    end
    for piece in (key .. ","):gmatch("([^,]*),") do
      local sel, err = M.selector(piece)
      if not sel then
        return nil, { key = key, message = ("selector %q: %s"):format(vim.trim(piece), err) }
      end
      -- key: the selector list as written (a config reports the line of its declarations)
      rules[#rules + 1] = { selector = sel, decls = decls, order = #rules + 1, key = key }
    end
  end
  return rules
end

return M
