-- Template files for {% import %} / {% from %} (design §6.2): paths are relative to the
-- config file's directory; compiled templates are cached by path and modification time.
local M = {}

local cache = {} ---@type table<string, { mtime: integer, tpl: table }>

local function fail(msg, ...)
  error(require("dbdash.template.errors").new("value", msg:format(...)), 0)
end

---Loader function for env.load_template.
---@param base_dir string
---@return fun(name: string): table, string compiled template and its path
function M.files(base_dir)
  return function(name)
    local path = vim.fs.normalize(name:sub(1, 1) == "/" and name or vim.fs.joinpath(base_dir, name))
    local stat = vim.uv.fs_stat(path)
    if not stat then
      fail("template not found: %s", path)
    end
    local mtime = stat.mtime.sec * 1e9 + stat.mtime.nsec
    local c = cache[path]
    if c and c.mtime == mtime then
      return c.tpl, path
    end
    local f = assert(io.open(path, "rb"))
    local src = f:read("*a")
    f:close()
    local tpl = require("dbdash.template").compile(src)
    cache[path] = { mtime = mtime, tpl = tpl }
    return tpl, path
  end
end

---Loader over an in-memory table (tests).
---@param files table<string, string>
function M.dict(files)
  return function(name)
    local src = files[name]
    if not src then
      fail("template not found: %s", name)
    end
    return require("dbdash.template").compile(src), name
  end
end

return M
