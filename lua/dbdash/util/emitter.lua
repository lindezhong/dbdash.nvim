-- Event emitters: on(type, fn) / off(type, fn) / emit(type, ...). Listeners run at once, in
-- the order they were added, on the caller's stack (the main loop for dashboards).
local M = {}

---@class dbdash.Emitter
---@field listeners table<string, function[]>
local Emitter = {}
Emitter.__index = Emitter

---@return dbdash.Emitter
function M.new()
  return setmetatable({ listeners = {} }, Emitter)
end

---Listen to `type`; returns `fn` (to give to off()).
---@param type string
---@param fn function
---@return function
function Emitter:on(type, fn)
  local list = self.listeners[type] or {}
  self.listeners[type] = list
  list[#list + 1] = fn
  return fn
end

---@param type string
---@param fn function
function Emitter:off(type, fn)
  local list = self.listeners[type] or {}
  for i = #list, 1, -1 do
    if list[i] == fn then
      table.remove(list, i)
    end
  end
end

---Call the listeners of `type` with the arguments; a failing listener does not stop the
---others (its error is reported).
---@param type string
function Emitter:emit(type, ...)
  for _, fn in ipairs(vim.list_slice(self.listeners[type] or {})) do
    local ok, err = pcall(fn, ...)
    if not ok then
      vim.notify(
        ("dbdash: %s listener failed: %s"):format(type, tostring(err)),
        vim.log.levels.ERROR
      )
    end
  end
end

return M
