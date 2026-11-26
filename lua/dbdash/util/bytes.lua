-- Byte sizes in options: a number of bytes, or "512", "64KB", "10MB", "1GB" (K, M, G are
-- powers of 1024; "KiB" and "KB" mean the same).
local M = {}

local UNITS = { [""] = 1, b = 1, k = 1024, kb = 1024, kib = 1024, m = 1024 ^ 2, mb = 1024 ^ 2, mib = 1024 ^ 2, g = 1024 ^ 3, gb = 1024 ^ 3, gib = 1024 ^ 3 }

---Bytes of a size, or nil and an error message.
---@param v any
---@return integer?, string?
function M.parse(v)
  if type(v) == "number" and v >= 1 and v == math.floor(v) then
    return v
  end
  if type(v) == "string" then
    local n, unit = vim.trim(v):match("^(%d+%.?%d*)%s*(%a*)$")
    local mult = unit and UNITS[unit:lower()]
    if n and mult and tonumber(n) * mult >= 1 then
      return math.floor(tonumber(n) * mult)
    end
  end
  return nil, ("invalid size %s (use bytes or a size like \"10MB\")"):format(vim.inspect(v))
end

---Check a size option: an error message for invalid values.
function M.check(v)
  local _, err = M.parse(v)
  return err
end

return M
