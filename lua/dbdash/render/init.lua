-- Render entry point: resolves the chart style through the registry, builds the render
-- context and runs the style. Chart styles are pure functions (rs, show, ctx) -> Output.
local highlight = require("dbdash.render.highlight")
local registry = require("dbdash.render.registry")
local W = require("dbdash.util.width")

local M = {}

---@class dbdash.render.Ctx
---@field width integer
---@field height integer
---@field color fun(spec: string?, fallback: string?): string
---@field strwidth fun(s: string): integer
---@field canvas fun(cols: integer, rows: integer, xlim: number[], ylim: number[]): dbdash.render.Canvas
---@field canvas_type table the canvas module (px_per_char)
---@field ticks fun(lo: number, hi: number, count: integer): number[], string[]
---@field limits fun(lo: number, hi: number, count: integer): number, number, number
---@field frame table
---@field palette fun(i: integer): string
---@field history number[]? recent values of this panel, oldest first (stat charts)
---@field value_group string? highlight group for the value (stat thresholds)

---@class dbdash.render.Output
---@field lines string[]
---@field hl { row: integer, col_s: integer, col_e: integer, group: string }[] 0-based rows, byte columns

local function options()
  local ok, dbdash = pcall(require, "dbdash")
  return ok and dbdash.options or {}
end

local function need(name)
  local impl = registry.get(name)
  if not impl then
    error({ phase = "render", message = ("unknown style '%s' (available: %s)"):format(
      name,
      table.concat(registry.names(name:match("^(.*/)")), ", ")
    ) }, 0)
  end
  return impl
end

---@param opts { width: integer, height: integer?, canvas: string?, ticks: string?, palette: string? }
---@return dbdash.render.Ctx
function M.ctx(opts)
  local o = options()
  local canvas_type = need("canvas/" .. (opts.canvas or "braille"))
  local ticks = need("ticks/" .. (opts.ticks or o.ticks or "nice"))
  local palette = need("palette/" .. (opts.palette or o.palette or "theme"))
  return {
    width = math.max(opts.width or 80, 20),
    height = math.max(opts.height or 24, 5),
    color = highlight.color,
    strwidth = W.width,
    canvas = canvas_type.new,
    canvas_type = canvas_type,
    ticks = ticks.ticks,
    limits = ticks.limits,
    frame = need("frame/" .. (opts.frame or "unicodeplots")),
    palette = palette.color,
  }
end

local function nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

-- Parts of a chart and the style.* key that colors them (CSS: one rule per element).
M.PARTS = {
  DbDashAxis = "axis_style",
  DbDashLabel = "label_style",
  DbDashLegend = "legend_style",
  DbDashNumber = "value_style",
  DbDashNull = "null_style",
  DbDashBorder = "border_style",
  DbDashHeader = "header_style",
  DbDashStatValue = "color",
  DbDashText = "color",
}

---Recolor the parts of an output by show.style (axis_style, label_style, ...).
---@param out dbdash.render.Output
---@param style table
function M.restyle(out, style)
  local map
  for group, key in pairs(M.PARTS) do
    local spec = nn(style[key])
    if spec then
      map = map or {}
      map[group] = highlight.color(spec, group)
    end
  end
  if map then
    for _, h in ipairs(out.hl) do
      h.group = map[h.group] or h.group
    end
  end
  return out
end

-- Where a title sits when show.style.title_align does not say.
local LEFT_TITLES = { stat = true, text = true }

---Put the title line above a chart: aligned over the chart's width.
function M.with_title(out, title, style, width, chart_type, subtitle)
  local w = 0
  for _, l in ipairs(out.lines) do
    w = math.max(w, W.width(l))
  end
  w = math.min(math.max(w, 1), width)
  local align = nn(style.title_align) or (LEFT_TITLES[chart_type] and "left" or "center")
  local line, s, e = require("dbdash.render.box").title_line(title, w, align, nn(style.ellipsis))
  local group = highlight.color(nn(style.title_style), "DbDashTitle")
  line = line:gsub("%s+$", "")
  if subtitle then -- a muted second line (Chart.js subtitle)
    local sl, ss, se = require("dbdash.render.box").title_line(subtitle, w, align, nn(style.ellipsis))
    out = M.with_title(out, sl:sub(ss + 1, se), vim.tbl_extend("force", {}, style, {
      title_style = "DbDashMuted",
      title_align = align,
    }), width, chart_type)
    -- the subtitle is now the first line; keep the title above (or below) it
  end
  -- caption: bottom puts it under the chart (CSS caption-side)
  if nn(style.caption) == "bottom" then
    local lines = vim.list_extend({}, out.lines)
    lines[#lines + 1] = line
    local hl = vim.list_extend({}, out.hl)
    hl[#hl + 1] = { row = #lines - 1, col_s = s, col_e = e, group = group }
    return { lines = lines, hl = hl }
  end
  local hl = { { row = 0, col_s = s, col_e = e, group = group } }
  for _, h in ipairs(out.hl) do
    local c = vim.deepcopy(h)
    c.row = h.row + 1
    hl[#hl + 1] = c
  end
  local lines = { line }
  vim.list_extend(lines, out.lines)
  return { lines = lines, hl = hl }
end

local function message(text, group)
  return { lines = { text }, hl = { { row = 0, col_s = 0, col_e = #text, group = group } } }
end

---Render a result set according to the show config.
---@param rs dbdash.db.ResultSet
---@param show table
---@param opts { width: integer, height: integer?, history: number[]?, fill: boolean? }
---@return dbdash.render.Output
function M.render(rs, show, opts)
  local renderer, canvas = registry.resolve(show, options().styles)
  local ok, res = pcall(function()
    local ctx = M.ctx({ width = opts.width, height = opts.height, canvas = canvas, palette = show.palette ~= vim.NIL and show.palette or nil })
    local w = tonumber(show.width ~= vim.NIL and show.width or nil)
    if w then
      ctx.width = math.min(ctx.width, w)
    end
    -- Plot rows: show.height, else the whole cell (opts.fill: a fixed or fr grid row),
    -- else setup's default (each chart's own when unset); never fewer than min_height
    -- (CSS min-height), unless the plot is capped below that.
    local defaults = require("dbdash").options.defaults
    local h = tonumber(show.height ~= vim.NIL and show.height or nil) or (opts.fill and 10000) or defaults.height
    if h then
      ctx.plot_height = h
    end
    local mh = tonumber(show.min_height ~= vim.NIL and show.min_height or nil) or defaults.min_height or 3
    ctx.min_plot_height = math.min(mh, h or 15)
    ctx.history = opts.history
    local st = nn(show.style) or {}
    ctx.border = nn(st.border)
    ctx.show_axes = nn(st.show_axes) ~= false
    ctx.ellipsis = nn(st.ellipsis) or "…"
    local style = need("chart/" .. show.type .. "/" .. renderer)
    -- The title is drawn here for every chart type (title_style, title_align,
    -- show_title); the chart gets the rest of the height.
    local title = nn(show.title)
    if nn(st.show_title) == false then
      title = nil
    end
    local inner = show
    if nn(show.title) ~= nil or nn(show.subtitle) ~= nil then
      inner = {}
      for k, v in pairs(show) do
        inner[k] = v
      end
      inner.title, inner.subtitle = vim.NIL, vim.NIL
      setmetatable(inner, getmetatable(show))
    end
    local subtitle = nn(show.subtitle)
    if title and title ~= "" then
      ctx.height = math.max(ctx.height - (subtitle and 2 or 1), 5)
    end
    local out = (style.render or style)(rs, inner, ctx)
    out = M.restyle(out, st)
    if title and title ~= "" then
      out = M.with_title(out, title, st, ctx.width, show.type, subtitle)
    end
    return out
  end)
  if ok then
    return res
  end
  if type(res) == "table" and res.message then
    return message(res.message, "DbDashError")
  end
  error(res, 0)
end

return M
