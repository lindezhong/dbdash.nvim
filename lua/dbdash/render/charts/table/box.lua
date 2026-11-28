-- Table renderer, "box" style (:help dbdash-charts), modeled after rich's default table:
--
--   ┏━━━━┳━━━━━━━┓
--   ┃ id ┃ name  ┃
--   ┡━━━━╇━━━━━━━┩
--   │  1 │ Alice │
--   └────┴───────┘
--
-- The table is laid out from its DOM (render/content/table.lua: table > header, row > cell,
-- built from the result with show.column_list, show.sort and the thresholds' classes);
-- appearance is each element's computed style:
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

local MIN_COL = 3

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

---What layout needs from a cell's computed style, once per (shared) style.
local function cell_settings(per_style, cs)
  local d = per_style[cs]
  if not d then
    local nowrap = cs["white-space"] == "nowrap"
    d = {
      group = require("dbdash.css.hl").group(cs),
      nowrap = nowrap,
      wrap = not nowrap and (cs["word-break"] == "break-all" and "char" or "word") or nil,
      valign = cs["vertical-align"],
      ellipsis = require("dbdash.css").ellipsis(cs),
      content = cs.content or "",
    }
    per_style[cs] = d
  end
  return d
end

---The width of a cell's text: its longest line.
local function text_width(text, multi)
  if not multi then
    return W.width(text)
  end
  local tw = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    tw = math.max(tw, W.width(line))
  end
  return tw
end

---Cell texts (a NULL cell's is its content) and natural widths (t.widths, t.data_w);
---colors are each cell's computed color (inherited from its row: row.danger colors the
---row's cells); rows with a background (t.row_bg).
local function measure(t, row_nodes)
  local style, hl = require("dbdash.css.style"), require("dbdash.css.hl")
  local cols = t.cols
  t.cells, t.row_bg, t.widths, t.data_w = {}, {}, {}, {}
  for c, col in ipairs(cols) do
    t.widths[c] = col.width or W.width(col.label)
    t.data_w[c] = 0
  end
  local per_style, bg_groups = {}, {}
  for r, rn in ipairs(row_nodes) do
    t.cells[r] = {}
    local bg = style.get(rn)["background-color"]
    if bg then
      bg_groups[bg] = bg_groups[bg] or hl.group({ ["background-color"] = bg })
      t.row_bg[r] = bg_groups[bg]
    end
    for c = 1, #cols do
      local cn = rn.children[c]
      local d = cell_settings(per_style, style.get(cn))
      local text = cn.text or d.content
      local multi = text:find("\n", 1, true) ~= nil
      if multi and d.nowrap then
        text = text:gsub("\n", "↵")
        multi = false
      end
      t.cells[r][c] = {
        text = text,
        null = cn.text == nil,
        group = d.group,
        wrap = d.wrap,
        valign = d.valign,
        ellipsis = d.ellipsis,
      }
      local tw = text_width(text, multi)
      t.data_w[c] = math.max(t.data_w[c], tw)
      if not cols[c].width then
        t.widths[c] = math.max(t.widths[c], tw)
      end
    end
  end
end

---Add a line with its highlight spans ({ col_s, col_e, group }).
local function add(t, line, spans)
  t.lines[#t.lines + 1] = line
  for _, sp in ipairs(spans or {}) do
    t.hl[#t.hl + 1] = { row = #t.lines - 1, col_s = sp[1], col_e = sp[2], group = sp[3] }
  end
end

---One row line from cell texts; returns the line and its highlight spans.
local function row_line(t, texts, groups, vbar)
  local parts, spans, pos = {}, {}, 0
  local function put(s, group)
    if group then
      spans[#spans + 1] = { pos, pos + #s, group }
    end
    parts[#parts + 1] = s
    pos = pos + #s
  end
  local sp = string.rep(" ", t.pad)
  local gap = string.rep(" ", math.max(2 * t.pad, 1))
  for c, col in ipairs(t.cols) do
    if t.border then
      put(vbar, t.g_border)
      put(sp)
    elseif c > 1 then
      put(gap)
    end
    put(W.pad(texts[c], t.widths[c], col.align), groups[c])
    if t.border then
      put(sp)
    end
  end
  if t.border then
    put(vbar, t.g_border)
  end
  return table.concat(parts), spans
end

---A rule line across the columns.
local function rule(t, left, fill, mid, right)
  local segs = {}
  for c = 1, #t.cols do
    segs[c] = fill:rep(t.widths[c] + 2 * t.pad)
  end
  local s = left .. table.concat(segs, mid) .. right
  return s, { { 0, #s, t.g_border } }
end

---The lines of a cell in its column: wrapped (or cut) to the width, at most the height.
local function cell_lines(t, cl, c)
  local w, out = t.widths[c], {}
  if not cl.wrap then
    return { W.truncate(cl.text, w, cl.ellipsis) }
  end
  for line in (cl.text .. "\n"):gmatch("([^\n]*)\n") do
    vim.list_extend(out, W.wrap(line, w, cl.wrap))
  end
  return W.clamp(out, t.cols[c].height, w, cl.ellipsis)
end

---The header: its labels wrap like cells (without a height limit), between the top rule
---and the header's rule (rich: heavy).
local function draw_header(t, cell)
  local wrap_mode = cell["white-space"] ~= "nowrap"
      and (cell["word-break"] == "break-all" and "char" or "word")
    or nil
  local ellipsis = require("dbdash.css").ellipsis(cell)
  local head_lines, hgroups, hn = {}, {}, 1
  for c, col in ipairs(t.cols) do
    hgroups[c] = col.header_group
    if wrap_mode then
      head_lines[c] = W.wrap(col.label, t.widths[c], wrap_mode)
    else
      head_lines[c] = { W.truncate(col.label, t.widths[c], ellipsis) }
    end
    hn = math.max(hn, #head_lines[c])
  end
  local function header_rows(vbar)
    for k = 1, hn do
      local texts = {}
      for c = 1, #t.cols do
        texts[c] = head_lines[c][k] or ""
      end
      add(t, row_line(t, texts, hgroups, vbar))
    end
  end
  local chars = t.chars
  if t.rich then
    add(t, rule(t, "┏", "━", "┳", "┓"))
    header_rows("┃")
    add(t, rule(t, "┡", "━", "╇", "┩"))
  elseif t.border then
    add(t, rule(t, chars.tl, chars.h, chars.tt, chars.tr))
    header_rows(chars.v)
    add(t, rule(t, chars.lt, chars.h, chars.x, chars.rt))
  else
    header_rows("")
    local segs = {}
    for c = 1, #t.cols do
      segs[c] = ("─"):rep(t.widths[c])
    end
    local s = table.concat(segs, string.rep(" ", math.max(2 * t.pad, 1)))
    add(t, s, { { 0, #s, t.g_border } })
  end
end

---One row: its lines (cells top, middle or bottom aligned), its background; returns the
---row element's lines (hit testing: :DbDashInspect on a row).
local function draw_row(t, r, row, vbar)
  local first_line = #t.lines
  local parts, groups, n = {}, {}, 1
  for c, rc in ipairs(row) do
    parts[c] = cell_lines(t, rc, c)
    n = math.max(n, #parts[c])
    groups[c] = rc.group
  end
  for k = 1, n do
    local texts = {}
    for c = 1, #t.cols do
      -- CSS vertical-align of a cell shorter than its row
      local free = n - #parts[c]
      local va = row[c].valign
      local skip = va == "middle" and math.floor(free / 2) or (va == "bottom" and free or 0)
      texts[c] = parts[c][k - skip] or ""
    end
    add(t, row_line(t, texts, groups, vbar))
    if t.row_bg[r] then
      table.insert(t.hl, {
        row = #t.lines - 1,
        col_s = 0,
        col_e = #t.lines[#t.lines],
        group = t.row_bg[r],
        priority = 50,
      })
    end
  end
  return first_line, #t.lines - 1
end

---The rows (rules between them with rule { display: block }) and the bottom rule.
local function draw_body(t, row_nodes, show_lines)
  local chars = t.chars
  local v = t.rich and "│" or (chars and chars.v or "")
  local hits = {}
  for r, row in ipairs(t.cells) do
    if show_lines and r > 1 and t.border then
      if t.rich then
        add(t, rule(t, "├", "─", "┼", "┤"))
      else
        add(t, rule(t, chars.lt, chars.h, chars.x, chars.rt))
      end
    end
    local row_s, row_e = draw_row(t, r, row, v)
    hits[#hits + 1] = { row_s = row_s, row_e = row_e, node = row_nodes[r] }
  end
  if t.border then
    if t.rich then
      add(t, rule(t, "└", "─", "┴", "┘"))
    else
      add(t, rule(t, chars.bl, chars.h, chars.bt, chars.br))
    end
  end
  return hits
end

---The columns with their widths and heights (the first row's cells) and header colors.
local function columns(tnode, row_nodes, header_nodes)
  local style, hl = require("dbdash.css.style"), require("dbdash.css.hl")
  local cols = vim.deepcopy(tnode.data.columns)
  for c, col in ipairs(cols) do
    local cn = row_nodes[1] and row_nodes[1].children[c]
    local cc = cn and style.get(cn) or {}
    col.width = col.width or cc.width
    col.height = col.height or cc.height
    col.header_group = header_nodes[c] and hl.group(style.get(header_nodes[c])) or nil
  end
  return cols
end

---@param rs dbdash.db.ResultSet
---@param _show table
---@param ctx dbdash.render.Ctx
---@return dbdash.render.Output
function M.render(rs, _show, ctx)
  local css = ctx.css
  local style = require("dbdash.css.style")
  local content = require("dbdash.render.content")
  -- the table's DOM (render/content/table.lua), built from the result before styles
  local tnode = content.root(css.node)
  if not tnode then
    return { lines = {}, hl = {} } -- nothing built (no result yet)
  end
  local tbl = style.get(tnode)
  local row_nodes = content.list(tnode, "row")
  -- table-wide cell settings: the first cell's (a cell part when there are no rows)
  local first = row_nodes[1] and content.list(row_nodes[1], "cell")[1]
  local cell = first and style.get(first) or css:get("cell")
  -- Box-drawing: "rich" (the default) mixes a heavy header with a light body (like rich);
  -- another border style draws all lines with it, none drops them.
  local rich = tbl.border == "rich"
  local chars = tbl.border ~= "none"
      and require("dbdash.render.borders").get(rich and "single" or tbl.border, "single")
    or nil
  local t = {
    cols = columns(tnode, row_nodes, content.list(tnode, "header")),
    lines = {},
    hl = {},
    rich = rich,
    chars = chars,
    border = chars ~= nil,
    pad = cell.padding[2],
    g_border = css:border_hl("table"),
  }
  if #t.cols == 0 then
    add(t, "(no columns)", { { 0, #"(no columns)", ctx.css:hl("note") } })
    return { lines = t.lines, hl = t.hl }
  end
  -- Rows shown: at most table { line-clamp }.
  local hidden = 0
  local limit = tbl["line-clamp"]
  if limit and #row_nodes > limit then
    hidden = #row_nodes - limit
    row_nodes = { unpack(row_nodes, 1, limit) }
  end
  measure(t, row_nodes)
  -- Overhead: the bars around and between the columns and the padding of every cell.
  local n, pad = #t.cols, t.pad
  local overhead = t.border and (n + 1 + 2 * pad * n) or (math.max(2 * pad, 1) * (n - 1))
  fit(t.widths, math.max(ctx.width - overhead, MIN_COL * n), t.cols, t.data_w)
  draw_header(t, cell)
  local hits = draw_body(t, row_nodes, css:get("rule").display ~= "none")
  local note
  if tnode.data.total == 0 then
    note = "(no rows)"
  elseif hidden > 0 then
    note = ("… %d more rows (table line-clamp)"):format(hidden)
  elseif rs.truncated then
    note = ("… showing the first %d rows (query.max_rows)"):format(#rs.rows)
  end
  if note then
    add(t, note, { { 0, #note, ctx.css:hl("note") } })
  end
  return { lines = t.lines, hl = t.hl, hits = hits }
end

return M
