-- Run ids: UUID v7 made in Lua (dbdash.util.uuid).
local uuid = require("dbdash.util.uuid")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["format: version 7, variant 10, 36 characters"] = function()
  for _ = 1, 200 do
    local id = uuid.v7()
    eq({ id, #id }, { id, 36 })
    eq(id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-7%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil, true)
  end
end

T["unique and increasing, also many in one millisecond"] = function()
  local seen, prev = {}, ""
  for _ = 1, 10000 do
    local id = uuid.v7()
    eq(seen[id], nil)
    seen[id] = true
    eq(id > prev, true)
    prev = id
  end
end

---The 48-bit timestamp of an id. Parsed in two parts: tonumber(s, 16) stops at 2^32 - 1
---on Windows' LuaJIT.
local function ms_of(id)
  return tonumber(id:sub(1, 8), 16) * 65536 + tonumber(id:sub(10, 13), 16)
end

T["the first 48 bits are the time in milliseconds"] = function()
  -- A burst of ids (the case above) borrows the next milliseconds once a millisecond's
  -- counter runs out, more so with a coarse clock (Windows): wait until the clock is past
  -- the ids made so far.
  local last = ms_of(uuid.v7())
  vim.wait(5000, function()
    return uuid.now_ms() > last
  end, 1)
  local before = uuid.now_ms()
  local id = uuid.v7()
  local after = uuid.now_ms()
  local ms = ms_of(id)
  -- (a burst within one millisecond may borrow the next one)
  eq(ms >= before and ms <= after + 1, true)
  eq(math.abs(uuid.now_ms() - os.time() * 1000) < 2000, true)
end

T["no random source is read"] = function()
  local real_open = io.open
  io.open = function()
    error("io.open called")
  end
  local ok, id = pcall(uuid.v7)
  io.open = real_open
  eq({ ok, type(id) }, { true, "string" })
end

T["math.random is left alone"] = function()
  math.randomseed(42)
  local a = math.random()
  math.randomseed(42)
  uuid.v7()
  eq(math.random(), a)
end

return T
