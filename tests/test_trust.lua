-- Configs with Lua code (lua:// or query.transform) run only when trusted.
local sched = require("dbdash.scheduler")
local dbdash = require("dbdash")
local eq = MiniTest.expect.equality

local dir, notes, read_calls
local real_read = vim.secure.read
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      notes, read_calls = {}, 0
      vim.notify = function(msg)
        notes[#notes + 1] = msg
      end
      vim.secure.read = function(path)
        read_calls = read_calls + 1
        return real_read(path)
      end
    end,
    post_case = function()
      vim.notify = vim.api.nvim_notify
      vim.secure.read = real_read
      dbdash.setup({})
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
    end,
  },
})

local function write(name, lines)
  local path = dir .. "/" .. name .. ".yaml"
  vim.fn.writefile(lines, path)
  return path
end

local LUA = { "database: { url: 'lua://' }", "query: { sql: 'return { { x = 1 } }' }" }
local TRANSFORM = {
  "database: { url: 'sqlite:///:memory:' }",
  "query:",
  "  sql: SELECT 1 AS x",
  "  transform: 'return rs'",
}
local PLAIN = { "database: { url: 'sqlite:///:memory:' }", "query: { sql: SELECT 1 AS x }" }

local function started(path)
  sched.start(path, { no_show = true })
  return sched.get(sched.normalize(path)) ~= nil
end

T["configs without Lua never ask"] = function()
  eq(started(write("plain", PLAIN)), true)
  eq(read_calls, 0)
end

T["denied configs with Lua do not start"] = function()
  for name, lines in pairs({ lua = LUA, transform = TRANSFORM }) do
    local path = write(name, lines)
    vim.secure.trust({ action = "deny", path = path })
    eq({ name, started(path) }, { name, false })
    eq(notes[#notes]:find(name .. ".yaml runs Lua code and is not trusted", 1, true) ~= nil, true)
  end
  eq(read_calls, 2)
end

T["allowed configs run; a change asks again"] = function()
  local path = write("lua", LUA)
  vim.secure.trust({ action = "allow", path = path })
  eq(started(path), true)
  sched.stop(sched.normalize(path))
  -- the trust is for the content: after an edit the file is no longer trusted
  vim.fn.writefile(vim.list_extend(vim.deepcopy(LUA), { "# edited" }), path)
  vim.secure.read = function()
    read_calls = read_calls + 1
    return nil -- the user answers "deny" to the new prompt
  end
  eq(started(path), false)
end

T["confirm = false and trusted_dirs skip the question"] = function()
  local path = write("lua", LUA)
  vim.secure.trust({ action = "deny", path = path })
  dbdash.setup({ lua = { confirm = false } })
  eq(started(path), true)
  sched.stop(sched.normalize(path))
  dbdash.setup({ lua = { trusted_dirs = { dir } } })
  eq(started(path), true)
  sched.stop(sched.normalize(path))
  dbdash.setup({ lua = { trusted_dirs = { dir .. "-other" } } }) -- a prefix is not enough
  eq(started(path), false)
  eq(read_calls, 1)
end

return T
