-- Data and legend shared by the pie styles.
local C = require("dbdash.render.charts.common")
local W = require("dbdash.util.width")
local fmt = require("dbdash.render.format")

local M = {}

---Positive slices from label_column / value_column, with colors.
---@return { label: string, value: number, group: string }[] items, number sum
function M.items(rs, show, ctx)
  local li = C.col(rs, C.nn(show.label_column), "label_column")
  local vi = C.col(rs, C.nn(show.value_column), "value_column")
  local items, sum = {}, 0
  for _, row in ipairs(rs.rows) do
    local v = C.num(row[vi])
    if v and v > 0 then
      items[#items + 1] = { label = C.text(row[li]), value = v }
      sum = sum + v
    end
  end
  -- style.sort (asc / desc by value) and style.top: the first N, the rest as one slice
  -- (style.other_label, default "Other"), as ECharts examples do.
  local style = C.nn(show.style) or {}
  local order = C.nn(style.sort)
  if order == "asc" or order == "desc" then
    table.sort(items, function(a, b)
      if order == "asc" then
        return a.value < b.value
      end
      return a.value > b.value
    end)
  end
  local top = tonumber(C.nn(style.top))
  if top and #items > top then
    local rest = 0
    for i = top + 1, #items do
      rest = rest + items[i].value
    end
    items = { unpack(items, 1, top) }
    items[#items + 1] = { label = C.nn(style.other_label) or "Other", value = rest, other = true }
  end
  for i, it in ipairs(items) do
    it.group = it.other and ctx.css:hl("series", { classes = { "other" } }) or C.color(ctx, show, i, nil, it.label)
  end
  return items, sum
end

---Where the legend goes: "right" (beside the circle, the default), "bottom" or "none".
function M.legend_position(show)
  return C.legend_position(show, 2)
end

---Legend lines "■ label  value  pct%" honoring style.show_labels / show_values /
---show_percentages. Spans are byte ranges within each line.
---@param max_label integer? label width cap (default 30)
---@return { text: string, spans: { [1]: integer, [2]: integer, [3]: string }[] }[]
function M.legend(items, sum, show, max_label, ctx)
  local style = C.nn(show.style) or {}
  local show_labels = C.nn(style.show_labels) ~= false
  local show_values = C.nn(style.show_values) ~= false
  local show_pct = C.nn(style.show_percentages) ~= false
  local lw, vw = 0, 0
  for _, it in ipairs(items) do
    lw = math.max(lw, W.width(it.label))
    vw = math.max(vw, #fmt.value(it.value, C.nn(show.format)))
  end
  lw = math.min(lw, max_label or 30)
  local out = {}
  for _, it in ipairs(items) do
    local b, sp, p = {}, {}, 0
    local function put(s, g)
      if g then
        sp[#sp + 1] = { p, p + #s, g }
      end
      b[#b + 1] = s
      p = p + #s
    end
    put("■", it.group)
    if show_labels then
      put(" " .. W.pad(it.label, lw), ctx.css:hl("legend"))
    end
    if show_values then
      put("  " .. W.pad(fmt.value(it.value, C.nn(show.format)), vw, "right"), ctx.css:hl("value"))
    end
    if show_pct then
      put(("  %5.1f%%"):format(it.value / sum * 100), ctx.css:hl("percent"))
    end
    out[#out + 1] = { text = table.concat(b), spans = sp }
  end
  return out
end

---Centered title line, or nil.
function M.title(show, width)
  local title = C.nn(show.title)
  if not title or title == "" then
    return nil
  end
  local t = W.truncate(title, width)
  local pad = math.max(0, math.floor((width - W.width(t)) / 2))
  return { text = string.rep(" ", pad) .. t, spans = { { pad, pad + #t, "DbDashTitle" } } }
end

return M
