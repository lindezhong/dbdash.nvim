-- Table renderer, "box" style (design §11.1), modeled after rich's default table:
--
--   ┏━━━━┳━━━━━━━┓
--   ┃ id ┃ name  ┃
--   ┡━━━━╇━━━━━━━┩
--   │  1 │ Alice │
--   └────┴───────┘
--
-- show.column_list: [{column, alias, width}] selects and labels columns (all by default).
-- show.style: border (true), header_style, border_style, title_style, show_lines (false),
--             null_text ("NULL").
local W = require("dbdash.util.width")

local M = { name = "box" }

local NUMERIC = { integer = true, number = true, decimal = true }
local MIN_COL = 3

local function nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---Display text for a cell value.
---@return string text, boolean is_null
function M.format_value(v, ltype, null_text)
  if v == nil or v == vim.NIL then
    return null_text, true
  end
  local t = type(v)
  local s
  if t == "string" then
    if ltype == "bytes" then
      s = "\\x" .. require("dbdash.db.resultset").hex(v)
    else
      s = v
    end
  elseif t == "number" then
    s = require("dbdash.template.runtime").numstr(v)
  elseif t == "boolean" then
    s = v and "true" or "false"
  elseif t == "table" then
    local ok, j = pcall(vim.json.encode, v)
    s = ok and j or tostring(v)
  else
    s = tostring(v)
  end
  s = s:gsub("\r?\n", "↵"):gsub("\t", " ")
  return s, false
end

---Resolve which columns to show: list of {index, label, width?, align}.
local function select_columns(rs, show)
  local cols = {}
  local list = nn(show.column_list)
  if list and #list > 0 then
    for _, spec in ipairs(list) do
      local name = type(spec) == "string" and spec or nn(spec.column)
      if name then
        local idx = rs:col_index(name)
        local ltype = idx and rs.columns[idx].type
        cols[#cols + 1] = {
          index = idx,
          label = type(spec) == "table" and nn(spec.alias) or name,
          width = type(spec) == "table" and tonumber(nn(spec.width)) or nil,
          align = (ltype and NUMERIC[ltype]) and "right" or "left",
          ltype = ltype,
        }
      end
    end
  else
    for i, c in ipairs(rs.columns) do
      cols[#cols + 1] = {
        index = i,
        label = c.name,
        align = NUMERIC[c.type] and "right" or "left",
        ltype = c.type,
      }
    end
  end
  return cols
end

---Shrink columns until the total fits, in order of least damage: text columns first, then
---numeric headers wider than their values, and numbers themselves only as a last resort.
local function fit(widths, budget, cols, data_w)
  local total = 0
  for _, w in ipairs(widths) do
    total = total + w
  end
  local passes = {
    function(i, w)
      return cols[i].align ~= "right" and w > MIN_COL
    end,
    function(i, w)
      return w > math.max(data_w[i], MIN_COL)
    end,
    function(_, w)
      return w > MIN_COL
    end,
  }
  while total > budget do
    local wi
    for _, ok in ipairs(passes) do
      local wv = 0
      for i, w in ipairs(widths) do
        if ok(i, w) and w > wv then
          wi, wv = i, w
        end
      end
      if wi then
        break
      end
    end
    if not wi then
      break
    end
    widths[wi] = widths[wi] - 1
    total = total - 1
  end
end

---@param rs dbdash.db.ResultSet
---@param show table
---@param ctx dbdash.render.Ctx
---@return dbdash.render.Output
function M.render(rs, show, ctx)
  local style = nn(show.style) or {}
  local border = nn(style.border) ~= false
  local show_lines = nn(style.show_lines) == true
  local null_text = nn(style.null_text) or "NULL"
  local g_border = ctx.color(nn(style.border_style), "DbDashBorder")
  local g_header = ctx.color(nn(style.header_style), "DbDashHeader")
  local g_title = ctx.color(nn(style.title_style), "DbDashTitle")

  local cols = select_columns(rs, show)
  local lines, hl = {}, {}
  local function add(line, spans)
    lines[#lines + 1] = line
    for _, sp in ipairs(spans or {}) do
      hl[#hl + 1] = { row = #lines - 1, col_s = sp[1], col_e = sp[2], group = sp[3] }
    end
  end

  if #cols == 0 then
    add("(no columns)", { { 0, #"(no columns)", "DbDashMuted" } })
    return { lines = lines, hl = hl }
  end

  -- Cell texts and natural widths.
  local cells = {}
  local widths, data_w = {}, {}
  for c, col in ipairs(cols) do
    widths[c] = col.width or W.width(col.label)
    data_w[c] = 0
  end
  for r, row in ipairs(rs.rows) do
    cells[r] = {}
    for c, col in ipairs(cols) do
      local text, is_null = M.format_value(col.index and row[col.index] or nil, col.ltype, null_text)
      cells[r][c] = { text = text, null = is_null }
      data_w[c] = math.max(data_w[c], W.width(text))
      if not col.width then
        widths[c] = math.max(widths[c], W.width(text))
      end
    end
  end

  -- Border overhead: "┃ " + " ┃" around the row and " ┃ " between columns.
  local overhead = border and (4 + 3 * (#cols - 1)) or 2 * (#cols - 1)
  fit(widths, math.max(ctx.width - overhead, MIN_COL * #cols), cols, data_w)

  ---Build one row line from cell texts; returns line and highlight spans.
  local function row_line(texts, groups, vbar)
    local parts, spans, pos = {}, {}, 0
    local function put(s, group)
      if group then
        spans[#spans + 1] = { pos, pos + #s, group }
      end
      parts[#parts + 1] = s
      pos = pos + #s
    end
    for c, col in ipairs(cols) do
      if border then
        put(c == 1 and vbar or (" " .. vbar), g_border)
        put(" ")
      elseif c > 1 then
        put("  ")
      end
      put(W.pad(texts[c], widths[c], col.align), groups[c])
    end
    if border then
      put(" " .. vbar, g_border)
    end
    return table.concat(parts), spans
  end

  local function rule(left, fill, mid, right)
    local segs = {}
    for c = 1, #cols do
      segs[c] = fill:rep(widths[c] + 2)
    end
    local s = left .. table.concat(segs, mid) .. right
    return s, { { 0, #s, g_border } }
  end

  local total_w = overhead
  for _, w in ipairs(widths) do
    total_w = total_w + w
  end

  local title = nn(show.title)
  if title and title ~= "" then
    local t = W.pad(title, math.min(total_w, ctx.width), "center"):gsub("%s+$", "")
    local lead = #t:match("^%s*")
    add(t, { { lead, #t, g_title } })
  end

  -- Header.
  local labels, hgroups = {}, {}
  for c, col in ipairs(cols) do
    labels[c] = col.label
    hgroups[c] = g_header
  end
  if border then
    add(rule("┏", "━", "┳", "┓"))
    add(row_line(labels, hgroups, "┃"))
    add(rule("┡", "━", "╇", "┩"))
  else
    add(row_line(labels, hgroups, ""))
    local segs = {}
    for c = 1, #cols do
      segs[c] = ("─"):rep(widths[c])
    end
    local s = table.concat(segs, "  ")
    add(s, { { 0, #s, g_border } })
  end

  for r, row in ipairs(cells) do
    if show_lines and r > 1 and border then
      add(rule("├", "─", "┼", "┤"))
    end
    local texts, groups = {}, {}
    for c, cell in ipairs(row) do
      texts[c] = cell.text
      groups[c] = cell.null and "DbDashNull" or nil
    end
    add(row_line(texts, groups, "│"))
  end
  if border then
    add(rule("└", "─", "┴", "┘"))
  end

  local note
  if #rs.rows == 0 then
    note = "(no rows)"
  elseif rs.truncated then
    note = ("… showing the first %d rows (query.max_rows)"):format(#rs.rows)
  end
  if note then
    add(note, { { 0, #note, "DbDashMuted" } })
  end
  return { lines = lines, hl = hl }
end

return M
