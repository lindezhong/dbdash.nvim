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
  local visits = {
    12,
    8,
    5,
    3,
    2,
    4,
    15,
    40,
    85,
    120,
    135,
    128,
    110,
    125,
    140,
    150,
    138,
    120,
    95,
    80,
    66,
    50,
    35,
    20,
  }
  for h = 0, 23 do
    rows[#rows + 1] = { ("%02d:00"):format(h), visits[h + 1], math.floor(visits[h + 1] * 0.3) }
  end
  return resultset.new({
    { name = "hour", type = "string" },
    { name = "visits", type = "integer" },
    { name = "signups", type = "integer" },
  }, rows)
end

-- Exam scores by class (boxplot, histogram).
function M.scores()
  local data = {
    A = { 55, 61, 64, 68, 70, 72, 73, 75, 78, 80, 82, 85, 99 },
    B = { 40, 48, 52, 58, 60, 63, 66, 69, 71, 74, 77 },
    C = { 70, 72, 75, 77, 79, 81, 83, 86, 88, 90, 92, 95, 20 },
  }
  local rows = {}
  for _, class in ipairs({ "A", "B", "C" }) do
    for _, v in ipairs(data[class]) do
      rows[#rows + 1] = { class, v }
    end
  end
  return resultset.new(
    { { name = "class", type = "string" }, { name = "score", type = "integer" } },
    rows
  )
end

-- Activity per weekday and hour (heatmap).
function M.activity()
  local rows = {}
  local days = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
  for d, day in ipairs(days) do
    for h = 0, 23, 2 do
      local v = math.floor(50 + 40 * math.sin((h - 6) / 24 * 2 * math.pi) + (d <= 5 and 30 or -10))
      rows[#rows + 1] = { day, h, math.max(v, 0) }
    end
  end
  return resultset.new({
    { name = "day", type = "string" },
    { name = "hour", type = "integer" },
    { name = "activity", type = "integer" },
  }, rows)
end

-- Companies with revenue, margin, size and segment (scatter, bubble).
function M.companies()
  return resultset.new({
    { name = "company", type = "string" },
    { name = "revenue", type = "number" },
    { name = "margin", type = "number" },
    { name = "size", type = "number" },
    { name = "segment", type = "string" },
  }, {
    { "Acme", 12.5, 8.2, 30, "Small" },
    { "Globex", 48.0, 21.5, 210, "Large" },
    { "Initech", 22.1, 12.0, 55, "Mid" },
    { "Umbrella", 65.3, 30.1, 400, "Large" },
    { "Hooli", 35.7, 18.4, 120, "Mid" },
    { "Vandelay", 8.9, 4.5, 12, "Small" },
  })
end

return M
