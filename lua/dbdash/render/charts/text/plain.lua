-- text/plain: the result as plain text, without a table. Each row is one piece of text:
-- its cells joined by show.separator (" "), NULL as cell.null { content } (""); newlines
-- in a cell start new lines, tabs expand to 8-column stops. show.column_list picks and
-- orders the columns, show.reverse puts the last row first, show.highlight gives lines
-- that match a pattern a class.
-- Appearance (CSS): line { text-align, white-space (nowrap: cut instead of wrapping),
-- word-break (break-all), text-overflow, color }, line.<class>, line-number { display:
-- block }, chart { line-clamp: N } (lines shown).
local W = require("dbdash.util.width")
local tbl = require("dbdash.render.table")

local M = {}

local function nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
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
      error({ phase = "render", message = ("column_list: no column '%s' in the result"):format(tostring(name)) }, 0)
    end
    out[#out + 1] = i
  end
  return out
end

---A cell as text: strings as they are, other values as the table shows them.
local function cell_text(v, ltype, null_text)
  if v == nil or v == vim.NIL then
    return null_text
  end
  if type(v) == "string" and ltype ~= "bytes" then
    return v
  end
  local s = tbl.format_value(v, ltype, null_text)
  return s
end

---Expand tabs to 8-column stops (by display width).
local function expand_tabs(line)
  if not line:find("\t", 1, true) then
    return line
  end
  local out, col = {}, 0
  for ch in W.chars(line) do
    if ch == "\t" then
      local n = 8 - col % 8
      out[#out + 1] = (" "):rep(n)
      col = col + n
    else
      out[#out + 1] = ch
      col = col + W.width(ch)
    end
  end
  return table.concat(out)
end

---@param rs dbdash.db.ResultSet
---@param show table
---@param ctx dbdash.render.Ctx
---@return dbdash.render.Output
function M.render(rs, show, ctx)
  local css = ctx.css
  local line_style = css:get("line")
  local sep = nn(show.separator) or " "
  local null_text = css:get("cell", { classes = { "null" } }).content or ""
  local do_wrap = line_style["white-space"] ~= "nowrap"
  local lines, hl = {}, {}
  local title = nn(show.title)
  if title and title ~= "" then
    local t = W.truncate(title, ctx.width)
    lines[1] = t
    hl[1] = { row = 0, col_s = 0, col_e = #t, group = css:hl("title") }
  end
  if #rs.rows == 0 then
    lines[#lines + 1] = "(no rows)"
    hl[#hl + 1] = { row = #lines - 1, col_s = 0, col_e = #"(no rows)", group = ctx.css:hl("note") }
    return { lines = lines, hl = hl }
  end
  local cols = columns(rs, show)
  -- After Bootstrap's text utilities and log viewers: line { text-align }, show.reverse
  -- (the last row first), line-number { display: block }, chart { line-clamp } ("… N more
  -- lines"), show.highlight: [{ pattern (a Vim regex), class }] puts the class on the lines
  -- that match (the first matching rule wins; default class: warning).
  local align = line_style["text-align"] ~= "start" and line_style["text-align"] or "left"
  local numbers = css:get("line-number").display ~= "none"
  local rules = {}
  for _, r in ipairs(nn(show.highlight) or {}) do
    local ok, re = pcall(vim.regex, tostring(nn(r.pattern) or ""))
    if not ok then
      error({ phase = "render", message = ("show.highlight: invalid pattern %q"):format(tostring(nn(r.pattern))) }, 0)
    end
    rules[#rules + 1] = { re = re, group = css:hl("line", { classes = { nn(r.class) or "warning" } }) }
  end
  local rows = rs.rows
  if nn(show.reverse) == true then
    rows = {}
    for k = #rs.rows, 1, -1 do
      rows[#rows + 1] = rs.rows[k]
    end
  end
  local body = {} -- { text, group }
  local nw = numbers and (#tostring(#rows) + 1) or 0
  local width = math.max(ctx.width - nw, 10)
  for n, row in ipairs(rows) do
    local parts = {}
    for k, i in ipairs(cols) do
      parts[k] = cell_text(row[i], rs.columns[i].type, null_text)
    end
    local text = table.concat(parts, sep):gsub("\r\n", "\n"):gsub("\r", "")
    local group = css:hl("line")
    for _, r in ipairs(rules) do
      if r.re:match_str(text) then
        group = r.group
        break
      end
    end
    local first = true
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      line = expand_tabs(line)
      local pieces
      if do_wrap then
        pieces = W.wrap(line, width, line_style["word-break"] == "break-all" and "char" or "word")
      else
        -- CSS text-overflow: clip by default (the UA sheet), a string to mark the cut
        pieces = { W.truncate(line, width, require("dbdash.render").ellipsis(line_style)) }
      end
      for _, piece in ipairs(pieces) do
        body[#body + 1] = { text = piece, group = group, n = first and n or nil }
        first = false
      end
    end
  end
  local max = css:get()["line-clamp"]
  local hidden = 0
  if max and #body > max then
    hidden = #body - max
    body = { unpack(body, 1, max) }
  end
  for _, b in ipairs(body) do
    local prefix = ""
    if numbers then
      prefix = b.n and (string.rep(" ", nw - 1 - #tostring(b.n)) .. b.n .. " ") or string.rep(" ", nw)
    end
    local gap = width - W.width(b.text)
    local lead = align == "center" and math.floor(gap / 2) or (align == "right" and gap or 0)
    local line = prefix .. string.rep(" ", math.max(lead, 0)) .. b.text
    lines[#lines + 1] = line
    if numbers and b.n then
      hl[#hl + 1] = { row = #lines - 1, col_s = 0, col_e = #prefix, group = ctx.css:hl("line-number") }
    end
    if b.text ~= "" then
      hl[#hl + 1] = { row = #lines - 1, col_s = #line - #b.text, col_e = #line, group = b.group }
    end
  end
  if hidden > 0 then
    local note = ("… %d more lines (chart line-clamp)"):format(hidden)
    lines[#lines + 1] = note
    hl[#hl + 1] = { row = #lines - 1, col_s = 0, col_e = #note, group = ctx.css:hl("note") }
  end
  if rs.truncated then
    local note = ("… showing the first %d rows (query.max_rows)"):format(#rs.rows)
    lines[#lines + 1] = note
    hl[#hl + 1] = { row = #lines - 1, col_s = 0, col_e = #note, group = ctx.css:hl("note") }
  end
  return { lines = lines, hl = hl }
end

return M
