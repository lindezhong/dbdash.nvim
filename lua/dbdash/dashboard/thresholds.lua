-- Threshold steps that notify: panel:threshold when a value rises to a step with
-- notify = true, again after falling back and crossing it again.
local M = {}

---@param p dbdash.Panel
---@param rs dbdash.db.ResultSet
local function check(p, rs)
  local ok, levels = pcall(require("dbdash.render.thresholds").levels, rs, p.cfg.show)
  if not ok then
    return -- the chart reports what is wrong with its data
  end
  p.levels = p.levels or {}
  for key, cur in pairs(levels) do
    local prev = p.levels[key] or 0
    if cur.level > prev and cur.step and cur.step.notify then
      p:emit("panel:threshold", cur)
    end
    p.levels[key] = cur.level
  end
end

---Check the results of the panels of dashboard `d`.
---@param d dbdash.Dashboard
function M.attach(d)
  d.events:on("panel:result", check)
end

return M
