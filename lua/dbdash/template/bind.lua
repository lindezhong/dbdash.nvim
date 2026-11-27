-- Arguments of filters, tests, methods and globals bound to a Python-like signature.
local R = require("dbdash.template.runtime")
local raise = require("dbdash.template.errors").raise

---Bind positional and keyword arguments to a Python-like signature.
---@param fname string
---@param args any[]
---@param kwargs table<string, any>
---@param params { [1]: string, [2]: any }[] name and default (nil = required)
---@return any ...
local M = {}

function M.bind(fname, args, kwargs, params)
  local out = {}
  if #args > #params then
    raise("type", "%s() takes at most %d arguments (%d given)", fname, #params, #args)
  end
  for i, p in ipairs(params) do
    local v = args[i]
    local kv = kwargs[p[1]]
    if v ~= nil and kv ~= nil then
      raise("type", "%s() got multiple values for argument '%s'", fname, p[1])
    end
    if v == nil then
      v = kv
    end
    if v == nil then
      v = p[2]
    end
    out[i] = R.check(v)
  end
  for k in pairs(kwargs) do
    local known = false
    for _, p in ipairs(params) do
      known = known or p[1] == k
    end
    if not known then
      raise("type", "%s() got an unexpected keyword argument '%s'", fname, k)
    end
  end
  return unpack(out, 1, #params)
end

return M
