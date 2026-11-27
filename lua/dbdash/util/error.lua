-- The error object of dbdash and its text (:help dbdash-errors).
local M = {}

---@alias dbdash.Phase
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
---| "template"
---| "args"
---| "render"

---@class dbdash.Error every error of dbdash: what failed (phase) and why
---@field phase dbdash.Phase
---@field message string
---@field driver string? the database driver it came from
---@field code string? server error code (e.g. SQLSTATE)
---@field detail string? more lines (shown under it)
---@field position integer? 1-based character position in the query (pg)
---@field kind string? a template error's kind ("syntax", "undefined", "type", "value"...)
---@field source string? the file of a template or Lua code
---@field line integer? its line
---@field col integer? its column (template syntax errors)
---@field not_found boolean? a template that does not exist ({% include ... ignore missing %})
---@field tls_closed boolean? the peer closed the connection during the TLS handshake

local Error = {}
Error.__index = Error
---The text of every error: "[<driver> ]<phase> error: [<source>:<line>: ]<message>", the
---server's code in brackets, the detail on the next lines.
Error.__tostring = function(e)
  local where = ""
  if e.line and e.phase == "template" then
    where = ("%s:%d: "):format(e.source or "template", e.line)
  end
  local s = ("%s%s error: %s%s"):format(
    e.driver and (e.driver .. " ") or "",
    e.phase,
    where,
    e.message
  )
  if e.code then
    s = s .. " [" .. e.code .. "]"
  end
  if e.detail then
    s = s .. "\n" .. e.detail
  end
  return s
end
M.Error = Error

---@param fields table
---@return dbdash.Error
function M.new(fields)
  assert(fields.phase and fields.message, "an error needs a phase and a message")
  return setmetatable(fields, Error)
end

function M.is(e)
  return getmetatable(e) == Error
end

---Raise an error. It never returns: `x or raise(...)` and `return raise(...)` keep the
---types of their code.
---@param phase dbdash.Phase
---@param message string
---@param extra table? additional fields (code, detail, position, driver)
---@return any
function M.raise(phase, message, extra)
  local e = extra or {}
  e.phase, e.message = phase, message
  error(M.new(e), 0)
end

---Anything raised as an error (an error table, a string from Lua) as an Error.
---@param err any
---@param driver string?
---@return dbdash.Error
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

---The text of an error (Error.__tostring); a cancelled one is its message ("query
---cancelled: <reason>").
---@param err any
---@return string
function M.format(err)
  if type(err) ~= "table" then
    return tostring(err)
  end
  if err.phase == "cancelled" then
    return err.message
  end
  if M.is(err) then
    return tostring(err)
  end
  return tostring(
    M.new(
      vim.tbl_extend(
        "force",
        {},
        err,
        { phase = err.phase or "internal", message = err.message or vim.inspect(err) }
      )
    )
  )
end

return M
