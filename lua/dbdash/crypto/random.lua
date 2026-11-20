-- Cryptographically secure random bytes: /dev/urandom, or BCryptGenRandom on Windows
-- (a system DLL, not an external dependency).
local M = {}

local ffi = require("ffi")

local win_ok, bcrypt
if jit.os == "Windows" then
  pcall(ffi.cdef, [[
    long BCryptGenRandom(void *hAlgorithm, unsigned char *pbBuffer, unsigned long cbBuffer, unsigned long dwFlags);
  ]])
  win_ok, bcrypt = pcall(ffi.load, "bcrypt")
end

---@param n integer
---@return string
function M.bytes(n)
  if n <= 0 then
    return ""
  end
  if jit.os == "Windows" then
    assert(win_ok, "BCryptGenRandom is not available")
    local buf = ffi.new("unsigned char[?]", n)
    local BCRYPT_USE_SYSTEM_PREFERRED_RNG = 0x00000002
    assert(bcrypt.BCryptGenRandom(nil, buf, n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0, "BCryptGenRandom failed")
    return ffi.string(buf, n)
  end
  local f = assert(io.open("/dev/urandom", "rb"))
  local s = f:read(n)
  f:close()
  assert(s and #s == n, "short read from /dev/urandom")
  return s
end

return M
