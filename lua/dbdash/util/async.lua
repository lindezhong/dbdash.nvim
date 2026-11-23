-- Minimal coroutine helpers: run a function as a task, and await callback-style APIs.
local M = {}

local unpack = unpack or table.unpack

-- Maps a running coroutine to the function that resumes it.
local resumers = setmetatable({}, { __mode = "k" })
-- When each task last got the CPU (hrtime), for checkpoint().
local slice_start = setmetatable({}, { __mode = "k" })

---Longest stretch (ns) a task runs before checkpoint() gives the main loop a turn.
M.SLICE_NS = 8e6

local function pack(...)
  return { n = select("#", ...), ... }
end

---Run `fn` as a coroutine task. `cb(err, ...)` receives the error or the return values.
---Without `cb`, errors are re-raised on the main loop so they are not silently lost.
---@param fn fun(...): ...
---@param cb? fun(err: any, ...)
function M.run(fn, cb)
  local co = coroutine.create(fn)
  local function step(...)
    slice_start[co] = vim.uv.hrtime()
    local res = pack(coroutine.resume(co, ...))
    if not res[1] then
      resumers[co] = nil
      local err = res[2]
      if type(err) == "string" then
        err = debug.traceback(co, err)
      end
      if cb then
        cb(err)
      else
        vim.schedule(function()
          error(err, 0)
        end)
      end
    elseif coroutine.status(co) == "dead" then
      resumers[co] = nil
      if cb then
        cb(nil, unpack(res, 2, res.n))
      end
    end
  end
  resumers[co] = step
  step()
end

---True when called from inside a task started with `run`.
---@return boolean
function M.in_task()
  local co = coroutine.running()
  return co ~= nil and resumers[co] ~= nil
end

---Call `fn(..., callback)` and suspend the current task until `callback` fires.
---Returns whatever the callback was called with. Safe if `fn` calls back synchronously;
---extra callback invocations are ignored.
---@param fn function
---@return ...
function M.await(fn, ...)
  local co = coroutine.running()
  local resume = co and resumers[co]
  assert(resume, "async.await must be called inside async.run")
  local args = pack(...)
  local done, sync, results = false, true, nil
  args.n = args.n + 1
  args[args.n] = function(...)
    if done then
      return
    end
    done = true
    results = pack(...)
    if not sync then
      resume()
    end
  end
  fn(unpack(args, 1, args.n))
  sync = false
  if not done then
    coroutine.yield()
  end
  return unpack(results, 1, results.n)
end

---Turn a callback-last function into one that awaits inside a task.
---@param fn function
---@return function
function M.wrap(fn)
  return function(...)
    return M.await(fn, ...)
  end
end

---Yield until the main loop is safe for `vim.api` calls (leaves a libuv fast callback).
function M.main()
  if vim.in_fast_event() then
    M.await(vim.schedule)
  end
end

---Give the main loop a turn when the current task has run longer than SLICE_NS, so long
---computations (crypto, decoding rows) do not freeze the editor. Outside a task (tests,
---synchronous callers) it does nothing.
function M.checkpoint()
  local co = coroutine.running()
  local started = co and slice_start[co]
  if started and resumers[co] and vim.uv.hrtime() - started > M.SLICE_NS then
    -- A timer, not vim.schedule: scheduled callbacks queued while the event queue is being
    -- processed run in the same pass, so input, timers and I/O would still wait.
    M.await(function(cb)
      vim.defer_fn(cb, 0)
    end)
  end
end

---Sleep for `ms` milliseconds inside a task.
---@param ms integer
function M.sleep(ms)
  M.await(function(cb)
    vim.defer_fn(cb, ms)
  end)
end

return M
