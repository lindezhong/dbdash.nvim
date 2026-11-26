-- Replaced elements (Servo's layout/replaced.rs): a chart gets a size from layout, and
-- its content is drawn elsewhere (the chart code, our "canvas thread": render/) into a
-- raster of lines and highlights; layout only places it.
local css = require("dbdash.css")

local M = {}

local function message(text, group)
  return { lines = { text }, hl = { { row = 0, col_s = 0, col_e = #text, group = group } } }
end

---The raster of a panel's chart at `width` x `height` (or a placeholder: loading, a
---render error, nothing after a query error).
---@param fill boolean? the plot fills the height (a fixed or fr grid row)
---@return dbdash.render.Output
function M.raster(p, show, width, height, fill)
  if p.rs then
    local ok, out = pcall(
      require("dbdash.render").render,
      p.rs,
      show,
      { width = width, height = height, history = p.values, fill = fill, node = p.chart_node }
    )
    if ok then
      return out
    end
    return message("render error: " .. tostring(out), css.scope(p.node):hl("error"))
  elseif not p.error then
    return message("Loading…", css.scope(p.node):hl("note"))
  end
  return { lines = {}, hl = {} }
end

return M
