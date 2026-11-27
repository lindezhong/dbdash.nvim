-- Cancellation tokens. A token is cancelled once, with a reason; the functions registered
-- with on_cancel() then run (at once when it is cancelled already). A query registers its
-- own cancel on the token given as opts.cancel (db.query), so one token stops everything a
-- refresh started: its query, the queries of its callbacks and Lua code that is running.
local M = {}

---@class dbdash.db.CancelToken
---@field cancelled boolean
---@field reason string? why it was cancelled
local Token = {}
Token.__index = Token

---A new token; cancelling `parent` cancels it too.
---@param parent dbdash.db.CancelToken?
---@return dbdash.db.CancelToken
function M.new(parent)
  local t = setmetatable({ cancelled = false, handlers = {} }, Token)
  if parent then
    t.unlink = parent:on_cancel(function(reason)
      t:cancel(reason)
    end)
  end
  return t
end

function M.is(v)
  return getmetatable(v) == Token
end

---Cancel: run the registered functions once (errors in them are ignored).
---@param reason string
function Token:cancel(reason)
  if self.cancelled then
    return
  end
  self.cancelled = true
  self.reason = reason or "cancelled"
  local handlers = self.handlers
  self.handlers = {}
  for _, fn in ipairs(handlers) do
    -- (pcall: a failing handler must not keep the others from running)
    pcall(fn, self.reason)
  end
end

---Run `fn(reason)` when the token is cancelled (now, if it is). Returns a function that
---unregisters it.
---@param fn fun(reason: string)
---@return fun()
function Token:on_cancel(fn)
  if self.cancelled then
    -- (pcall: a failing handler must not keep the others from running)
    pcall(fn, self.reason)
    return function() end
  end
  local handlers = self.handlers
  handlers[#handlers + 1] = fn
  return function()
    for i = #self.handlers, 1, -1 do
      if self.handlers[i] == fn then
        table.remove(self.handlers, i)
      end
    end
  end
end

---Stop listening to the parent (a token that is done).
function Token:release()
  if self.unlink then
    self.unlink()
    self.unlink = nil
  end
end

return M
