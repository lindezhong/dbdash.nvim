-- Ids for runs: UUID version 7 (RFC 9562) made in Lua, without reading a random source
-- (crypto/random reads /dev/urandom or calls BCryptGenRandom on every call). A private
-- xorshift generator, seeded once from the clocks and the process id, makes the random
-- bits, so scripts' math.random is left alone. Within one process ids are unique and
-- increase: the 12 bits after the version count up within a millisecond (RFC 9562
-- method 1).
local bit = require("bit")

local M = {}

---Milliseconds since the Unix epoch (an integer).
---@return integer
function M.now_ms()
  local sec, usec = vim.uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

local state

---A random 32-bit integer (xorshift32).
local function next32()
  local x = state
  x = bit.bxor(x, bit.lshift(x, 13))
  x = bit.bxor(x, bit.rshift(x, 17))
  x = bit.bxor(x, bit.lshift(x, 5))
  state = x
  return x
end

local function seed()
  local sec, usec = vim.uv.gettimeofday()
  local s = bit.bxor(
    bit.tobit(vim.uv.hrtime() % 4294967296),
    bit.tobit((vim.uv.os_getpid() * 2654435761) % 4294967296),
    bit.tobit((sec * 1000003 + usec) % 4294967296)
  )
  state = s ~= 0 and s or 0x9e3779b9
  for _ = 1, 8 do -- mix the seed
    next32()
  end
end
seed()

local last_ms, counter = -1, 0

---A new UUID v7, e.g. "019ab940-c621-7a3f-9c1e-5d2b8f40a7e6".
---@return string
function M.v7()
  local ms = M.now_ms()
  if ms > last_ms then
    last_ms = ms
    counter = bit.band(next32(), 0x7ff) -- leaves room to count up within this ms
  else
    -- The same millisecond (or the clock went back): count up; when the 12 bits run
    -- out, move to the next millisecond.
    counter = counter + 1
    if counter > 0xfff then
      last_ms = last_ms + 1
      counter = bit.band(next32(), 0x7ff)
    end
  end
  local ts = ("%012x"):format(last_ms)
  local r1, r2 = bit.tohex(next32(), 8), bit.tohex(next32(), 8)
  -- variant 10xx: the first hex digit of the fourth group is 8, 9, a or b
  local variant = ("%x"):format(8 + tonumber(r1:sub(1, 1), 16) % 4)
  return ("%s-%s-7%03x-%s%s-%s%s"):format(ts:sub(1, 8), ts:sub(9, 12), counter, variant, r1:sub(2, 4), r1:sub(5, 8), r2)
end

return M
