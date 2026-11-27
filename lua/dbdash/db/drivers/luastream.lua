-- luastream:// push source: query.sql is Lua code (after the template), like lua://, whose
-- output is the data: print() and io.write() text is cut into items at the delimiter, and
-- dbdash.emit(value) passes one item as it is (:help dbdash-luastream). It ends when the
-- code returns (a value it returns is the last item).
--
-- database.options.cwd is the code's directory: Lua runs inside Neovim, so instead of
-- changing the process's directory, io.open / io.lines / dofile / loadfile resolve relative
-- paths there and io.popen / os.execute / dbdash.system() run commands there.
local options = require("dbdash.db.push.options")

local M = {
  name = "luastream",
  schemes = { "luastream" },
  capabilities = { tls = false, sql = false, query_language = "lua" },
}

local SPEC = { cwd = "string", delimiter = options.delimiter }

local function absolute(p)
  return p:sub(1, 1) == "/" or p:match("^%a:[/\\]") ~= nil
end

---Shell prefix that runs a command in `dir`.
local function in_dir(dir, cmd)
  if jit.os == "Windows" then
    return ('cd /d "%s" && %s'):format(dir, cmd)
  end
  return ("cd '%s' && %s"):format(dir:gsub("'", [['\'']]), cmd)
end

---The globals that make `cwd` the code's directory, and print / io.write into `write`.
function M.globals(cwd, write)
  local function resolve(p)
    if type(p) == "string" and not absolute(p) then
      return vim.fs.joinpath(cwd, p)
    end
    return p
  end
  local io_proxy
  io_proxy = setmetatable({
    write = function(...)
      for i = 1, select("#", ...) do
        write(tostring((select(i, ...))))
      end
      return io_proxy
    end,
    open = function(p, mode)
      return io.open(resolve(p), mode)
    end,
    lines = function(p, ...)
      if p == nil then
        return io.lines()
      end
      return io.lines(resolve(p), ...)
    end,
    popen = function(cmd, mode)
      return io.popen(in_dir(cwd, cmd), mode)
    end,
  }, { __index = io })
  local os_proxy = setmetatable({
    execute = function(cmd)
      if cmd == nil then
        return os.execute()
      end
      return os.execute(in_dir(cwd, cmd))
    end,
  }, { __index = os })
  return {
    io = io_proxy,
    os = os_proxy,
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
      end
      write(table.concat(parts, "\t") .. "\n")
    end,
    dofile = function(p)
      return dofile(resolve(p))
    end,
    loadfile = function(p, ...)
      return loadfile(resolve(p), ...)
    end,
  }
end

---@param ctx dbdash.db.StreamCtx
function M.produce(info, code, ctx)
  local o = options.check("luastream", info.options, SPEC, { delimiter = "\n" })
  local cwd = options.dir("luastream", o.cwd, ctx.base_dir)
  local write = ctx.writer(o.delimiter, {})
  local lua_env = require("dbdash.db.lua_env")
  local g = ctx.lua or {}
  local base = g.helpers or lua_env.helpers
  local helpers = setmetatable({
    emit = function(value)
      ctx.emit(value)
    end,
    cwd = cwd,
    system = function(cmd, opts)
      return base.system(cmd, vim.tbl_extend("keep", opts or {}, { cwd = cwd }))
    end,
  }, { __index = base })
  local value = lua_env.run(code, {
    phase = "query",
    source = ctx.source,
    line = ctx.line,
    args = ctx.args,
    meta = ctx.meta,
    lua = { store = g.store, helpers = helpers, after = g.after },
    vars = M.globals(cwd, write),
    cancel = ctx.cancel, -- no timeout: it runs until it returns or is stopped,
    slice = ctx.timeout, -- but a stretch without waiting longer than the query timeout stops
  })
  if value ~= nil then
    ctx.emit(value)
  end
end

return M
