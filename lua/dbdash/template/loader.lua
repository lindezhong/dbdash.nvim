-- Files for {% import %} / {% from %} (design §6.2): paths are relative to the config
-- file's directory. Templates are compiled and cached by path and modification time;
-- *.lua files are Lua modules, returned as { lua = true } and run by the runtime.
local M = {}

local cache = {} ---@type table<string, { mtime: integer, tpl: table }>

local function fail(msg, ...)
  error(require("dbdash.template.errors").new("value", msg:format(...)), 0)
end

---Loader function for env.load_template.
---@param base_dir string
---@return fun(name: string): table, string, string compiled template (or { lua = true }), its path and its text
function M.files(base_dir)
  return function(name)
    local absolute = name:sub(1, 1) == "/" or name:match("^%a:[/\\]")
    local path = vim.fs.normalize(absolute and name or vim.fs.joinpath(base_dir, name))
    local stat = vim.uv.fs_stat(path)
    if not stat then
      fail("template not found: %s", path)
    end
    local mtime = stat.mtime.sec * 1e9 + stat.mtime.nsec
    local c = cache[path]
    if c and c.mtime == mtime then
      return c.tpl, path, c.src
    end
    local f = assert(io.open(path, "rb"))
    local src = f:read("*a")
    f:close()
    local tpl = path:match("%.lua$") and { lua = true } or require("dbdash.template").compile(src)
    cache[path] = { mtime = mtime, tpl = tpl, src = src }
    return tpl, path, src
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
    if name:match("%.lua$") then
      return { lua = true }, name, src
    end
    return require("dbdash.template").compile(src), name, src
  end
end

return M
