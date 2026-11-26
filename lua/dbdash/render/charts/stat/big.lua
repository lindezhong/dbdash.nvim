-- Stat chart: the value in 3-row block digits, the change since the previous refresh and a
-- sparkline of recent refreshes. Falls back to one line when the window is too narrow.
-- Appearance (CSS): value { font-size: big (block digits, the default) | normal, color },
-- value.<threshold class>, unit, label, delta.up / .down / .same, sparkline; delta and
-- sparkline { display: none } leave them out.
--   Active users
--   █▀█ ▄█  ▀▀█
--   █ █  █    █
--   █▄█ ▄█▄   █
--   ↑ 12.5%  ▁▂▄▃▅▇
local C = require("dbdash.render.charts.stat.common")
local W = require("dbdash.util.width")

local M = { name = "big" }

-- 3-row glyphs; every row of a glyph has the same display width.
local FONT = {
  ["0"] = { "█▀█", "█ █", "█▄█" },
  ["1"] = { "▄█ ", " █ ", "▄█▄" },
  ["2"] = { "▀▀█", "█▀▀", "█▄▄" },
  ["3"] = { "▀▀█", " ▀█", "▄▄█" },
  ["4"] = { "█ █", "▀▀█", "  █" },
  ["5"] = { "█▀▀", "▀▀█", "▄▄█" },
  ["6"] = { "█▀▀", "█▀█", "█▄█" },
  ["7"] = { "▀▀█", "  █", "  █" },
  ["8"] = { "█▀█", "█▀█", "█▄█" },
  ["9"] = { "█▀█", "▀▀█", "▄▄█" },
  ["."] = { " ", " ", "▄" },
  [","] = { " ", " ", "▄" },
  [":"] = { " ", "▀", "▀" },
  ["-"] = { "   ", "▀▀▀", "   " },
  ["+"] = { "   ", "▄█▄", " ▀ " },
  ["%"] = { "█ ▄", "▄▀ ", "▀ █" },
  ["k"] = { "█  ", "█▄▀", "█ █" },
  ["M"] = { "█▄ ▄█", "█ ▀ █", "█   █" },
  ["G"] = { "█▀▀▀", "█ ▀█", "█▄▄█" },
  ["T"] = { "▀█▀", " █ ", " █ " },
  [" "] = { " ", " ", " " },
  ["$"] = { "▄█▀", "▀█▄", "▀█▀" },
  ["/"] = { "  █", " █ ", "█  " },
}

---The three rows of `s` in the block font, or nil when a character has no glyph.
local function big(s)
  local rows = { {}, {}, {} }
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    local g = FONT[ch]
    if not g then
      return nil
    end
    for r = 1, 3 do
      rows[r][#rows[r] + 1] = g[r]
    end
  end
  return {
    table.concat(rows[1], " "),
    table.concat(rows[2], " "),
    table.concat(rows[3], " "),
  }
end

---One value: the number (big or normal), its label, the change and the sparkline.
local function one(rs, show, ctx, history)
  local lines, hl = {}, {}
  local function add(s, spans)
    lines[#lines + 1] = s
    for _, sp in ipairs(spans or {}) do
      hl[#hl + 1] = { row = #lines - 1, col_s = sp[1], col_e = sp[2], group = sp[3] }
    end
  end
  local title = show.title ~= vim.NIL and show.title or ""
  if title ~= "" then
    title = W.truncate(title, ctx.width)
    add(title, { { 0, #title, ctx.css:hl("title") } })
  end

  local v, err = C.value(rs, show)
  if err then
    add(err, { { 0, #err, ctx.css:hl("warning") } })
    return { lines = lines, hl = hl }
  end
  local text, unit = C.text(v, show)
  -- the value element: its threshold class colors it (Grafana colorMode is a rule:
  -- value.danger { background-color: ... })
  local classes = {}
  if show.thresholds and show.thresholds ~= vim.NIL then
    local T = require("dbdash.render.thresholds")
    local below = show.thresholds_below == true
    local _, step = T.level(v, T.steps(show.thresholds, below), below)
    classes = T.classes(step)
  end
  local vstyle = ctx.css:get("value", { classes = classes })
  local group = ctx.css:hl("value", { classes = classes })

  local size = vstyle["font-size"]
  local rows = size ~= "normal" and big(text) or nil
  local fits = rows and W.width(rows[1]) + (unit and (W.width(unit) + 1) or 0) <= ctx.width
  if fits then
    for r = 1, 3 do
      local s = rows[r]
      local spans = { { 0, #s, group } }
      if r == 3 and unit then
        spans[#spans + 1] = { #s + 1, #s + 1 + #unit, ctx.css:hl("unit") }
        s = s .. " " .. unit
      end
      add(s, spans)
    end
  else
    local s = W.truncate(text .. (unit and (" " .. unit) or ""), ctx.width)
    add(s, { { 0, math.min(#s, #text), group } })
  end
  local label = show.label ~= vim.NIL and show.label or nil
  if label then -- a muted line under the value (Grafana stat text)
    local l = W.truncate(tostring(label), ctx.width)
    add(l, { { 0, #l, ctx.css:hl("label") } })
  end

  -- change and sparkline
  history = history or {}
  local parts, spans, pos = {}, {}, 0
  local function put(s, g)
    spans[#spans + 1] = { pos, pos + #s, g }
    parts[#parts + 1] = s
    pos = pos + #s
  end
  if ctx.css:get("delta").display ~= "none" then
    local d = C.delta(history, show.delta_mode ~= vim.NIL and show.delta_mode or nil)
    if d then
      put(d.text, ctx.css:hl("delta", { classes = { d.dir } }))
    end
  end
  if ctx.css:get("sparkline").display ~= "none" then
    local len = tonumber(show.sparkline_length ~= vim.NIL and show.sparkline_length or nil) or C.HISTORY
    local room = ctx.width - (pos > 0 and (W.width(table.concat(parts)) + 2) or 0)
    local spark = C.sparkline(history, math.min(len, room))
    if spark then
      if pos > 0 then
        parts[#parts + 1] = "  "
        pos = pos + 2
      end
      put(spark, ctx.css:hl("sparkline"))
    end
  end
  if #parts > 0 then
    add(table.concat(parts), spans)
  end
  return { lines = lines, hl = hl }
end

---Several values side by side (show.value_columns: names or { column, label, format,
---unit, prefix }, like a Grafana stat with several fields); the change and sparkline
---follow the first value only.
function M.render(rs, show, ctx)
  local cols = show.value_columns ~= vim.NIL and show.value_columns or nil
  if not cols or #cols == 0 then
    return one(rs, show, ctx, ctx.history)
  end
  local outs, cells, x, gap = {}, {}, 0, 4
  local w = math.max(8, math.floor((ctx.width - gap * (#cols - 1)) / #cols))
  for i, spec in ipairs(cols) do
    local sub = {}
    for k, v in pairs(show) do
      sub[k] = v
    end
    sub.title, sub.value_columns = vim.NIL, vim.NIL
    if type(spec) == "table" then
      for k, v in pairs(spec) do
        sub[k] = v
      end
      sub.value_column = spec.column
      sub.label = spec.label ~= nil and spec.label or spec.column
    else
      sub.value_column, sub.label = spec, spec
    end
    local sctx = setmetatable({ width = w }, { __index = ctx })
    outs[i] = one(rs, sub, sctx, i == 1 and ctx.history or {})
    cells[i] = { x = x, width = w, y = 0, height = #outs[i].lines }
    x = x + w + gap
  end
  local h = 0
  for _, c in ipairs(cells) do
    h = math.max(h, c.height)
  end
  for _, c in ipairs(cells) do
    c.height = h
  end
  local out = require("dbdash.compositor").compose(cells, outs)
  return { lines = out.lines, hl = out.hl }
end

return M
