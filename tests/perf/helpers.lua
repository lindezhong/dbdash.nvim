-- Performance test helpers: medians of repeated runs, data of a given size for every chart
-- type, and documents to render into (a dashboard-like tree: dashboard > panel > chart).
local M = {}

local css = require("dbdash.css")
local dom = require("dbdash.dom.node")
local parser = require("dbdash.css.parser")
local resultset = require("dbdash.db.resultset")
local style = require("dbdash.css.style")

---Timing tests are skipped with DBDASH_PERF=0 (slow machines); counting tests always run.
function M.timing_enabled()
  return vim.env.DBDASH_PERF ~= "0"
end

---Median wall time (ms) of `n` runs of `fn(i)` (`setup(i)` runs before each, untimed), and
---the memory the last run kept (MB).
---@return number ms, number mb
function M.measure(fn, n, setup)
  n = n or 5
  local times, mb = {}, 0
  for i = 1, n do
    if setup then
      setup(i)
    end
    collectgarbage()
    collectgarbage()
    local m0 = collectgarbage("count")
    local t0 = vim.uv.hrtime()
    fn(i)
    times[i] = (vim.uv.hrtime() - t0) / 1e6
    mb = (collectgarbage("count") - m0) / 1024
  end
  table.sort(times)
  return times[math.floor((n + 1) / 2)], mb
end

---A sheet like a real dashboard's: stripes, threshold and highlight classes, a series color.
M.SHEET = {
  ["row:nth-child(even)"] = { ["background-color"] = "#202020" },
  ["cell.null"] = { color = "Comment" },
  ["line.error"] = { color = "#e06c75" },
  ["series.s1"] = { color = "#61afef" },
}

---A document with the UA and M.SHEET, and a chart element of `type` in a panel.
---@return dbdash.dom.Document doc, dbdash.dom.Node chart
function M.chart(type)
  local doc = css.document("dashboard")
  doc:set_sheet("author", assert(parser.sheet(M.SHEET)))
  local panel = doc.root:append(dom.new("panel", { id = "p", classes = { type } }))
  local chart = panel:append(dom.new("chart", { classes = { type }, attrs = { type = type } }))
  style.restyle(doc)
  return doc, chart
end

local function rs(columns, rows)
  local cols = {}
  for i, c in ipairs(columns) do
    cols[i] = { name = c[1], type = c[2] }
  end
  return resultset.new(cols, rows)
end

---Data and show config of each scenario: fn(size, seed) -> rs, show. `seed` changes the
---values but not the shape (a new result of the same query).
M.SCENARIOS = {
  table = function(n, seed)
    local rows = {}
    for r = 1, n do
      rows[r] = { "name" .. r, (r * 7 + seed) % 1000, (r * 13 + seed) % 97 == 0 and vim.NIL or r * 3, r % 5, "x" .. (r + seed) % 9, r * 1.5 }
    end
    return rs({ { "name", "string" }, { "a", "integer" }, { "b", "integer" }, { "c", "integer" }, { "d", "string" }, { "e", "number" } }, rows), {
      type = "table",
      column_list = { "name", { column = "a", thresholds = { { value = 900, class = "danger" } } }, "b", "c", "d", "e" },
    }
  end,
  text = function(n, seed)
    local rows = {}
    for r = 1, n do
      rows[r] = { ("2026-11-26 12:%02d:%02d %s request %d took %d ms"):format(r % 60, (r + seed) % 60, (r + seed) % 7 == 0 and "ERROR" or "INFO", r, (r * 37 + seed) % 900) }
    end
    return rs({ { "line", "string" } }, rows), { type = "text", highlight = { { pattern = "ERROR", class = "error" } } }
  end,
  bar = function(n, seed)
    local rows = {}
    for r = 1, n do
      rows[r] = { "c" .. r, (r * 7 + seed) % 100, (r * 11 + seed) % 100, (r * 13 + seed) % 100 }
    end
    return rs({ { "k", "string" }, { "s1", "integer" }, { "s2", "integer" }, { "s3", "integer" } }, rows),
      { type = "bar", x_column = "k", y_columns = { "s1", "s2", "s3" } }
  end,
  line = function(n, seed)
    local rows = {}
    for r = 1, n do
      rows[r] = { r, math.sin(r / 10 + seed) * 50, math.cos(r / 7) * 40, (r + seed) % 30 }
    end
    return rs({ { "x", "integer" }, { "s1", "number" }, { "s2", "number" }, { "s3", "integer" } }, rows),
      { type = "line", x_column = "x", y_columns = { "s1", "s2", "s3" } }
  end,
  scatter = function(n, seed)
    local rows = {}
    for r = 1, n do
      rows[r] = { (r * 37 + seed) % 500, (r * 53) % 300, "g" .. r % 4 }
    end
    return rs({ { "x", "integer" }, { "y", "integer" }, { "g", "string" } }, rows),
      { type = "scatter", x_column = "x", y_column = "y", color_column = "g" }
  end,
  pie = function(n, seed)
    local rows = {}
    for r = 1, n do
      rows[r] = { "slice" .. r, 1 + (r * 7 + seed) % 50 }
    end
    return rs({ { "l", "string" }, { "v", "integer" } }, rows), { type = "pie", label_column = "l", value_column = "v" }
  end,
  boxplot = function(n, seed)
    local rows = {}
    for r = 1, n * 20 do
      rows[r] = { "k" .. r % n, (r * 37 + seed) % 500 }
    end
    return rs({ { "k", "string" }, { "v", "integer" } }, rows), { type = "boxplot", category_column = "k", value_column = "v" }
  end,
  heatmap = function(n, seed)
    local rows = {}
    for x = 1, n do
      for y = 1, math.max(7, math.floor(n / 2)) do
        rows[#rows + 1] = { "x" .. x, "y" .. y, (x * y + seed) % 100 }
      end
    end
    return rs({ { "x", "string" }, { "y", "string" }, { "v", "integer" } }, rows),
      { type = "heatmap", x_column = "x", y_column = "y", value_column = "v" }
  end,
  stat = function(n, seed)
    local cols, row = {}, {}
    for c = 1, n do
      cols[c] = { "v" .. c, "integer" }
      row[c] = c * 100 + seed
    end
    local names = {}
    for c = 1, n do
      names[c] = "v" .. c
    end
    return rs(cols, { row }), { type = "stat", value_columns = n > 1 and names or nil, value_column = "v1" }
  end,
}

---How many items a scenario of `size` has (rows, points, cells, ...): costs grow with it.
function M.items(kind, size)
  if kind == "heatmap" then
    return size * math.max(7, math.floor(size / 2))
  elseif kind == "boxplot" then
    return size * 20
  end
  return size
end

---Sizes per scenario: { typical, large }.
M.SIZES = {
  table = { 100, 1000 },
  text = { 100, 1000 },
  bar = { 12, 100 },
  line = { 200, 2000 },
  scatter = { 200, 2000 },
  pie = { 8, 50 },
  boxplot = { 5, 50 },
  heatmap = { 24, 100 },
  stat = { 1, 6 },
}

return M
