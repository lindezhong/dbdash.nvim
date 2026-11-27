-- Dates and times.
local M = {}

---Milliseconds since the epoch from an ISO-8601 date string (UTC or with offset); nil and
---a message when it is not one.
---@param s string
---@return number? ms, string? err
function M.iso_to_ms(s)
  local y, mo, d, h, mi, sec, frac, tz =
    s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ]?(%d?%d?):?(%d?%d?):?(%d?%d?)%.?(%d*)(.*)$")
  if not y then
    return nil, ("cannot parse date %q"):format(s)
  end
  local function days_from_civil(yy, mm, dd)
    yy = mm <= 2 and yy - 1 or yy
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local doy = math.floor((153 * (mm + (mm > 2 and -3 or 9)) + 2) / 5) + dd - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
  end
  local days = days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
  local secs = days * 86400
    + (tonumber(h) or 0) * 3600
    + (tonumber(mi) or 0) * 60
    + (tonumber(sec) or 0)
  local ms = secs * 1000 + (frac ~= "" and math.floor(tonumber("0." .. frac) * 1000 + 0.5) or 0)
  if tz ~= "" and tz ~= "Z" then
    local sign, th, tm = tz:match("^([+-])(%d%d):?(%d%d)$")
    if not sign then
      return nil, ("cannot parse time zone in %q"):format(s)
    end
    local off = (tonumber(th) * 60 + tonumber(tm)) * 60000
    ms = sign == "+" and ms - off or ms + off
  end
  return ms
end

return M
