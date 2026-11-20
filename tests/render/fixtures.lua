-- Fixed datasets shared by all render tests (design §11.5).
local resultset = require("dbdash.db.resultset")
local NULL = vim.NIL

local M = {}

function M.departments()
  return resultset.new({
    { name = "id", type = "integer" },
    { name = "department", type = "string" },
    { name = "headcount", type = "integer" },
    { name = "budget", type = "decimal" },
    { name = "manager", type = "string" },
  }, {
    { 1, "IT", 42, "1250000.50", "Alice" },
    { 2, "HR", 7, "310000.00", NULL },
    { 3, "Finance", 15, "880000.25", "王小明" },
    { 4, "Research & Development", 120, "4200000.00", "Bob" },
  })
end

function M.hourly_visits()
  local rows = {}
  local visits = { 12, 8, 5, 3, 2, 4, 15, 40, 85, 120, 135, 128, 110, 125, 140, 150, 138, 120, 95, 80, 66, 50, 35, 20 }
  for h = 0, 23 do
    rows[#rows + 1] = { ("%02d:00"):format(h), visits[h + 1], math.floor(visits[h + 1] * 0.3) }
  end
  return resultset.new({
    { name = "hour", type = "string" },
    { name = "visits", type = "integer" },
    { name = "signups", type = "integer" },
  }, rows)
end

return M
