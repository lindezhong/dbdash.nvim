-- Stat chart: the value in 3-row block digits, the change since the previous refresh and a
-- sparkline of recent refreshes. Falls back to one line when the window is too narrow.
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

function M.render(rs, show, ctx)
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
    add(title, { { 0, #title, "DbDashTitle" } })
  end

  local v, err = C.value(rs, show)
  if err then
    add(err, { { 0, #err, "DbDashWarn" } })
    return { lines = lines, hl = hl }
  end
  local text, unit = C.text(v, show)
  local group = ctx.value_group or "DbDashStatValue"

  local rows = big(text)
  local fits = rows and W.width(rows[1]) + (unit and (W.width(unit) + 1) or 0) <= ctx.width
  if fits then
    for r = 1, 3 do
      local s = rows[r]
      local spans = { { 0, #s, group } }
      if r == 3 and unit then
        spans[#spans + 1] = { #s + 1, #s + 1 + #unit, "DbDashMuted" }
        s = s .. " " .. unit
      end
      add(s, spans)
    end
  else
    local s = W.truncate(text .. (unit and (" " .. unit) or ""), ctx.width)
    add(s, { { 0, math.min(#s, #text), group } })
  end

  -- change and sparkline
  local history = ctx.history or {}
  local parts, spans, pos = {}, {}, 0
  local function put(s, g)
    spans[#spans + 1] = { pos, pos + #s, g }
    parts[#parts + 1] = s
    pos = pos + #s
  end
  if show.delta ~= false then
    local d = C.delta(history)
    if d then
      put(d.text, ({ up = "DbDashUp", down = "DbDashDown", same = "DbDashMuted" })[d.dir])
    end
  end
  if show.sparkline ~= false then
    local room = ctx.width - (pos > 0 and (W.width(table.concat(parts)) + 2) or 0)
    local spark = C.sparkline(history, math.min(C.HISTORY, room))
    if spark then
      if pos > 0 then
        parts[#parts + 1] = "  "
        pos = pos + 2
      end
      put(spark, "DbDashSeries1")
    end
  end
  if #parts > 0 then
    add(table.concat(parts), spans)
  end
  return { lines = lines, hl = hl }
end

return M
