-- Uniform database error object (design §8.9).
local M = {}

---@alias dbdash.db.Phase
---| "connect"
---| "tls"
---| "auth"
---| "query"
---| "decode"
---| "timeout"
---| "cancelled"
---| "config"
---| "internal"
---| "transform"

---@class dbdash.db.DbError
---@field driver string?
---@field phase dbdash.db.Phase
---@field code string? server error code (e.g. SQLSTATE)
---@field message string
---@field detail string?
---@field position integer? 1-based character position in the query (pg)

local DbError = {}
DbError.__index = DbError
DbError.__tostring = function(e)
  local s = ("%s%s error: %s"):format(e.driver and (e.driver .. " ") or "", e.phase, e.message)
  if e.code then
    s = s .. " [" .. e.code .. "]"
  end
  if e.detail then
    s = s .. "\n" .. e.detail
  end
  return s
end
M.DbError = DbError

---@param fields table
---@return dbdash.db.DbError
function M.new(fields)
  assert(fields.phase and fields.message, "DbError needs phase and message")
  return setmetatable(fields, DbError)
end

function M.is(e)
  return getmetatable(e) == DbError
end

---Raise a DbError.
---@param phase dbdash.db.Phase
---@param message string
---@param extra table? additional fields (code, detail, position, driver)
function M.raise(phase, message, extra)
  local e = extra or {}
  e.phase, e.message = phase, message
  error(M.new(e), 0)
end

---Convert anything raised inside a driver into a DbError.
---@param err any
---@param driver string?
---@return dbdash.db.DbError
function M.wrap(err, driver)
  if M.is(err) then
    err.driver = err.driver or driver
    return err
  end
  if type(err) == "table" and err.phase and err.message then
    err.driver = err.driver or driver
    return M.new(err)
  end
  return M.new({ driver = driver, phase = "internal", message = tostring(err) })
end

---Human-readable error with its phase.
function M.format(err)
  if type(err) ~= "table" then
    return tostring(err)
  end
  if err.phase == "cancelled" then
    return err.message -- "query cancelled: <reason>"
  end
  local phase = err.phase or "error"
  local msg = getmetatable(err) and getmetatable(err).__tostring and tostring(err) or err.message
  if err.phase == "template" and err.message then
    msg = (err.source and (err.source .. ":") or "")
      .. (err.line and (err.line .. ": ") or "")
      .. err.message
  end
  if msg:find("^" .. vim.pesc(phase)) or msg:find("^%w+ " .. vim.pesc(phase)) then
    return msg
  end
  return ("[%s] %s"):format(phase, msg)
end

return M
