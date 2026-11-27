-- db.run with a driver queried on ticks (connect): one query per tick, each result or error
-- passed on with its tag, the run going on after an error; one tick without wait_tick.
local db = require("dbdash.db")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

---Run until it ends; ticks: how many times wait_tick says go on.
local function run(query, ticks)
  local results, ended = {}, false
  local n = 0
  local wait = ticks and function()
    n = n + 1
    return n <= ticks
  end or nil
  local handle
  handle = db.run("sqlite:///:memory:", query, { wait_tick = wait }, function(err, value, _, tag)
    results[#results + 1] =
      { err = err and err.message or nil, rows = value and value.rows, tag = tag }
    handle:report(err == nil) -- the consumer took it: the next tick may query
  end, function(err)
    ended = { err = err }
  end)
  vim.wait(5000, function()
    return ended ~= false
  end, 10)
  return results, ended
end

T["one query per tick, with the tag of its rendering"] = function()
  local i = 0
  local results, ended = run(function()
    i = i + 1
    return ("SELECT %d AS n"):format(i), "run " .. i
  end, 3)
  eq(results, {
    { rows = { { 1 } }, tag = "run 1" },
    { rows = { { 2 } }, tag = "run 2" },
    { rows = { { 3 } }, tag = "run 3" },
  })
  eq(ended.err, nil)
end

T["an error is a result: the run goes on"] = function()
  local i = 0
  local results = run(function()
    i = i + 1
    return i == 2 and "SELECT * FROM missing" or "SELECT 1 AS n"
  end, 3)
  eq(#results, 3)
  eq({ results[1].err, results[3].err }, { nil, nil })
  eq(results[2].err:find("no such table", 1, true) ~= nil, true)
end

T["without wait_tick: one query"] = function()
  local results, ended = run("SELECT 7 AS n")
  eq({ #results, results[1].rows, ended.err }, { 1, { { 7 } }, nil })
end

T["a query that cannot be rendered is an error of that tick"] = function()
  local results = run(function()
    error({ phase = "template", message = "bad template" }, 0)
  end, 1)
  eq(results[1].err, "bad template")
end

return T
