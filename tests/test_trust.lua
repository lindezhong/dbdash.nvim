-- Configs with Lua code (lua:// or query.transform) run only when trusted.
local sched = require("dbdash.scheduler")
local trust = require("dbdash.trust")
local dbdash = require("dbdash")
local eq = MiniTest.expect.equality
local real_notify = vim.notify -- restored after each case (nvim_notify needs 3 arguments)

local dir, notes, levels, asked, answer
local real_ask = trust.ask
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      notes, levels, asked, answer = {}, {}, 0, "cancel"
      vim.notify = function(msg, level)
        notes[#notes + 1] = msg
        levels[#levels + 1] = level
      end
      trust.ask = function()
        asked = asked + 1
        return answer
      end
    end,
    post_case = function()
      vim.notify = real_notify
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
  eq(notes[#notes]:find("lua.yaml not started (not trusted yet)", 1, true) ~= nil, true)
  eq(levels[#levels], vim.log.levels.INFO) -- "Not now" is not an error
end

T["Deny is remembered; Not now asks again"] = function()
  local path = write("lua", LUA)
  answer = "cancel"
  eq(started(path), false)
  eq(levels[#levels], vim.log.levels.INFO)
  answer = "deny"
  eq(started(path), false)
  eq(trust.state(path), "denied")
  eq(started(path), false)
  eq(asked, 2) -- a denied file is not asked about again
  eq(notes[#notes]:find("lua.yaml was denied (:trust", 1, true) ~= nil, true)
  eq(levels[#levels], vim.log.levels.WARN)
end

---Choose View, then press `key` in the float; returns what the float showed.
local function view_then(path, key)
  answer = "view"
  local before = #vim.api.nvim_list_wins()
  sched.start(path, { no_show = true })
  local win = vim.api.nvim_get_current_win()
  local shown = {
    floating = vim.api.nvim_win_get_config(win).relative ~= "",
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
    filetype = vim.bo.filetype,
    title = vim.api.nvim_win_get_config(win).title,
  }
  vim.api.nvim_feedkeys(vim.keycode(key), "xt", false)
  vim.wait(1000, function()
    return #vim.api.nvim_list_wins() == before
  end, 5)
  vim.wait(50, function()
    return false
  end) -- let the scheduled decision run
  return shown
end

T["View shows the config in a float; a allows and starts it"] = function()
  local path = write("lua", LUA)
  local shown = view_then(path, "a")
  eq({ shown.floating, shown.lines, shown.filetype }, { true, LUA, "yaml" })
  eq(vim.inspect(shown.title):find("a allow, d deny, q close", 1, true) ~= nil, true)
  eq(trust.state(path), "allowed")
  eq(sched.get(sched.normalize(path)) ~= nil, true) -- started after allowing
  eq(asked, 1)
end

T["View: d denies, q closes without deciding (no split window either way)"] = function()
  local path = write("lua", LUA)
  local wins = #vim.api.nvim_list_wins()
  view_then(path, "d")
  eq(trust.state(path), "denied")
  eq(sched.get(sched.normalize(path)), nil)
  eq(levels[#levels], vim.log.levels.WARN)
  eq(#vim.api.nvim_list_wins(), wins)
  local other = write("other", LUA)
  view_then(other, "q")
  eq(trust.state(other), "unknown")
  eq(sched.get(sched.normalize(other)), nil)
  eq(notes[#notes]:find("other.yaml not started (not trusted yet)", 1, true) ~= nil, true)
  eq(levels[#levels], vim.log.levels.INFO)
  eq(#vim.api.nvim_list_wins(), wins)
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
