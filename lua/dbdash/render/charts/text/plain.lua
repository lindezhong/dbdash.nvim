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
    hl[1] = { row = 0, col_s = 0, col_e = #t, group = ctx.color(nn(style.title_style), "DbDashTitle") }
  end
  if #rs.rows == 0 then
    lines[#lines + 1] = "(no rows)"
    hl[#hl + 1] = { row = #lines - 1, col_s = 0, col_e = #"(no rows)", group = "DbDashMuted" }
    return { lines = lines, hl = hl }
  end
  local cols = columns(rs, show)
  for _, row in ipairs(rs.rows) do
    local parts = {}
    for k, i in ipairs(cols) do
      parts[k] = cell_text(row[i], rs.columns[i].type, null_text)
    end
    local text = table.concat(parts, sep):gsub("\r\n", "\n"):gsub("\r", "")
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      line = expand_tabs(line)
      if do_wrap then
        vim.list_extend(lines, W.wrap(line, ctx.width, wrap == "char" and "char" or "word"))
      else
        lines[#lines + 1] = W.truncate(line, ctx.width, "")
      end
    end
  end
  if rs.truncated then
    local note = ("… showing the first %d rows (query.max_rows)"):format(#rs.rows)
    lines[#lines + 1] = note
    hl[#hl + 1] = { row = #lines - 1, col_s = 0, col_e = #note, group = "DbDashMuted" }
  end
  return { lines = lines, hl = hl }
end

return M
