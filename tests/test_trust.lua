-- Configs with Lua code (lua:// or query.transform) run only when trusted.
local sched = require("dbdash.scheduler")
local trust = require("dbdash.trust")
local dbdash = require("dbdash")
local eq = MiniTest.expect.equality

local dir, notes, asked, answer
local real_ask = trust.ask
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      notes, asked, answer = {}, 0, "cancel"
      vim.notify = function(msg)
        notes[#notes + 1] = msg
      end
      trust.ask = function()
        asked = asked + 1
        return answer
      end
    end,
    post_case = function()
      vim.notify = vim.api.nvim_notify
      trust.ask = real_ask
      dbdash.setup({})
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      vim.cmd("silent! only")
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
  local ok = sched.get(sched.normalize(path)) ~= nil
  if ok then
    sched.stop(sched.normalize(path))
  end
  return ok
end

T["configs without Lua never ask"] = function()
  eq(started(write("plain", PLAIN)), true)
  eq(asked, 0)
end

T["Allow runs it and is remembered until the file changes"] = function()
  for name, lines in pairs({ lua = LUA, transform = TRANSFORM }) do
    local path = write(name, lines)
    answer = "allow"
    eq({ name, started(path) }, { name, true })
    eq(trust.state(path), "allowed") -- recorded in Neovim's trust database
    answer = "cancel"
    eq({ name, started(path) }, { name, true }) -- not asked again
  end
  eq(asked, 2)
  -- an edit changes the content hash: asked again
  local path = dir .. "/lua.yaml"
  vim.fn.writefile(vim.list_extend(vim.deepcopy(LUA), { "# edited" }), path)
  eq(trust.state(path), "unknown")
  eq(started(path), false)
  eq(asked, 3)
  eq(notes[#notes]:find("lua.yaml runs Lua code and is not trusted: not trusted yet", 1, true) ~= nil, true)
end

T["Deny is remembered; View opens the file; Not now asks again"] = function()
  local path = write("lua", LUA)
  answer = "view"
  eq(started(path), false)
  eq(vim.fn.expand("%:t"), "lua.yaml") -- opened for review
  eq(notes[#notes]:find("review it, then start it again", 1, true) ~= nil, true)
  answer = "cancel"
  eq(started(path), false)
  answer = "deny"
  eq(started(path), false)
  eq(trust.state(path), "denied")
  eq(started(path), false)
  eq(asked, 3) -- a denied file is not asked about again
  eq(notes[#notes]:find("denied earlier (:trust to allow it)", 1, true) ~= nil, true)
end

T[":trust decisions count (shared trust database)"] = function()
  local path = write("lua", LUA)
  vim.secure.trust({ action = "allow", path = path })
  eq(started(path), true)
  vim.secure.trust({ action = "deny", path = path })
  eq(started(path), false)
  eq(asked, 0)
end

T["confirm = false and trusted_dirs skip the question"] = function()
  local path = write("lua", LUA)
  vim.secure.trust({ action = "deny", path = path })
  dbdash.setup({ lua = { confirm = false } })
  eq(started(path), true)
  dbdash.setup({ lua = { trusted_dirs = { dir } } })
  eq(started(path), true)
  dbdash.setup({ lua = { trusted_dirs = { dir .. "-other" } } }) -- a prefix is not enough
  eq(started(path), false)
  eq(asked, 0) -- denied earlier: not asked
end

return T
