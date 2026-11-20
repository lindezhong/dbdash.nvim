-- JSON decoding for driver values: objects become ordered mappings (keys sorted, since
-- vim.json does not keep their order), arrays stay lists, null is db.NULL.
local map = require("dbdash.util.map")

local M = {}

local EMPTY_DICT_MT = getmetatable(vim.empty_dict())

local function convert(v)
  if type(v) ~= "table" or v == vim.NIL then
    return v
  end
  if getmetatable(v) ~= EMPTY_DICT_MT and vim.islist(v) then
    local out = {}
    for i, x in ipairs(v) do
      out[i] = convert(x)
    end
    return out
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys)
  local m = map.new()
  for _, k in ipairs(keys) do
    map.set(m, k, convert(v[k]))
  end
  return m
end

---Decode JSON text; returns the original string when it is not valid JSON.
function M.decode(s)
  local ok, v = pcall(vim.json.decode, s, { luanil = { object = false, array = false } })
  if not ok then
    return s
  end
  return convert(v)
end

return M
