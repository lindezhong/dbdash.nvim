-- Table renderer, "box" style (design §11.1), modeled after rich's default table:
--
--   ┏━━━━┳━━━━━━━┓
--   ┃ id ┃ name  ┃
--   ┡━━━━╇━━━━━━━┩
--   │  1 │ Alice │
--   └────┴───────┘
--
-- The table is laid out from its DOM (dom/content/table.lua: table > header, row > cell,
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
  local style = require("dbdash.css.style")
  local hl = require("dbdash.css.hl")
  -- the table's DOM (dom/content/table.lua): built from the result before styles, here
  -- only brought up to date when rendering outside a dashboard
  local tnode = require("dbdash.dom.content").build(css.node, rs, show)
  local content = require("dbdash.dom.content")
  local tbl = style.get(tnode)
  local show_lines = css:get("rule").display ~= "none"
  local g_border = css:border_hl("table")
  local cols = vim.deepcopy(tnode.data.columns)
  local header_nodes = content.list(tnode, "header")
  local row_nodes = content.list(tnode, "row")
  -- table-wide cell settings: the first cell's (a cell part when there are no rows)
  local first = row_nodes[1] and content.list(row_nodes[1], "cell")[1]
  local cell = first and style.get(first) or css:get("cell")
  for c, col in ipairs(cols) do
    local cn = row_nodes[1] and row_nodes[1].children[c]
    local cc = cn and style.get(cn) or {}
    col.width = col.width or cc.width
    col.height = col.height or cc.height
    col.header_group = header_nodes[c] and hl.group(style.get(header_nodes[c])) or nil
  end
  local lines, hl_spans = {}, {}
  local function add(line, spans)
    lines[#lines + 1] = line
    for _, sp in ipairs(spans or {}) do
      hl_spans[#hl_spans + 1] = { row = #lines - 1, col_s = sp[1], col_e = sp[2], group = sp[3] }
    end
  end

  if #cols == 0 then
    add("(no columns)", { { 0, #"(no columns)", ctx.css:hl("note") } })
    return { lines = lines, hl = hl_spans }
  end

  -- Rows shown: at most table { line-clamp }.
  local hidden = 0
  local limit = tbl["line-clamp"]
  if limit and #row_nodes > limit then
    hidden = #row_nodes - limit
    row_nodes = { unpack(row_nodes, 1, limit) }
  end

  -- Cell texts (a NULL cell's is its content) and natural widths; colors are each cell's
  -- computed color (inherited from its row: row.danger colors the row's cells).
  local cells, row_bg, bg_groups, hits = {}, {}, {}, {}
  local widths, data_w = {}, {}
  for c, col in ipairs(cols) do
    widths[c] = col.width or W.width(col.label)
    data_w[c] = 0
  end
  -- what layout needs from a cell's computed style, once per (shared) style
  local per_style = {}
  local ellipsis_of = require("dbdash.render").ellipsis
  local function cell_style(cs)
    local d = per_style[cs]
    if not d then
      local nowrap = cs["white-space"] == "nowrap"
      d = {
        group = hl.group(cs),
        nowrap = nowrap,
        wrap = not nowrap and (cs["word-break"] == "break-all" and "char" or "word") or nil,
        valign = cs["vertical-align"],
        ellipsis = ellipsis_of(cs),
        content = cs.content or "",
      }
      per_style[cs] = d
    end
    return d
  end
  for r, rn in ipairs(row_nodes) do
    cells[r] = {}
    local rc = style.get(rn)
    local bg = rc["background-color"]
    if bg then
      bg_groups[bg] = bg_groups[bg] or hl.group({ ["background-color"] = bg })
      row_bg[r] = bg_groups[bg]
    end
    for c = 1, #cols do
      local cn = rn.children[c]
      local d = cell_style(style.get(cn))
      local is_null = cn.text == nil
      local text = cn.text or d.content
      local multi = text:find("\n", 1, true)
      if multi and d.nowrap then
        text = text:gsub("\n", "↵")
        multi = false
      end
      cells[r][c] = {
        text = text,
        null = is_null,
        group = d.group,
        wrap = d.wrap,
        valign = d.valign,
        ellipsis = d.ellipsis,
      }
      local tw = 0
      if multi then
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
          tw = math.max(tw, W.width(line))
        end
      else
        tw = W.width(text)
      end
      data_w[c] = math.max(data_w[c], tw)
      if not cols[c].width then
        widths[c] = math.max(widths[c], tw)
      end
    end
  end
  local wrap_mode = cell["white-space"] ~= "nowrap"
      and (cell["word-break"] == "break-all" and "char" or "word")
    or nil

  -- Box-drawing: "rich" (the default) mixes a heavy header with a light body (like rich);
  -- another border style draws all lines with it, none drops them.
  local B = require("dbdash.render.borders")
  local rich = tbl.border == "rich"
  local chars = tbl.border ~= "none" and B.get(rich and "single" or tbl.border, "single") or nil
  local border = chars ~= nil
  local pad = cell.padding[2]
  local sp = string.rep(" ", pad)
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
  local function cell_lines(cl, c)
    local w, out = widths[c], {}
    if not cl.wrap then
      return { W.truncate(cl.text, w, cl.ellipsis) }
    end
    for line in (cl.text .. "\n"):gmatch("([^\n]*)\n") do
      vim.list_extend(out, W.wrap(line, w, cl.wrap))
    end
    return W.clamp(out, cols[c].height, w, cl.ellipsis)
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
    local first_line = #lines
    local parts, groups, n = {}, {}, 1
    for c, rc in ipairs(row) do
      parts[c] = cell_lines(rc, c)
      n = math.max(n, #parts[c])
      groups[c] = rc.group
    end
    for k = 1, n do
      local texts = {}
      for c = 1, #cols do
        -- CSS vertical-align of a cell shorter than its row
        local free = n - #parts[c]
        local va = row[c].valign
        local skip = va == "middle" and math.floor(free / 2) or (va == "bottom" and free or 0)
        texts[c] = parts[c][k - skip] or ""
      end
      add(row_line(texts, groups, v))
      if row_bg[r] then
        table.insert(
          hl_spans,
          { row = #lines - 1, col_s = 0, col_e = #lines[#lines], group = row_bg[r], priority = 50 }
        )
      end
    end
    -- the row element's lines (hit testing: :DbDashInspect on a row)
    hits[#hits + 1] = { row_s = first_line, row_e = #lines - 1, node = row_nodes[r] }
  end
  if border then
    if rich then
      add(rule("└", "─", "┴", "┘"))
    else
      add(rule(chars.bl, chars.h, chars.bt, chars.br))
    end
  end

  local note
  if tnode.data.total == 0 then
    note = "(no rows)"
  elseif hidden > 0 then
    note = ("… %d more rows (table line-clamp)"):format(hidden)
  elseif rs.truncated then
    note = ("… showing the first %d rows (query.max_rows)"):format(#rs.rows)
  end
  if note then
    add(note, { { 0, #note, ctx.css:hl("note") } })
  end
  return { lines = lines, hl = hl_spans, hits = hits }
end

return M
