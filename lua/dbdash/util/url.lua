-- Percent-encoding of URL components.
local M = {}

---Percent-encode everything but unreserved characters (RFC 3986): a query component, a
---form value (application/x-www-form-urlencoded style), curl --data-urlencode.
---@param s any
---@return string
function M.encode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

---Percent-decode ("+" is kept literally).
---@param s string
---@return string
function M.decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

return M
