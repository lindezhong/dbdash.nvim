-- text/plain: the result as plain text, without a table. Each row is one piece of text:
-- its cells joined by show.separator (" "), NULL as cell.null { content } (""); newlines
-- in a cell start new lines, tabs expand to 8-column stops. show.column_list picks and
-- orders the columns, show.reverse puts the last row first, show.highlight gives lines
-- that match a pattern a class.
-- Appearance (CSS): line { text-align, white-space (nowrap: cut instead of wrapping),
-- word-break (break-all), text-overflow, color }, line.<class>, line-number { display:
-- block }, chart { line-clamp: N } (lines shown).
local W = require("dbdash.util.width")

local M = {}

local function nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
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
  local style = require("dbdash.css.style")
  local hl = require("dbdash.css.hl")
  -- the lines' DOM (render/content/text.lua), one line element per row
  local root = require("dbdash.render.content").build(css.node, rs, show)
  local line_nodes = require("dbdash.render.content").list(root, "line")
  local null_text = css:get("cell", { classes = { "null" } }).content or ""
  local lines, hls = {}, {}
  local title = nn(show.title)
  if title and title ~= "" then
    local t = W.truncate(title, ctx.width)
    lines[1] = t
    hls[1] = { row = 0, col_s = 0, col_e = #t, group = css:hl("title") }
  end
  if root.data.total == 0 then
    lines[#lines + 1] = "(no rows)"
    hls[#hls + 1] =
      { row = #lines - 1, col_s = 0, col_e = #"(no rows)", group = ctx.css:hl("note") }
    return { lines = lines, hl = hls }
  end
  -- After Bootstrap's text utilities and log viewers: line { text-align, white-space,
  -- word-break, text-overflow, color } per line element, line-number { display: block }
  -- (the lines' marker, like li::marker), chart { line-clamp } ("… N more lines").
  local numbers = css:get("line-number").display ~= "none"
  local body = {} -- { text, group, n, align }
  local nw = numbers and (#tostring(#line_nodes) + 1) or 0
  local width = math.max(ctx.width - nw, 10)
  local NULL = require("dbdash.render.content.text").NULL
  for n, ln in ipairs(line_nodes) do
    local ls = style.get(ln)
    local text = ln.text or ""
    if text:find(NULL, 1, true) then
      text = text:gsub(NULL, null_text)
    end
    local group = hl.group(ls)
    local align = ls["text-align"] ~= "start" and ls["text-align"] or "left"
    local first = true
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      line = expand_tabs(line)
      local pieces
      if ls["white-space"] ~= "nowrap" then
        pieces = W.wrap(line, width, ls["word-break"] == "break-all" and "char" or "word")
      else
        -- CSS text-overflow: clip by default (the UA sheet), a string to mark the cut
        pieces = { W.truncate(line, width, require("dbdash.render").ellipsis(ls)) }
      end
      for _, piece in ipairs(pieces) do
        body[#body + 1] =
          { text = piece, group = group, n = first and n or nil, align = align, node = ln }
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
  local hits = {}
  for _, b in ipairs(body) do
    -- the line element's screen lines (hit testing)
    local last = hits[#hits]
    if last and last.node == b.node then
      last.row_e = #lines
    else
      hits[#hits + 1] = { row_s = #lines, row_e = #lines, node = b.node }
    end
    local prefix = ""
    if numbers then
      prefix = b.n and (string.rep(" ", nw - 1 - #tostring(b.n)) .. b.n .. " ")
        or string.rep(" ", nw)
    end
    local gap = width - W.width(b.text)
    local lead = b.align == "center" and math.floor(gap / 2) or (b.align == "right" and gap or 0)
    local line = prefix .. string.rep(" ", math.max(lead, 0)) .. b.text
    lines[#lines + 1] = line
    if numbers and b.n then
      hls[#hls + 1] =
        { row = #lines - 1, col_s = 0, col_e = #prefix, group = ctx.css:hl("line-number") }
    end
    if b.text ~= "" then
      hls[#hls + 1] = { row = #lines - 1, col_s = #line - #b.text, col_e = #line, group = b.group }
    end
  end
  if hidden > 0 then
    local note = ("… %d more lines (chart line-clamp)"):format(hidden)
    lines[#lines + 1] = note
    hls[#hls + 1] = { row = #lines - 1, col_s = 0, col_e = #note, group = ctx.css:hl("note") }
  end
  if root.data.truncated then
    local note = ("… showing the first %d rows (query.max_rows)"):format(root.data.total)
    lines[#lines + 1] = note
    hls[#hls + 1] = { row = #lines - 1, col_s = 0, col_e = #note, group = ctx.css:hl("note") }
  end
  return { lines = lines, hl = hls, hits = hits }
end

return M
