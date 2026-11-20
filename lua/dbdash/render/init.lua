-- Render entry point: builds the render context and dispatches to the chart style.
-- Chart styles are pure functions (rs, show, ctx) -> { lines, hl }.
local highlight = require("dbdash.render.highlight")
local W = require("dbdash.util.width")

local M = {}

---@class dbdash.render.Ctx
---@field width integer
---@field height integer
---@field color fun(spec: string?, fallback: string?): string
---@field strwidth fun(s: string): integer

---@class dbdash.render.Output
---@field lines string[]
---@field hl { row: integer, col_s: integer, col_e: integer, group: string }[] 0-based rows, byte columns

---@param opts { width: integer, height: integer? }
---@return dbdash.render.Ctx
function M.ctx(opts)
  return {
    width = math.max(opts.width or 80, 20),
    height = math.max(opts.height or 24, 5),
    color = highlight.color,
    strwidth = W.width,
  }
end

---Render a result set according to the show config.
---@param rs dbdash.db.ResultSet
---@param show table
---@param opts { width: integer, height: integer? }
---@return dbdash.render.Output
function M.render(rs, show, opts)
  local ctx = M.ctx(opts)
  if show.width and tonumber(show.width) then
    ctx.width = math.min(ctx.width, tonumber(show.width))
  end
  if show.type == "table" then
    return require("dbdash.render.table").render(rs, show, ctx)
  end
  local msg = ("chart type '%s' is not available yet; showing the data as a table"):format(show.type)
  local out = require("dbdash.render.table").render(rs, { title = show.title, style = {} }, ctx)
  table.insert(out.lines, 1, msg)
  for _, h in ipairs(out.hl) do
    h.row = h.row + 1
  end
  table.insert(out.hl, 1, { row = 0, col_s = 0, col_e = #msg, group = "DbDashWarn" })
  return out
end

return M
