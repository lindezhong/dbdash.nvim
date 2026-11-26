-- Table renderer, "box" style (design §11.1), modeled after rich's default table:
--
--   ┏━━━━┳━━━━━━━┓
--   ┃ id ┃ name  ┃
--   ┡━━━━╇━━━━━━━┩
--   │  1 │ Alice │
--   └────┴───────┘
--
-- show.column_list: [{column, alias, align, format, thresholds}] selects and labels
-- columns (all by default); show.sort orders the rows, show.row_thresholds gives rows a
-- class. Appearance is CSS (the chart's parts):
--   table   border (rich: heavy header, light body), border-color, line-clamp (rows shown)
--   header  color; header[column=name]
--   rule    display: block draws a line between rows
--   row     background-color (row:nth-child(even) stripes), color; row.<threshold class>
--   cell    padding, width, height, white-space (nowrap: one line), word-break
--           (break-all: wrap anywhere), vertical-align, text-overflow, color;
--           cell[column=name], cell.null { content: "NULL" }, cell.<threshold class>
-- A cell still longer than its height ends with text-overflow.
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
  local css = ctx.css
  local tbl = css:get("table")
  local show_lines = css:get("rule").display ~= "none"
  local null_text = css:get("cell", { classes = { "null" } }).content or ""
  local g_border = css:border_hl("table")
  local null_hl = css:hl("cell", { classes = { "null" } })
  local cell = css:get("cell")
  local wrap_mode = cell["white-space"] ~= "nowrap" and (cell["word-break"] == "break-all" and "char" or "word") or nil

  local cols = select_columns(rs, show)
  for _, col in ipairs(cols) do
    -- per column: cell[column=name] and header[column=name]
    local cc = css:get("cell", { attrs = { column = col.label } })
    col.width = col.width or cc.width
    col.height = col.height or cc.height
    col.group = css:hl("cell", { attrs = { column = col.label } })
    col.header_group = css:hl("header", { attrs = { column = col.label } })
  end
  local lines, hl = {}, {}
  local function add(line, spans)
    lines[#lines + 1] = line
    for _, sp in ipairs(spans or {}) do
      hl[#hl + 1] = { row = #lines - 1, col_s = sp[1], col_e = sp[2], group = sp[3] }
    end
  end

  if #cols == 0 then
    add("(no columns)", { { 0, #"(no columns)", ctx.css:hl("note") } })
    return { lines = lines, hl = hl }
  end

  -- Rows to show: sorted (DataTables order) and at most max_rows_shown.
  local rows = rs.rows
  local sort = nn(show.sort)
  if sort then
    local sc = type(sort) == "table" and nn(sort.column) or sort
    local desc = type(sort) == "table" and nn(sort.order) == "desc"
    local si = rs:col_index(sc)
    if not si then
      error({ phase = "render", message = ("show.sort: no column '%s'"):format(tostring(sc)) }, 0)
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
  local limit = tbl["line-clamp"]
  if limit and #rows > limit then
    hidden = #rows - limit
    rows = { unpack(rows, 1, limit) }
  end
  -- Whole rows colored by one column's thresholds (AG Grid rowStyle).
  local row_th = nn(show.row_thresholds)
  local row_steps, row_col, row_below
  if row_th then
    local T = require("dbdash.render.thresholds")
    row_col = rs:col_index(nn(row_th.column) or "")
    if not row_col then
      error({ phase = "render", message = "show.row_thresholds: no column '" .. tostring(nn(row_th.column)) .. "'" }, 0)
    end
    row_below = nn(row_th.below) == true
    row_steps = T.steps(nn(row_th.steps) or {}, row_below)
  end

  -- Cell texts and natural widths.
  local cells = {}
  local row_groups, row_bg = {}, {}
  local widths, data_w = {}, {}
  for c, col in ipairs(cols) do
    widths[c] = col.width or W.width(col.label)
    data_w[c] = 0
  end
  for r, row in ipairs(rows) do
    cells[r] = {}
    local row_classes = {}
    if row_steps then
      local T = require("dbdash.render.thresholds")
      local _, step = T.level(row[row_col], row_steps, row_below)
      row_classes = T.classes(step)
    end
    -- the row element: its color (threshold classes) and background (:nth-child stripes)
    local rc = css:get("row", { classes = row_classes, index = r })
    row_groups[r] = require("dbdash.css.hl").group({ color = rc.color, ["font-weight"] = rc["font-weight"] })
    row_bg[r] = rc["background-color"] and require("dbdash.css.hl").group({ ["background-color"] = rc["background-color"] }) or nil
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
        if step and step.class then
          group = css:hl("cell", { classes = { step.class }, attrs = { column = col.label } })
        end
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

  -- Box-drawing: "rich" (the default) mixes a heavy header with a light body (like rich);
  -- another border style draws all lines with it, none drops them.
  local B = require("dbdash.render.borders")
  local rich = tbl.border == "rich"
  local chars = tbl.border ~= "none" and B.get(rich and "single" or tbl.border, "single") or nil
  local border = chars ~= nil
  local pad = cell.padding[2]
  local sp = string.rep(" ", pad)
  local valign = cell["vertical-align"]
  local ellipsis = require("dbdash.render").ellipsis(cell)

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
    hgroups[c] = col.header_group
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
      groups[c] = cell.null and null_hl or cell.group or row_groups[r] or cols[c].group
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
      if row_bg[r] then
        table.insert(hl, { row = #lines - 1, col_s = 0, col_e = #lines[#lines], group = row_bg[r], priority = 50 })
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
    note = ("… %d more rows (table line-clamp)"):format(hidden)
  elseif rs.truncated then
    note = ("… showing the first %d rows (query.max_rows)"):format(#rs.rows)
  end
  if note then
    add(note, { { 0, #note, ctx.css:hl("note") } })
  end
  return { lines = lines, hl = hl }
end

return M
