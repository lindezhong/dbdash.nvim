-- The grid formatting context, after CSS Grid (pure: no Neovim API calls); Servo uses
-- Taffy for this. Placing the painted cells into buffer lines is the compositor's job
-- (compositor/init.lua).
--
-- Tracks (grid-template-columns / -rows):
--   integer      a fixed size: display columns, or lines for rows
--   "N%"         columns: a share of the width
--   "Nfr"        a share of the space left (rows: at least the panel's min-content)
--   auto         columns: 1fr; rows: minmax(min-content, max-content)
--   min-content  rows: the panel with its smallest plot; max-content: its full plot
--   "minmax(a, b)"  a, b: any of the above (b may be fr)
--   "repeat(n, t ...)"  in a string of tracks
-- Panels are placed by area name (grid-template-areas), row / column / span / row_span
-- (grid-row / grid-column), or flow into the next free cells (auto-placement, sparse).
--
-- Sizing follows the CSS track sizing algorithm, simplified: every track starts at its
-- base (fixed size, or the min-content of its panels), free space then grows the tracks
-- that have a limit (auto: up to max-content) equally, and what is left goes to fr tracks
-- in proportion. Nothing shrinks below its base: a grid taller than the window scrolls.

local M = {}

M.MIN_COL = 10 -- the narrowest column, as before

---@alias dbdash.layout.Size { [1]: "len"|"pct"|"fr", [2]: number }|"min"|"max"
---@class dbdash.layout.Track
---@field min dbdash.layout.Size
---@field max dbdash.layout.Size

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---One size: 12, "25%", "2fr", "min-content", "max-content".
---@return dbdash.layout.Size?
local function parse_size(s, axis)
  if type(s) == "number" then
    return (s >= 0 and s == math.floor(s)) and { "len", s } or nil
  end
  s = trim(s)
  local n = tonumber(s)
  if n then
    return parse_size(n, axis)
  end
  local pct = s:match("^(%d+%.?%d*)%%$")
  if pct and axis == "columns" then
    return { "pct", tonumber(pct) }
  end
  local fr = s:match("^(%d*%.?%d+)fr$")
  if fr and tonumber(fr) > 0 then
    return { "fr", tonumber(fr) }
  end
  if axis == "rows" and s == "min-content" then
    return "min"
  end
  if axis == "rows" and s == "max-content" then
    return "max"
  end
  return nil
end

---One track: a size, auto, or minmax(a, b).
---@param v string|integer
---@param axis "columns"|"rows"
---@return dbdash.layout.Track?, string? err
function M.parse_track(v, axis)
  if type(v) == "string" then
    local s = trim(v)
    if s == "auto" then
      if axis == "columns" then
        return { min = { "len", M.MIN_COL }, max = { "fr", 1 } }
      end
      return { min = "min", max = "max" }
    end
    local a, b = s:match("^minmax%(%s*([^,]-)%s*,%s*([^,]-)%s*%)$")
    if a then
      local lo = a == "auto" and (axis == "rows" and "min" or { "len", M.MIN_COL })
        or parse_size(a, axis)
      local hi = b == "auto" and (axis == "rows" and "max" or { "fr", 1 }) or parse_size(b, axis)
      if not lo or not hi or (type(lo) == "table" and lo[1] == "fr") then
        return nil, ("invalid track %q (minmax(min, max): the min cannot be fr)"):format(v)
      end
      return { min = lo, max = hi }
    end
  end
  local size = parse_size(v, axis)
  if not size then
    local kinds = axis == "columns" and 'an integer, "N%", "Nfr", auto or minmax(a, b)'
      or 'an integer, "Nfr", auto, min-content, max-content or minmax(a, b)'
    return nil, ("invalid track %q (%s)"):format(tostring(v), kinds)
  end
  if type(size) == "table" and size[1] == "fr" then
    -- Like CSS: a fr track is minmax(auto, Nfr).
    return { min = axis == "rows" and "min" or { "len", M.MIN_COL }, max = size }
  end
  return { min = size, max = size }
end

---Split a string of tracks at top-level spaces and expand repeat(n, ...).
local function split_tracks(s)
  local out, depth, cur = {}, 0, {}
  for ch in s:gmatch(".") do
    if ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
    end
    if ch:match("%s") and depth == 0 then
      if #cur > 0 then
        out[#out + 1] = table.concat(cur)
        cur = {}
      end
    else
      cur[#cur + 1] = ch
    end
  end
  if #cur > 0 then
    out[#out + 1] = table.concat(cur)
  end
  local expanded = {}
  for _, t in ipairs(out) do
    local n, inner = t:match("^repeat%(%s*(%d+)%s*,(.*)%)$")
    if n then
      local parts = split_tracks(inner)
      for _ = 1, tonumber(n) do
        vim.list_extend(expanded, parts)
      end
    else
      expanded[#expanded + 1] = t
    end
  end
  return expanded
end

---Track list from an integer (n x 1fr columns), a string ("1fr 2fr 30") or a list.
---@param v integer|string|(string|integer)[]
---@param axis "columns"|"rows"
---@return dbdash.layout.Track[]?, string? err
function M.parse_tracks(v, axis)
  local list
  if type(v) == "number" then
    if axis ~= "columns" or v < 1 or v ~= math.floor(v) then
      return nil, "expected a track list"
    end
    list = {}
    for i = 1, v do
      list[i] = "1fr"
    end
  elseif type(v) == "string" then
    list = split_tracks(v)
  elseif type(v) == "table" then
    list = {}
    for _, t in ipairs(v) do
      if type(t) == "string" and t:find("repeat%(") then
        vim.list_extend(list, split_tracks(t))
      else
        list[#list + 1] = t
      end
    end
  else
    return nil, "expected a number, a string or a list of tracks"
  end
  local tracks = {}
  for i, t in ipairs(list) do
    local tr, err = M.parse_track(t, axis)
    if not tr then
      return nil, err
    end
    tracks[i] = tr
  end
  if axis == "columns" and #tracks == 0 then
    return nil, "at least one column is needed"
  end
  return tracks
end

---@class dbdash.layout.Area
---@field row integer
---@field col integer
---@field row_span integer
---@field span integer

---grid-template-areas: rows of names ("." is an empty cell); each name a rectangle.
---@param rows string[]
---@return table<string, dbdash.layout.Area>? areas
---@return integer? columns
---@return string? err
function M.parse_areas(rows)
  local grid, width = {}, nil
  for r, line in ipairs(rows) do
    local names = vim.split(trim(line), "%s+")
    if width and #names ~= width then
      return nil, nil, ("areas row %d has %d cells, row 1 has %d"):format(r, #names, width)
    end
    width = #names
    grid[r] = names
  end
  local areas = {}
  for r, names in ipairs(grid) do
    for c, n in ipairs(names) do
      if n ~= "." then
        local a = areas[n]
        if not a then
          areas[n] = { row = r, col = c, last_row = r, last_col = c }
        else
          a.col = math.min(a.col, c)
          a.last_row, a.last_col = math.max(a.last_row, r), math.max(a.last_col, c)
        end
      end
    end
  end
  for n, a in pairs(areas) do
    for r = a.row, a.last_row do
      for c = a.col, a.last_col do
        if grid[r][c] ~= n then
          return nil, nil, ("area %q is not a rectangle"):format(n)
        end
      end
    end
    areas[n] =
      { row = a.row, col = a.col, row_span = a.last_row - a.row + 1, span = a.last_col - a.col + 1 }
  end
  return areas, width
end

---@class dbdash.layout.Item
---@field area string?
---@field row integer?
---@field column integer?
---@field span integer?
---@field row_span integer?

---@class dbdash.layout.Place
---@field row integer first grid row (1-based)
---@field col integer first grid column (1-based)
---@field span integer columns
---@field row_span integer rows

---Place items on a grid of `ncols` columns: areas and explicit positions first, the rest
---in order into the first free cells after the previous auto item (CSS sparse placement).
---@param items dbdash.layout.Item[]
---@param ncols integer
---@param areas table?
---@return dbdash.layout.Place[]?, { index: integer, field: string, message: string }? err
---Cells taken by placed items.
local Used = {}
Used.__index = Used

---Is the rs x cs block at (r, c) inside the columns and free?
function Used:free(r, c, rs, cs)
  if c < 1 or c + cs - 1 > self.ncols or r < 1 then
    return false
  end
  for y = r, r + rs - 1 do
    for x = c, c + cs - 1 do
      if self[y] and self[y][x] then
        return false
      end
    end
  end
  return true
end

function Used:take(i, p)
  for y = p.row, p.row + p.row_span - 1 do
    self[y] = self[y] or {}
    for x = p.col, p.col + p.span - 1 do
      self[y][x] = i
    end
  end
end

local function placement_error(i, field, msg, ...)
  return nil, { index = i, field = field, message = msg:format(...) }
end

---An item with an area, or with both row and column: its place (nil: it flows), or nil and
---an error.
local function place_fixed(used, i, it, areas)
  local p
  if it.area then
    local a = areas and areas[it.area]
    if not a then
      return placement_error(i, "area", "no area named %q in grid-template-areas", it.area)
    end
    p = { row = a.row, col = a.col, span = a.span, row_span = a.row_span }
  elseif it.row and it.column then
    p = { row = it.row, col = it.column, span = it.span or 1, row_span = it.row_span or 1 }
  else
    return false
  end
  local field = it.area and "area" or "column"
  if p.col + p.span - 1 > used.ncols then
    local msg = "column %d + span %d is past the %d columns"
    return placement_error(i, field, msg, p.col, p.span, used.ncols)
  end
  if not used:free(p.row, p.col, p.row_span, p.span) then
    local other = used[p.row] and used[p.row][p.col]
    return placement_error(i, it.area and "area" or "row", "overlaps panel %d", other or 0)
  end
  return p
end

---An item with a row or a column only (the first free place along it), or an auto item
---(after the cursor, row by row); returns its place or nil and an error.
local function place_flowing(used, i, it, cursor)
  local ncols = used.ncols
  local cs = math.max(1, math.min(it.span or 1, ncols))
  local rs = it.row_span or 1
  local p
  if it.column then
    if it.column + cs - 1 > ncols then
      local msg = "column %d + span %d is past the %d columns"
      return placement_error(i, "column", msg, it.column, cs, ncols)
    end
    local r = 1
    while not used:free(r, it.column, rs, cs) do
      r = r + 1
    end
    p = { row = r, col = it.column }
  elseif it.row then
    local c = 1
    while c + cs - 1 <= ncols and not used:free(it.row, c, rs, cs) do
      c = c + 1
    end
    if c + cs - 1 > ncols then
      return placement_error(i, "row", "no room in row %d", it.row)
    end
    p = { row = it.row, col = c }
  else
    local r, c = cursor.r, cursor.c
    while not used:free(r, c, rs, cs) do
      c = c + 1
      if c + cs - 1 > ncols then
        r, c = r + 1, 1
      end
    end
    p = { row = r, col = c }
    cursor.r, cursor.c = r, c + cs
  end
  p.span, p.row_span = cs, rs
  return p
end

function M.place(items, ncols, areas)
  local used = setmetatable({ ncols = ncols }, Used)
  local out = {}
  -- 1. Areas and items with both row and column.
  for i, it in ipairs(items) do
    local p, err = place_fixed(used, i, it, areas)
    if p == nil then
      return nil, err
    elseif p then
      used:take(i, p)
      out[i] = p
    end
  end
  -- 2. A row or a column only, then 3. auto items (cursor-based).
  local cursor = { r = 1, c = 1 }
  for pass = 2, 3 do
    for i, it in ipairs(items) do
      if not out[i] and ((pass == 2) == (it.row ~= nil or it.column ~= nil)) then
        local p, err = place_flowing(used, i, it, cursor)
        if not p then
          return nil, err
        end
        used:take(i, p)
        out[i] = p
      end
    end
  end
  return out
end

---Sizes of `tracks` sharing `avail` (fr after the rest; fr never below its base).
---@param bases number[]
---@param limits (number|false)[] growth limits of non-fr tracks (false: none)
---@param frs number[] fr factor per track (0: not flexible)
---@param avail number
---@return integer[]
local function distribute(bases, limits, frs, avail)
  local size = {}
  local used = 0
  for i, b in ipairs(bases) do
    size[i] = b
    used = used + b
  end
  local free = avail - used
  -- Grow limited tracks equally up to their limits.
  local growing = {}
  for i = 1, #bases do
    if frs[i] == 0 and limits[i] and limits[i] > size[i] then
      growing[#growing + 1] = i
    end
  end
  while free > 0 and #growing > 0 do
    local share = math.floor(free / #growing)
    if share == 0 then
      for k = 1, free do
        size[growing[k]] = size[growing[k]] + 1
      end
      free = 0
      break
    end
    local next_growing = {}
    for _, i in ipairs(growing) do
      local add = math.min(share, limits[i] - size[i])
      size[i] = size[i] + add
      free = free - add
      if size[i] < limits[i] then
        next_growing[#next_growing + 1] = i
      end
    end
    growing = next_growing
  end
  -- fr tracks: a share of what is left, never below their base.
  local flex = {}
  for i = 1, #bases do
    if frs[i] > 0 then
      flex[#flex + 1] = i
    end
  end
  if free > 0 and #flex > 0 then
    local pool, total = free, 0
    for _, i in ipairs(flex) do
      pool = pool + size[i]
      total = total + frs[i]
    end
    -- Tracks whose base exceeds their share keep the base and leave the pool.
    local changed = true
    while changed do
      changed = false
      local unit = pool / total
      for k = #flex, 1, -1 do
        local i = flex[k]
        if size[i] > unit * frs[i] then
          pool, total = pool - size[i], total - frs[i]
          table.remove(flex, k)
          changed = true
        end
      end
      if total <= 0 then
        break
      end
    end
    if total > 0 then
      local unit, given, acc = pool / total, 0, 0
      for _, i in ipairs(flex) do
        acc = acc + unit * frs[i]
        local s = math.floor(acc + 0.5) - given
        given = given + s
        size[i] = s
      end
    end
  end
  return size
end

---Column widths and x offsets.
---@param tracks dbdash.layout.Track[]
---@param width integer
---@param gap integer
---@return { width: integer, x: integer }[]
function M.columns(tracks, width, gap)
  local avail = math.max(0, width - gap * (#tracks - 1))
  local function len(sz)
    if type(sz) ~= "table" then
      return nil
    end
    if sz[1] == "len" then
      return sz[2]
    elseif sz[1] == "pct" then
      return math.floor(avail * sz[2] / 100)
    end
  end
  local bases, limits, frs = {}, {}, {}
  for i, t in ipairs(tracks) do
    bases[i] = len(t.min) or M.MIN_COL
    local hi = t.max
    if type(hi) == "table" and hi[1] == "fr" then
      frs[i], limits[i] = hi[2], false
    else
      frs[i], limits[i] = 0, len(hi) or bases[i]
    end
  end
  local sizes = distribute(bases, limits, frs, avail)
  local out, x = {}, 0
  for i, w in ipairs(sizes) do
    out[i] = { width = w, x = x }
    x = x + w + gap
  end
  return out
end

---Row heights: `tracks[r]` for every grid row; `items` are the placed panels with their
---min-content and max-content heights (hmin, hmax).
---@param tracks dbdash.layout.Track[]
---@param items { row: integer, row_span: integer, hmin: integer, hmax: integer }[]
---@param avail integer lines for the rows (gaps already taken out)
---@param gap integer? lines between rows (default 1), part of a spanning panel's cell
---@return integer[] heights, boolean[] fill (rows whose panels fill their cells: fixed or fr)
function M.rows(tracks, items, avail, gap)
  gap = gap or 1
  local n = #tracks
  local cmin, cmax = {}, {}
  for r = 1, n do
    cmin[r], cmax[r] = 0, 0
  end
  for _, it in ipairs(items) do
    if it.row_span == 1 then
      cmin[it.row] = math.max(cmin[it.row], it.hmin)
      cmax[it.row] = math.max(cmax[it.row], it.hmax)
    end
  end
  local function size_of(sz, r)
    if sz == "min" then
      return cmin[r]
    elseif sz == "max" then
      return cmax[r]
    elseif type(sz) == "table" and sz[1] == "len" then
      return sz[2]
    end
  end
  local bases, limits, frs, fixed, fill = {}, {}, {}, {}, {}
  for r, t in ipairs(tracks) do
    bases[r] = size_of(t.min, r) or 0
    if type(t.max) == "table" and t.max[1] == "fr" then
      frs[r], limits[r] = t.max[2], false
      fill[r] = true
    else
      frs[r] = 0
      limits[r] = math.max(size_of(t.max, r) or bases[r], bases[r])
      fixed[r] = type(t.min) == "table" and type(t.max) == "table"
      fill[r] = fixed[r]
    end
  end
  -- Items spanning rows: what their rows lack goes to the rows that can grow.
  for _, it in ipairs(items) do
    if it.row_span > 1 then
      local last = it.row + it.row_span - 1
      local function lack(key, need)
        local have, grow = gap * (it.row_span - 1), {}
        for r = it.row, last do
          have = have + key[r]
          if not fixed[r] then
            grow[#grow + 1] = r
          end
        end
        local d = need - have
        if d > 0 and #grow > 0 then
          for k, r in ipairs(grow) do
            key[r] = key[r] + math.floor(d / #grow) + (k <= d % #grow and 1 or 0)
          end
        end
      end
      lack(bases, it.hmin)
      local lim = {}
      for r = it.row, last do
        lim[r] = limits[r] or bases[r]
      end
      lack(lim, it.hmax)
      for r = it.row, last do
        if limits[r] then
          limits[r] = math.max(limits[r], lim[r], bases[r])
        end
      end
    end
  end
  return distribute(bases, limits, frs, avail), fill
end

---A grid-row / grid-column value: N, "span M" or "N / span M" -> start, span.
---@return integer? start, integer span
local function grid_line(v)
  if type(v) == "number" then
    return v, 1
  end
  if type(v) ~= "string" then
    return nil, 1
  end
  local a, b = v:match("^(%d+)%s*/%s*span%s+(%d+)$")
  if a then
    return tonumber(a), tonumber(b)
  end
  local n = v:match("^span%s+(%d+)$")
  if n then
    return nil, tonumber(n)
  end
  return tonumber(v), 1
end
M.grid_line = grid_line

---@class dbdash.layout.Grid
---@field columns table
---@field rows table
---@field auto_row table
---@field gap integer
---@field row_gap integer
---@field places dbdash.layout.Place[]

---@class dbdash.layout.GridError
---@field index integer?
---@field field string
---@field message string

---The grid of a dashboard from computed styles: the container's tracks, gaps and areas,
---and each panel's placement (grid-area, grid-row, grid-column).
---@param container table computed style of the dashboard element
---@param items table[] computed style of every panel, in order
---@return dbdash.layout.Grid? grid
---@return dbdash.layout.GridError? err
function M.from_styles(container, items)
  local areas, area_cols
  if container["grid-template-areas"] then
    local err
    areas, area_cols, err = M.parse_areas(container["grid-template-areas"])
    if not areas then
      return nil, { field = "grid-template-areas", message = err }
    end
  end
  local cols_v = container["grid-template-columns"]
  if cols_v == 1 and area_cols then
    cols_v = area_cols -- the default: as many columns as the areas have
  end
  local columns, err = M.parse_tracks(cols_v, "columns")
  if not columns then
    return nil, { field = "grid-template-columns", message = err }
  end
  if area_cols and #columns ~= area_cols then
    return nil,
      {
        field = "grid-template-columns",
        message = ("%d columns, but grid-template-areas has %d"):format(#columns, area_cols),
      }
  end
  local rows = {}
  if container["grid-template-rows"] then
    rows, err = M.parse_tracks(container["grid-template-rows"], "rows")
    if not rows then
      return nil, { field = "grid-template-rows", message = err }
    end
  end
  local auto, aerr = M.parse_tracks(container["grid-auto-rows"] or "auto", "rows")
  if not auto then
    return nil, { field = "grid-auto-rows", message = aerr }
  end
  local list = {}
  for i, c in ipairs(items) do
    local row, row_span = grid_line(c["grid-row"])
    local column, span = grid_line(c["grid-column"])
    list[i] =
      { area = c["grid-area"], row = row, row_span = row_span, column = column, span = span }
    if list[i].area and (row or column) then
      return nil,
        {
          index = i,
          field = "grid-area",
          message = "grid-area and grid-row / grid-column cannot be used together",
        }
    end
  end
  local places, perr = M.place(list, #columns, areas)
  if not places then
    local field = ({ area = "grid-area", row = "grid-row", column = "grid-column" })[perr.field]
      or perr.field
    return nil, { index = perr.index, field = field, message = perr.message }
  end
  return {
    columns = columns,
    rows = rows,
    auto_row = auto[1],
    gap = container["column-gap"],
    row_gap = container["row-gap"],
    places = places,
  }
end

---`columns` equal columns with the panels in order and their spans (tests and tools).
---@param spans integer[]
---@param width integer
---@param columns integer
---@param gap integer
---@return { row: integer, col: integer, width: integer, x: integer }[]
function M.plan(spans, width, columns, gap)
  local tracks = M.parse_tracks(math.max(1, columns), "columns")
  local items = {}
  for i, s in ipairs(spans) do
    items[i] = { span = s }
  end
  local places = M.place(items, #tracks, nil)
  local cols = M.columns(tracks, width, gap)
  local cells = {}
  for i, p in ipairs(places) do
    local last = cols[p.col + p.span - 1]
    cells[i] = {
      row = p.row,
      col = p.col - 1,
      width = last.x + last.width - cols[p.col].x,
      x = cols[p.col].x,
    }
  end
  return cells
end

-- The rules of a config's grid (config/validators.lua): the panels are placed once with
-- the config's own sheets (computed as a dashboard would), so conflicts (overlaps, unknown
-- areas, areas that are not rectangles) are reported with the line of the declaration at
-- fault; :DbDashStyle rules are placed again at layout.
M.validators = {
  {
    field = "dashboard",
    validate = function(cfg, ctx)
      if not cfg.grid then
        return
      end
      local doc = ctx:document(cfg)
      local style = require("dbdash.css.style")
      local items = {}
      for i, p in ipairs(doc.panels) do
        items[i] = style.get(p.node)
      end
      local _, err = M.from_styles(style.get(doc.doc.root), items)
      if err then
        -- the declaration at fault: <sheet>.<selector>.<property>, else the sheet
        local sheet = err.index and ("panels[%d].style"):format(err.index) or "style"
        local rules = (err.index and cfg.panels[err.index].style_rules or cfg.style_rules) or {}
        local where = sheet
        for _, r in ipairs(rules) do
          if r.decls[err.field] ~= nil then
            where = ("%s.%s.%s"):format(sheet, r.key or r.selector.text, err.field)
          end
        end
        ctx:fail(where, "%s: %s", err.field, err.message)
      end
    end,
  },
}

return M
