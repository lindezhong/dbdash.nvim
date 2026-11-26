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
  -- show.sort (asc / desc by value) and show.top: the first N, the rest as one slice
  -- (show.other_label, default "Other"; styled as series.other), as ECharts examples do.
  local order = C.nn(show.sort)
  if order == "asc" or order == "desc" then
    table.sort(items, function(a, b)
      if order == "asc" then
        return a.value < b.value
      end
      return a.value > b.value
    end)
  end
  local top = tonumber(C.nn(show.top))
  if top and #items > top then
    local rest = 0
    for i = top + 1, #items do
      rest = rest + items[i].value
    end
    items = { unpack(items, 1, top) }
    items[#items + 1] = { label = C.nn(show.other_label) or "Other", value = rest, other = true }
  end
  for i, it in ipairs(items) do
    -- the slice's series element (series.other for the rest)
    it.group = C.color(ctx, show, i, nil, it.label)
  end
  return items, sum
end

---Where the legend goes: "right" (beside the circle, the default), "bottom" or "none".
function M.legend_position(ctx)
  return C.legend_position(ctx, 2)
end

---Legend lines "■ label  value  pct%"; label, value and percent { display: none } leave
---a column out. Spans are byte ranges within each line.
---@param max_label integer? label width cap (default 30)
---@return { text: string, spans: { [1]: integer, [2]: integer, [3]: string }[] }[]
function M.legend(items, sum, show, max_label, ctx)
  local lw, vw = 0, 0
  for _, it in ipairs(items) do
    lw = math.max(lw, W.width(it.label))
    vw = math.max(vw, #fmt.value(it.value, C.nn(show.format)))
  end
  lw = math.min(lw, max_label or 30)
  local out = {}
  for i, it in ipairs(items) do
    -- the legend item's own label, value and percent elements
    local show_labels, g_label = C.item_part(ctx, "legend", i, "label", ctx.css:hl("legend"))
    local show_values, g_value = C.item_part(ctx, "legend", i, "value", ctx.css:hl("value"))
    local show_pct, g_pct = C.item_part(ctx, "legend", i, "percent", ctx.css:hl("percent"))
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
      put(" " .. W.pad(it.label, lw), g_label)
    end
    if show_values then
      put("  " .. W.pad(fmt.value(it.value, C.nn(show.format)), vw, "right"), g_value)
    end
    if show_pct then
      put(("  %5.1f%%"):format(it.value / sum * 100), g_pct)
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
