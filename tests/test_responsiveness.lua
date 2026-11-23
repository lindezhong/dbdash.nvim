-- Queries must not freeze the editor: long computations (crypto, decoding rows) give the
-- main loop a turn through util.async.checkpoint().
local async = require("dbdash.util.async")
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

---Run fn() while a 1 ms timer measures the longest gap of the main loop (ms).
local function longest_stall(fn)
  local maxgap, last = 0, vim.uv.hrtime()
  local t = vim.uv.new_timer()
  t:start(1, 1, function()
    local n = vim.uv.hrtime()
    maxgap = math.max(maxgap, (n - last) / 1e6)
    last = n
  end)
  local ok, err = pcall(fn)
  t:stop()
  t:close()
  assert(ok, err)
  return maxgap
end

T["checkpoint: nothing outside a task, yields inside a long task"] = function()
  local t0 = vim.uv.hrtime()
  for _ = 1, 1000 do
    async.checkpoint() -- not in a task: no yield, no error
  end
  eq((vim.uv.hrtime() - t0) / 1e6 < 50, true)
  local stall = longest_stall(function()
    local done
    async.run(function()
      local t1 = vim.uv.hrtime()
      while vim.uv.hrtime() - t1 < 150e6 do -- 150 ms of work
        async.checkpoint()
      end
    end, function()
      done = true
    end)
    vim.wait(5000, function()
      return done
    end, 1)
  end)
  eq(stall < 40, true)
end

local CASES = {
  { "TLS handshake with verify-full", "postgres://dbdash:dbdash_pw@localhost:15432/dbdash_test?tls=verify-full&ca=tests/fixtures/pki/root.pem", "SELECT 1" },
  { "SCRAM-SHA-256 (MongoDB, 15000 iterations)", "mongodb://dbdash:dbdash_pw@127.0.0.1:17017/admin?authSource=admin", '{"operation":"command","command":{"ping":1}}' },
  { "50k rows (PostgreSQL)", "postgres://dbdash:dbdash_pw@127.0.0.1:15432/dbdash_test", "SELECT g, md5(g::text) FROM generate_series(1, 50000) g" },
  { "50k rows over TLS", "postgres://dbdash:dbdash_pw@localhost:15432/dbdash_test?tls=require", "SELECT g, md5(g::text) FROM generate_series(1, 50000) g" },
}

for _, c in ipairs(CASES) do
  T["it: no long stall: " .. c[1]] = function()
    h.require_it()
    local rs
    local stall = longest_stall(function()
      rs = h.ok(c[2], c[3])
    end)
    MiniTest.add_note(("longest main-loop stall %.0f ms"):format(stall))
    eq(rs.row_count > 0, true)
    -- Was 90-900 ms before checkpoints; now mostly under 30 ms. The margin covers garbage
    -- collection pauses and slow machines while still catching a regression.
    eq(stall < 100, true)
  end
end

return T
