-- A text chart's content as DOM: chart > lines > line, one line element per result row
-- (like one <div> per log entry; the screen lines a long one wraps into are layout's line
-- boxes, not elements), in show.reverse order, with the class of the first show.highlight
-- rule whose pattern matches. A line's text is its cells joined by show.separator; a NULL
-- cell is the character "\1" there, which layout replaces with cell.null { content }.
local content = require("dbdash.render.content")
local tbl = require("dbdash.render.format")

local M = {}

M.NULL = "\1"

local nn = require("dbdash.util.null").nn

function M.key(show)
  return { show.column_list, show.separator, show.reverse, show.highlight }
end

---Column indexes to show: show.column_list (names, or { column = ... }) or all of them.
local function columns(rs, show)
  local list = nn(show.column_list)
  if not list or #list == 0 then
    local all = {}
    for i = 1, #rs.columns do
      all[i] = i
    end
    return all
  end
  local by_name = {}
  for i, c in ipairs(rs.columns) do
    by_name[c.name] = by_name[c.name] or i
  end
  local out = {}
  for _, spec in ipairs(list) do
    local name = type(spec) == "table" and nn(spec.column) or spec
    local i = by_name[tostring(name)]
    if not i then
      require("dbdash.util.error").raise(
        "render",
        ("column_list: no column '%s' in the result"):format(tostring(name))
      )
    end
    out[#out + 1] = i
  end
  return out
end

---A cell as text: strings as they are, other values as the table shows them.
local function cell_text(v, ltype)
  if v == nil or v == vim.NIL then
    return M.NULL
  end
  if type(v) == "string" and ltype ~= "bytes" then
    return v
  end
  return (tbl.value_text(v, ltype, ""))
end

---@return dbdash.dom.Node lines
function M.build(chart, rs, show)
  local root = require("dbdash.css").scope(chart):part("lines")
  local cols = columns(rs, show)
  local sep = nn(show.separator) or " "
  local rules = {}
  for _, r in ipairs(nn(show.highlight) or {}) do
    local ok, re = pcall(vim.regex, tostring(nn(r.pattern) or ""))
    if not ok then
      require("dbdash.util.error").raise(
        "render",
        ("show.highlight: invalid pattern %q"):format(tostring(nn(r.pattern)))
      )
    end
    rules[#rules + 1] = { re = re, class = nn(r.class) or "warning" }
  end
  local rows = rs.rows
  if nn(show.reverse) == true then
    rows = {}
    for k = #rs.rows, 1, -1 do
      rows[#rows + 1] = rs.rows[k]
    end
  end
  content.set(root, { data = { total = #rs.rows, truncated = rs.truncated or false } })
  content.children(root, "line", rows, function(row)
    local parts = {}
    for k, i in ipairs(cols) do
      parts[k] = cell_text(row[i], rs.columns[i].type)
    end
    local text = table.concat(parts, sep):gsub("\r\n", "\n"):gsub("\r", "")
    local plain = text:gsub(M.NULL, "")
    for _, r in ipairs(rules) do
      if r.re:match_str(plain) then
        return { text = text, classes = { r.class } }
      end
    end
    return { text = text }
  end)
  return root
end

return M
