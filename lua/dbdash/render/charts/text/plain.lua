-- text/plain: the result as plain text, without a table. Each row is one piece of text:
-- its cells joined by style.separator (" "), NULL as style.null_text (""); newlines in a
-- cell start new lines, tabs expand to 8-column stops. Lines wider than the panel wrap
-- (style.wrap = false cuts them instead). show.column_list picks and orders the columns.
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
  local style = nn(show.style) or {}
  local sep = nn(style.separator) or " "
  local null_text = nn(style.null_text) or ""
  local wrap = nn(style.wrap)
  local do_wrap = wrap ~= false
  local lines, hl = {}, {}
  local title = nn(show.title)
  if title and title ~= "" then
    local t = W.truncate(title, ctx.width)
    lines[1] = t
    hl[1] = { row = 0, col_s = 0, col_e = #t, group = ctx.color(nn(style.title_style), ctx.css:hl("title")) }
  end
  if #rs.rows == 0 then
    lines[#lines + 1] = "(no rows)"
    hl[#hl + 1] = { row = #lines - 1, col_s = 0, col_e = #"(no rows)", group = ctx.css:hl("note") }
    return { lines = lines, hl = hl }
  end
  local cols = columns(rs, show)
  -- Options after Bootstrap's text utilities and log viewers: style.text_align (left, center,
  -- right), style.reverse (the last row first), style.line_numbers, style.max_lines
  -- ("… N more lines"), style.highlight: [{ pattern (a Vim regex), color }] colors the
  -- lines that match (the first matching rule wins).
  local align = nn(style.text_align) or "left"
  local numbers = nn(style.line_numbers) == true
  local rules = {}
  for _, r in ipairs(nn(style.highlight) or {}) do
    local ok, re = pcall(vim.regex, tostring(nn(r.pattern) or ""))
    if not ok then
      error({ phase = "render", message = ("style.highlight: invalid pattern %q"):format(tostring(nn(r.pattern))) }, 0)
    end
    rules[#rules + 1] = { re = re, group = ctx.color(nn(r.color), ctx.css:hl("warning")) }
  end
  local rows = rs.rows
  if nn(style.reverse) == true then
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
    local group = ctx.css:hl("line")
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
        pieces = W.wrap(line, width, wrap == "char" and "char" or "word")
      else
        -- CSS text-overflow: clip by default, style.ellipsis to mark the cut
        pieces = { W.truncate(line, width, nn(style.ellipsis) or "") }
      end
      for _, piece in ipairs(pieces) do
        body[#body + 1] = { text = piece, group = group, n = first and n or nil }
        first = false
      end
    end
  end
  local max = tonumber(nn(style.max_lines))
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
    local note = ("… %d more lines (style.max_lines)"):format(hidden)
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
