local A = require("dbdash.util.async")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

-- Run the event loop until `done()` is true or the timeout expires.
local function wait(done)
  vim.wait(1000, done, 5)
end

T["await resumes after an async callback"] = function()
  local got
  A.run(function()
    local a, b = A.await(function(x, cb)
      vim.defer_fn(function()
        cb(x + 1, "ok")
      end, 10)
    end, 41)
    return a, b
  end, function(err, a, b)
    got = { err, a, b }
  end)
  wait(function()
    return got ~= nil
  end)
  eq(got, { nil, 42, "ok" })
end

T["await handles synchronous callbacks"] = function()
  local got
  A.run(function()
    return A.await(function(cb)
      cb(7)
    end)
  end, function(_, v)
    got = v
  end)
  eq(got, 7)
end

T["errors are passed to the callback, tables untouched"] = function()
  local got
  A.run(function()
    A.sleep(5)
    error({ phase = "query", message = "boom" })
  end, function(err)
    got = err
  end)
  wait(function()
    return got ~= nil
  end)
  eq(got, { phase = "query", message = "boom" })
end

T["string errors carry a traceback"] = function()
  local got
  A.run(function()
    error("bad thing")
  end, function(err)
    got = err
  end)
  MiniTest.expect.equality(got:find("bad thing", 1, true) ~= nil, true)
  MiniTest.expect.equality(got:find("traceback", 1, true) ~= nil, true)
end

T["await outside a task fails loudly"] = function()
  MiniTest.expect.error(function()
    A.await(function() end)
  end, "inside async.run")
end

return T
