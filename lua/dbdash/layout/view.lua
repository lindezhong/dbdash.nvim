-- Layout of a dashboard view (Servo's layout: box tree -> fragment tree), from the
-- dashboard's document and computed styles:
--   view     the header block, then the panels: one block (a one-chart dashboard) or the
--            grid formatting context (layout/grid.lua)
--   panel    a block box (padding, border: paint/box.lua settings) stacking its rows:
--            the title line (inline: title, ⓘ, error), the subtitle, the argument line,
--            and the chart
--   chart    a replaced element: laid out at the size it gets; its raster comes from the
--            chart code (layout/replaced.lua)
-- The result is a tree of fragments; painting them is paint/init.lua's job.
local W = require("dbdash.util.width")
local box = require("dbdash.paint.box")
local css = require("dbdash.css")
local replaced = require("dbdash.layout.replaced")

local M = {}

---@class dbdash.layout.FragmentRow
---@field node dbdash.dom.Node?
---@field out dbdash.render.Output

---@class dbdash.layout.Fragment
---@field node dbdash.dom.Node?
---@field x integer
---@field y integer
---@field width integer
---@field height integer? nil: as tall as its content
---@field rows dbdash.layout.FragmentRow[]? block children (text rows), in order
---@field chart { node: dbdash.dom.Node, out: dbdash.render.Output }? the replaced element
---@field box table? box settings (padding, border, background, alignment)
---@field border_title table? the title drawn in the top border
---@field caption_bottom boolean?

local function child(node, tag)
  return require("dbdash.dom.node").child(node, tag)
end

local function text(n)
  return n and n.text or nil
end

---The header of the view: the dashboard title and ⓘ, then an empty line; none without
---either (the global countdown is an overlay on its line).
---@return dbdash.render.Output
function M.header(d)
  local title = text(child(d.header_node, "header-title")) or ""
  local icon_node = child(d.header_node, "description-icon")
  local icon = text(icon_node)
  local countdown = require("dbdash.css").countdown(d.header_node) and d.cfg.refresh_all
  if not (d.cfg.title or countdown or icon) then
    return { lines = {}, hl = {} }
  end
  local line, hl =
    title, {
      {
        row = 0,
        col_s = 0,
        col_e = #title,
        group = css.hl_of(child(d.header_node, "header-title")),
      },
    }
  if icon then
    line = title ~= "" and (title .. " ") or ""
    hl[#hl + 1] = { row = 0, col_s = #line, col_e = #line + #icon, group = css.hl_of(icon_node) }
    line = line .. icon
  end
  return { lines = { line, "" }, hl = hl }
end

---The argument line of a panel (inline: arg-name=arg-value pairs), cut to `width`.
---@return dbdash.render.Output?
function M.args_line(p, width)
  local args = child(p.node, "args")
  if #args.children == 0 then
    return nil
  end
  local parts, spans, pos = {}, {}, 0
  local function put(str, group)
    if group then
      spans[#spans + 1] = { pos, pos + #str, group }
    end
    parts[#parts + 1] = str
    pos = pos + #str
  end
  for i = 1, #args.children, 2 do
    local name, value = args.children[i], args.children[i + 1]
    if i > 1 then
      put("  ")
    end
    put(name.text, css.hl_of(name))
    put("=")
    put(value.text, css.hl_of(value))
  end
  local line = W.truncate(table.concat(parts), width)
  local hl = {}
  for _, sp in ipairs(spans) do
    if sp[1] < #line then
      hl[#hl + 1] = { row = 0, col_s = sp[1], col_e = math.min(sp[2], #line), group = sp[3] }
    end
  end
  return { lines = { line }, hl = hl }
end

---The title line of a panel: the title aligned in the room ⓘ leaves, ⓘ, then the error
---when at least 6 cells are left (an inline formatting context whose first item shrinks).
---@return string line, table[] spans
local function title_line(p, st, iw)
  local title_node, icon_node, err_node =
    child(p.node, "panel-title"), child(p.node, "description-icon"), child(p.node, "error")
  local name, icon = text(title_node) or "", text(icon_node)
  local room = math.max(iw - (icon and (W.width(icon) + 1) or 0), 1)
  local head, s0, e0 = box.title_line(name, room, st.title_align or "left", st.ellipsis)
  local spans = { { s0, e0, st.title_group } }
  if icon then
    head = head .. " " .. icon
    spans[#spans + 1] = { #head - #icon, #head, css.hl_of(icon_node) }
  end
  local err = text(err_node)
  if err then
    local free = iw - W.width(head) - 3
    if free > 5 then
      local e = W.truncate(err:gsub("\n", " "), free)
      spans[#spans + 1] = { #head + 2, #head + 2 + #("✗ " .. e), css.hl_of(err_node) }
      head = head .. "  ✗ " .. e
    end
  end
  return head, spans
end

local layout_panel

---The cache key of a panel's layout: what it depends on (Servo keys its layout caches on
---the containing block; here also the data, the panel's subtree version and its show
---config, which still carries per-panel overrides).
local function panel_key(p, width, height, fill, exact)
  return table.concat({
    width,
    height or "",
    tostring(fill),
    tostring(exact),
    p.node and p.node.version or 0,
    p.values and #p.values or 0,
    vim.json.encode(p:show_config()),
  }, "|")
end

---Lay out a panel of a grid in a `width` x `height` cell. `fill`: the chart fills the
---cell (a fixed or fr row); `exact`: the box is `height` lines (else as tall as its
---content, for measuring min-content / max-content). The fragment is reused while
---nothing it depends on changed.
---@return dbdash.layout.Fragment
---A fragment from the panel's layout cache, else laid out by `build` and kept.
local function cached(p, kind, width, height, fill, exact, build)
  p.layout_cache = p.layout_cache or { n = 0, entries = {} }
  local cache = p.layout_cache
  local key = kind .. "|" .. panel_key(p, width, height, fill, exact)
  local hit = cache.entries[key]
  if hit and hit.rs == p.rs then
    M.stats.hits = M.stats.hits + 1
    return hit.frag
  end
  M.stats.misses = M.stats.misses + 1
  local frag = build()
  if cache.n > 16 then -- sizes come and go with the window: keep the cache small
    cache.entries, cache.n = {}, 0
  end
  -- keyed on the version after layout: styling parts the first time bumps it
  cache.entries[kind .. "|" .. panel_key(p, width, height, fill, exact)] =
    { rs = p.rs, frag = frag }
  cache.n = cache.n + 1
  return frag
end

function M.panel(p, width, height, fill, exact)
  return cached(p, "grid", width, height, fill, exact, function()
    return layout_panel(p, width, height, fill, exact)
  end)
end

---Layout cache counters (tests).
M.stats = { hits = 0, misses = 0 }

layout_panel = function(p, width, height, fill, exact)
  local show = vim.deepcopy(p:show_config())
  local scope = css.scope(p.node)
  local st = box.settings(scope)
  show.title = nil -- in the title line (or the box's top border) instead
  local iw, ih = box.inner(st, width, height)
  local head, spans = title_line(p, st, iw)
  local frag = {
    node = p.node,
    x = 0,
    y = 0,
    width = width,
    height = exact and height or nil,
    box = st,
    rows = {},
  }
  local header = { lines = { head }, hl = {} }
  for _, sp in ipairs(spans) do
    header.hl[#header.hl + 1] = { row = 0, col_s = sp[1], col_e = sp[2], group = sp[3] }
  end
  if st.border then
    -- fieldset style: ╭─ Title ⓘ ──╮
    local lead = #head - #(head:gsub("^%s+", ""))
    frag.border_title = { text = vim.trim(head), spans = {} }
    for _, sp in ipairs(spans) do
      frag.border_title.spans[#frag.border_title.spans + 1] = { sp[1] - lead, sp[2] - lead, sp[3] }
    end
    header = nil
  end
  local sub_node = child(p.node, "subtitle")
  if sub_node.text and header then
    local sl, ss, se = box.title_line(sub_node.text, iw, st.title_align or "left", st.ellipsis)
    header.lines[2] = sl
    header.hl[#header.hl + 1] = { row = 1, col_s = ss, col_e = se, group = css.hl_of(sub_node) }
  end
  show.subtitle = nil
  local args_line = M.args_line(p, iw)
  local bh = ih - (header and #header.lines or 0) - (args_line and 1 or 0)
  local body = replaced.raster(p, show, iw, bh, fill)
  body = box.position(body, st, iw, exact and bh or nil)
  -- the title under the chart
  frag.caption_bottom = scope:get("panel-title")["caption-side"] == "bottom"
  if header and not frag.caption_bottom then
    frag.rows[#frag.rows + 1] = { node = p.node, out = header }
  end
  if args_line then
    frag.rows[#frag.rows + 1] = { node = child(p.node, "args"), out = args_line }
  end
  frag.chart = { node = p.chart_node, out = body }
  if header and frag.caption_bottom then
    frag.after = { node = p.node, out = header }
  end
  return frag
end

---The chart of a one-chart dashboard in its box; the title stays the chart's own unless
---the border carries it.
---@return dbdash.layout.Fragment
local layout_single

function M.single(p, width, height)
  return cached(p, "single", width, height, false, false, function()
    return layout_single(p, width, height)
  end)
end

layout_single = function(p, width, height)
  local show = p:show_config()
  local st = box.settings(css.scope(p.node))
  local iw, ih = box.inner(st, width, height)
  local frag = { node = p.node, x = 0, y = 0, width = width, box = st, rows = {} }
  if st.border and show.title ~= nil and show.title ~= vim.NIL then
    frag.border_title = { text = show.title, spans = { { 0, #show.title, st.title_group } } }
    show = vim.deepcopy(show)
    show.title = nil
  end
  local body = replaced.raster(p, show, iw, ih)
  local exact = st.align ~= "start" or st.border ~= nil or st.background ~= nil
  frag.chart = { node = p.chart_node, out = box.position(body, st, iw, exact and ih or nil) }
  frag.height = exact and height or nil
  return frag
end

---A panel's heights at `width` (CSS min-content / max-content): laid out and painted with
---its smallest plot and with its full plot. Cached until its result, error, style or width
---change (Servo caches intrinsic sizes per box the same way).
---@return integer hmin, integer hmax
function M.measure(p, width)
  local paint = require("dbdash.paint")
  local show = p:show_config()
  local key = vim.json.encode({
    width,
    show,
    p.error and true or false,
    p.node and p.node.layout_version or 0,
  })
  local m = p.measured
  if not (m and m.rs == p.rs and m.key == key) then
    m = {
      rs = p.rs,
      key = key,
      hmin = #paint.fragment(M.panel(p, width, 0)).lines,
      hmax = #paint.fragment(M.panel(p, width, 100000)).lines,
    }
    p.measured = m
  end
  return m.hmin, m.hmax
end

---The grid formatting context: tracks, placement, row sizing (layout/grid.lua), then each
---panel laid out in its cell.
---@return { fragments: dbdash.layout.Fragment[] }
function M.grid(d, width, avail)
  local L = require("dbdash.layout.grid")
  local style = require("dbdash.css.style")
  local items = {}
  for i, p in ipairs(d.panels) do
    items[i] = style.get(p.node)
  end
  local lay, err = L.from_styles(style.get(d.doc.root), items)
  if not lay then
    -- a runtime rule broke the grid: say so instead of drawing (config rules were checked)
    local msg = ("style: %s%s: %s"):format(
      err.index and ("panel %d "):format(err.index) or "",
      err.field,
      err.message
    )
    return { fragments = {}, error = msg }
  end
  local cols = L.columns(lay.columns, width, lay.gap)
  local nrows = 0
  for _, pl in ipairs(lay.places) do
    nrows = math.max(nrows, pl.row + pl.row_span - 1)
  end
  local tracks = {}
  for r = 1, nrows do
    tracks[r] = lay.rows[r] or lay.auto_row
  end
  local cells, rows_wanted = {}, {}
  for i, p in ipairs(d.panels) do
    local pl = lay.places[i]
    local first, last = cols[pl.col], cols[pl.col + pl.span - 1]
    local w = last.x + last.width - first.x
    local hmin, hmax = M.measure(p, w)
    cells[i] = { x = first.x, width = w }
    rows_wanted[i] = { row = pl.row, row_span = pl.row_span, hmin = hmin, hmax = hmax }
  end
  local heights, fill =
    L.rows(tracks, rows_wanted, avail - lay.row_gap * math.max(nrows - 1, 0), lay.row_gap)
  local top, y = {}, 0
  for r = 1, nrows do
    top[r] = y
    y = y + heights[r] + lay.row_gap
  end
  local frags = {}
  for i, p in ipairs(d.panels) do
    local pl, c = lay.places[i], cells[i]
    local h, f = lay.row_gap * (pl.row_span - 1), false
    for r = pl.row, pl.row + pl.row_span - 1 do
      h = h + heights[r]
      f = f or fill[r]
    end
    local frag = M.panel(p, c.width, h, f, true)
    frag.x, frag.y, frag.height = c.x, top[pl.row], h
    frags[i] = frag
  end
  return { fragments = frags }
end

---@class dbdash.layout.View
---@field header dbdash.render.Output
---@field single dbdash.layout.Fragment?
---@field args dbdash.render.Output?
---@field grid { fragments: dbdash.layout.Fragment[] }?

---Lay out the whole view at `width` x `height`.
---@return dbdash.layout.View
function M.reflow(d, width, height)
  local header = M.header(d)
  local avail = height - #header.lines
  if not d.cfg.grid then
    local p = d.panels[1]
    local args_line = M.args_line(p, width)
    local h = avail - (args_line and 2 or 0)
    return { header = header, args = args_line, single = M.single(p, width, h) }
  end
  return { header = header, grid = M.grid(d, width, avail) }
end

return M
