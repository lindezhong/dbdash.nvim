-- Table renderer, "box" style (design §11.1), modeled after rich's default table:
--
--   ┏━━━━┳━━━━━━━┓
--   ┃ id ┃ name  ┃
--   ┡━━━━╇━━━━━━━┩
--   │  1 │ Alice │
--   └────┴───────┘
--
-- show.column_list: [{column, alias, width, height}] selects and labels columns (all by
-- default); width and height limit a column's cells.
-- show.style: border (true), header_style, border_style, title_style, show_lines (false),
--             null_text ("NULL"), wrap (true: long cells wrap at spaces; "char": anywhere;
--             false: one line, cut with "…"), cell_width / cell_height (every column's
--             limits). A cell still longer than its height ends with "…".
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

---Display text for a cell value. Line breaks become "↵" unless `keep_lines` (wrapping
---tables break the cell there).
---@return string text, boolean is_null
function M.format_value(v, ltype, null_text, keep_lines)
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
  s = s:gsub("\r\n?", "\n"):gsub("\t", " ")
  if not keep_lines then
    s = s:gsub("\n", "↵")
  end
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
          height = type(spec) == "table" and tonumber(nn(spec.height)) or nil,
          format = type(spec) == "table" and nn(spec.format) or nil,
          style = type(spec) == "table" and nn(spec.style) or nil,
          align = (type(spec) == "table" and nn(spec.align)) or ((ltype and NUMERIC[ltype]) and "right" or "left"),
          ltype = ltype,
          thresholds = type(spec) == "table" and nn(spec.thresholds) and require("dbdash.render.thresholds").steps(
            spec.thresholds,
            nn(spec.thresholds_below) == true
          ) or nil,
          below = type(spec) == "table" and nn(spec.thresholds_below) == true,
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
  local wrap = nn(style.wrap)
  local wrap_mode = wrap == "char" and "char" or (wrap ~= false and "word" or nil)
  local cell_w, cell_h = tonumber(nn(style.cell_width)), tonumber(nn(style.cell_height))

  local cols = select_columns(rs, show)
  for _, col in ipairs(cols) do
    col.width = col.width or cell_w
    col.height = col.height or cell_h
  end
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

  -- Rows to show: sorted (DataTables order) and at most max_rows_shown.
  local rows = rs.rows
  local sort = nn(style.sort)
  if sort then
    local sc = type(sort) == "table" and nn(sort.column) or sort
    local desc = type(sort) == "table" and nn(sort.order) == "desc"
    local si = rs:col_index(sc)
    if not si then
      error({ phase = "render", message = ("style.sort: no column '%s'"):format(tostring(sc)) }, 0)
    end
    rows = vim.list_extend({}, rows)
    local function key(r)
      local v = r[si]
      if v == vim.NIL then
        return nil
      end
      return v
    end
    table.sort(rows, function(a, b)
      local x, y = key(a), key(b)
      if x == nil or y == nil then
        return y == nil and x ~= nil -- NULLs last
      end
      if type(x) ~= type(y) then
        x, y = tostring(x), tostring(y)
      end
      if desc then
        return x > y
      end
      return x < y
    end)
  end
  local hidden = 0
  local limit = tonumber(nn(style.max_rows_shown))
  if limit and #rows > limit then
    hidden = #rows - limit
    rows = { unpack(rows, 1, limit) }
  end
  -- Whole rows colored by one column's thresholds (AG Grid rowStyle).
  local row_th = nn(style.row_thresholds)
  local row_steps, row_col, row_below
  if row_th then
    local T = require("dbdash.render.thresholds")
    row_col = rs:col_index(nn(row_th.column) or "")
    if not row_col then
      error({ phase = "render", message = "style.row_thresholds: no column '" .. tostring(nn(row_th.column)) .. "'" }, 0)
    end
    row_below = nn(row_th.below) == true
    row_steps = T.steps(nn(row_th.steps) or {}, row_below)
  end
  for _, col in ipairs(cols) do
    col.group = col.style and ctx.color(col.style) or nil
  end

  -- Cell texts and natural widths.
  local cells = {}
  local row_groups = {}
  local widths, data_w = {}, {}
  for c, col in ipairs(cols) do
    widths[c] = col.width or W.width(col.label)
    data_w[c] = 0
  end
  for r, row in ipairs(rows) do
    cells[r] = {}
    if row_steps then
      local T = require("dbdash.render.thresholds")
      local _, step = T.level(row[row_col], row_steps, row_below)
      row_groups[r] = step and T.group(step) or nil
    end
    for c, col in ipairs(cols) do
      local v
      if col.index then
        v = row[col.index] -- not `and ... or nil`: that turned false into NULL
      end
      local text, is_null = M.format_value(v, col.ltype, null_text, wrap_mode ~= nil)
      if col.format and type(v) == "number" then
        text = require("dbdash.render.format").python(v, col.format) or text
      end
      local group
      if col.thresholds and not is_null then
        local T = require("dbdash.render.thresholds")
        local _, step = T.level(v, col.thresholds, col.below)
        group = T.group(step)
      end
      cells[r][c] = { text = text, null = is_null, group = group }
      local tw = 0
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        tw = math.max(tw, W.width(line))
      end
      data_w[c] = math.max(data_w[c], tw)
      if not col.width then
        widths[c] = math.max(widths[c], tw)
      end
    end
  end

  -- Box-drawing: the default mixes a heavy header with a light body (like rich);
  -- style.border picks one line style for all (CSS border-style), false / "none" drops it.
  local B = require("dbdash.render.borders")
  local chars = border and B.get(nn(style.border), "single") or nil
  local rich = border and (nn(style.border) == nil or nn(style.border) == true)
  border = chars ~= nil
  local pad = math.max(tonumber(nn(style.cell_padding)) or 1, 0)
  local sp = string.rep(" ", pad)
  local valign = nn(style.vertical_align) or "top"
  local ellipsis = nn(style.ellipsis) or "…"
  local striped = nn(style.striped) and ctx.color("on " .. tostring(style.striped):gsub("^on%s+", "")) or nil

  -- Overhead: the bars around and between the columns and the padding of every cell.
  local overhead = border and (#cols + 1 + 2 * pad * #cols) or (math.max(2 * pad, 1) * (#cols - 1))
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
    local gap = string.rep(" ", math.max(2 * pad, 1))
    for c, col in ipairs(cols) do
      if border then
        put(vbar, g_border)
        put(sp)
      elseif c > 1 then
        put(gap)
      end
      put(W.pad(texts[c], widths[c], col.align), groups[c])
      if border then
        put(sp)
      end
    end
    if border then
      put(vbar, g_border)
    end
    return table.concat(parts), spans
  end

  local function rule(left, fill, mid, right)
    local segs = {}
    for c = 1, #cols do
      segs[c] = fill:rep(widths[c] + 2 * pad)
    end
    local s = left .. table.concat(segs, mid) .. right
    return s, { { 0, #s, g_border } }
  end

  ---The lines of a cell in its column: wrapped (or cut) to the width, at most the height.
  local function cell_lines(text, c)
    local w, out = widths[c], {}
    if not wrap_mode then
      return { W.truncate(text, w, ellipsis) }
    end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      vim.list_extend(out, W.wrap(line, w, wrap_mode))
    end
    return W.clamp(out, cols[c].height, w, ellipsis)
  end

  -- Header (its labels wrap like cells, without a height limit).
  local labels, hgroups = {}, {}
  for c, col in ipairs(cols) do
    labels[c] = col.label
    hgroups[c] = g_header
  end
  local head_lines, hn = {}, 1
  for c = 1, #cols do
    if wrap_mode then
      head_lines[c] = {}
      for _, l in ipairs(W.wrap(labels[c], widths[c], wrap_mode)) do
        head_lines[c][#head_lines[c] + 1] = l
      end
    else
      head_lines[c] = { W.truncate(labels[c], widths[c], ellipsis) }
    end
    hn = math.max(hn, #head_lines[c])
  end
  local function header_rows(vbar)
    for k = 1, hn do
      local texts = {}
      for c = 1, #cols do
        texts[c] = head_lines[c][k] or ""
      end
      add(row_line(texts, hgroups, vbar))
    end
  end
  if rich then
    add(rule("┏", "━", "┳", "┓"))
    header_rows("┃")
    add(rule("┡", "━", "╇", "┩"))
  elseif border then
    add(rule(chars.tl, chars.h, chars.tt, chars.tr))
    header_rows(chars.v)
    add(rule(chars.lt, chars.h, chars.x, chars.rt))
  else
    header_rows("")
    local segs = {}
    for c = 1, #cols do
      segs[c] = ("─"):rep(widths[c])
    end
    local s = table.concat(segs, string.rep(" ", math.max(2 * pad, 1)))
    add(s, { { 0, #s, g_border } })
  end
  local v = rich and "│" or (chars and chars.v or "")

  for r, row in ipairs(cells) do
    if show_lines and r > 1 and border then
      if rich then
        add(rule("├", "─", "┼", "┤"))
      else
        add(rule(chars.lt, chars.h, chars.x, chars.rt))
      end
    end
    local parts, groups, n = {}, {}, 1
    for c, cell in ipairs(row) do
      parts[c] = cell_lines(cell.text, c)
      n = math.max(n, #parts[c])
      groups[c] = cell.null and "DbDashNull" or cell.group or row_groups[r] or cols[c].group
    end
    for k = 1, n do
      local texts = {}
      for c = 1, #cols do
        -- CSS vertical-align of a cell shorter than its row
        local free = n - #parts[c]
        local skip = valign == "middle" and math.floor(free / 2) or (valign == "bottom" and free or 0)
        texts[c] = parts[c][k - skip] or ""
      end
      add(row_line(texts, groups, v))
      if striped and r % 2 == 0 then
        table.insert(hl, { row = #lines - 1, col_s = 0, col_e = #lines[#lines], group = striped, priority = 50 })
      end
    end
  end
  if border then
    if rich then
      add(rule("└", "─", "┴", "┘"))
    else
      add(rule(chars.bl, chars.h, chars.bt, chars.br))
    end
  end

  local note
  if #rs.rows == 0 then
    note = "(no rows)"
  elseif hidden > 0 then
    note = ("… %d more rows (style.max_rows_shown)"):format(hidden)
  elseif rs.truncated then
    note = ("… showing the first %d rows (query.max_rows)"):format(#rs.rows)
  end
  if note then
    add(note, { { 0, #note, "DbDashMuted" } })
  end
  return { lines = lines, hl = hl }
end

return M
