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

local function message(text, group)
  return { lines = { text }, hl = { { row = 0, col_s = 0, col_e = #text, group = group } } }
end

---Render a result set according to the show config.
---@param rs dbdash.db.ResultSet
---@param show table
---@param opts { width: integer, height: integer? }
---@return dbdash.render.Output
function M.render(rs, show, opts)
  local renderer, canvas = registry.resolve(show, options().styles)
  local ok, res = pcall(function()
    local ctx = M.ctx({ width = opts.width, height = opts.height, canvas = canvas, palette = show.palette ~= vim.NIL and show.palette or nil })
    local w = tonumber(show.width ~= vim.NIL and show.width or nil)
    if w then
      ctx.width = math.min(ctx.width, w)
    end
    local h = tonumber(show.height ~= vim.NIL and show.height or nil) or require("dbdash").options.defaults.height
    if h then
      ctx.plot_height = h
    end
    local style = need("chart/" .. show.type .. "/" .. renderer)
    return (style.render or style)(rs, show, ctx)
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
