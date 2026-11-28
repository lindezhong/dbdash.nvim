-- Render entry point: resolves the chart's renderer through the registry, builds the render
-- context and runs it. Renderers are { name, render(rs, show, ctx) -> Output }.
local highlight = require("dbdash.css.hl")
local registry = require("dbdash.render.registry")
local W = require("dbdash.util.width")

local M = {}

---The implementation registered as `name`, or a render error.
---@return table
local function need(name)
  local impl = registry.get(name)
  if impl then
    return impl
  end
  return require("dbdash.util.error").raise(
    "render",
    ("unknown style '%s' (available: %s)"):format(
      name,
      table.concat(registry.names(name:match("^(.*/)")), ", ")
    )
  )
end

---@class dbdash.render.CtxOpts
---@field width integer
---@field height integer?
---@field canvas string?
---@field ticks string?
---@field palette string?
---@field css dbdash.css.Scope?
---@field type string?
---@field frame string? (default "unicodeplots")

---@param opts dbdash.render.CtxOpts
---@return dbdash.render.Ctx
function M.ctx(opts)
  local canvas_type = need("canvas/" .. (opts.canvas or "braille"))
  local ticks = need("ticks/" .. (opts.ticks or registry.ticks))
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
    -- the chart's content as DOM (render/content): a dashboard's is built by its commit
    -- (dashboard/commit.lua); a chart rendered on its own builds it here (a result the
    -- content cannot use is left to the renderer to report)
    if not opts.node then
      pcall(require("dbdash.render.content").build, css.node, rs, show)
    end
    -- the chart only: its title is its panel's (layout/view.lua)
    local out = style.render(rs, show, ctx)
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
