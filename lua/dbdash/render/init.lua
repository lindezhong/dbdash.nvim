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
---@field canvas fun(cols: integer, rows: integer, xlim: number[], ylim: number[]):
---  dbdash.render.Canvas a canvas of cols x rows characters over xlim x ylim
---@field canvas_type table the canvas module (px_per_char)
---@field ticks fun(lo: number, hi: number, count: integer): number[], string[]
---@field limits fun(lo: number, hi: number, count: integer): number, number, number
---@field frame table
---@field palette fun(i: integer): string
---@field history number[]? recent values of this panel, oldest first (stat charts)

---@class dbdash.render.Highlight
---@field row integer
---@field col_s integer
---@field col_e integer
---@field group string

---@class dbdash.render.Output
---@field lines string[]
---@field hl dbdash.render.Highlight[] 0-based rows, byte columns

local function options()
  local ok, dbdash = pcall(require, "dbdash")
  return ok and dbdash.options or {}
end

local function need(name)
  local impl = registry.get(name)
  if not impl then
    error({
      phase = "render",
      message = ("unknown style '%s' (available: %s)"):format(
        name,
        table.concat(registry.names(name:match("^(.*/)")), ", ")
      ),
    }, 0)
  end
  return impl
end

---@class dbdash.render.CtxOpts
---@field width integer
---@field height integer?
---@field canvas string?
---@field ticks string?
---@field palette string?
---@field css dbdash.css.Scope?
---@field type string?

---@param opts dbdash.render.CtxOpts
---@return dbdash.render.Ctx
function M.ctx(opts)
  local o = options()
  local canvas_type = need("canvas/" .. (opts.canvas or "braille"))
  local ticks = need("ticks/" .. (opts.ticks or o.ticks or "nice"))
  local palette = need("palette/" .. (opts.palette or "theme"))
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
    -- the chart's parts are styled through its element (render() passes the dashboard's)
    css = opts.css or require("dbdash.css").scope(nil, opts.type),
  }
end

local function nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

-- Where a title sits when its text-align is "start".
local LEFT_TITLES = { stat = true, text = true }

---The cut marker of a computed text-overflow: "ellipsis" -> "…", "clip" -> "", else
---the string itself (CSS text-overflow: "<string>").
function M.ellipsis(c)
  local v = c["text-overflow"]
  if v == nil or v == "ellipsis" then
    return "…"
  elseif v == "clip" then
    return ""
  end
  return v
end

---Put the title line (and the subtitle under it) above a chart, aligned over the chart's
---width; caption-side: bottom puts them under it. Styles: the title and subtitle parts.
function M.with_title(out, title, subtitle, width, chart_type, css)
  local w = 0
  for _, l in ipairs(out.lines) do
    w = math.max(w, W.width(l))
  end
  w = math.min(math.max(w, 1), width)
  local box = require("dbdash.render.box")
  local tc = css:get("title")
  local function line_of(text, part)
    local c = css:get(part)
    local align = c["text-align"] ~= "start" and c["text-align"]
      or (LEFT_TITLES[chart_type] and "left" or "center")
    local line, s, e = box.title_line(text, w, align, M.ellipsis(c))
    return {
      lines = { (line:gsub("%s+$", "")) },
      hl = { { row = 0, col_s = s, col_e = e, group = css:hl(part) } },
    }
  end
  local parts = { line_of(title, "title") }
  if subtitle and css:get("subtitle").display ~= "none" then
    parts[#parts + 1] = line_of(subtitle, "subtitle")
  end
  local stack = require("dbdash.paint").stack
  if tc["caption-side"] == "bottom" then
    return stack(vim.list_extend({ out }, parts))
  end
  parts[#parts + 1] = out
  return stack(parts)
end

local function message(text, group)
  return { lines = { text }, hl = { { row = 0, col_s = 0, col_e = #text, group = group } } }
end

---@class dbdash.render.RenderOpts
---@field width integer
---@field height integer?
---@field history number[]?
---@field fill boolean?
---@field node dbdash.dom.Node?
---@field style table?

---Render a result set according to the show config and the chart element's computed
---style (renderer, canvas, palette, plot sizes, title placement).
---@param rs dbdash.db.ResultSet
---@param show table
---@param opts dbdash.render.RenderOpts
---  node: the chart's element in a dashboard; without it the chart gets a document of its
---  own with the default sheets and `style` (selector -> properties) as its sheet
---@return dbdash.render.Output
function M.render(rs, show, opts)
  local css = require("dbdash.css").scope(opts.node, show.type, opts.style)
  local ok, res = pcall(function()
    local chart = css:get()
    local renderer, canvas = registry.resolve(show.type, chart)
    local ctx = M.ctx({
      width = opts.width,
      height = opts.height,
      canvas = canvas,
      palette = chart.palette,
      css = css,
    })
    if chart["max-width"] then
      ctx.width = math.min(ctx.width, chart["max-width"])
    end
    -- Plot rows: plot { height }, else the whole cell (opts.fill: a fixed or fr grid row),
    -- else each chart's own (15); never fewer than plot { min-height } (default 8), unless
    -- the plot is capped below that.
    local plot = css:get("plot")
    local h = plot.height or (opts.fill and 10000) or nil
    ctx.plot_height = h
    ctx.min_plot_height = math.min(plot["min-height"] or 8, h or 15)
    ctx.history = opts.history
    local style = need("chart/" .. show.type .. "/" .. renderer)
    -- the chart's content as DOM (dom/content): in a dashboard already built before
    -- styles were computed; a chart rendered on its own builds it here
    -- (a result the content cannot use is left to the renderer to report)
    pcall(require("dbdash.dom.content").build, css.node, rs, show)
    -- The title is drawn here for every chart type; the chart gets the rest of the height.
    local title = nn(show.title)
    if css:get("title").display == "none" then
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
    if title and title ~= "" then
      out = M.with_title(out, title, subtitle, ctx.width, show.type, css)
    end
    return out
  end)
  if ok then
    return res
  end
  if type(res) == "table" and res.message then
    return message(res.message, css:hl("error"))
  end
  error(res, 0)
end

return M
