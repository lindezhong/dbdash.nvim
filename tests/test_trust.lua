-- Configs that run Lua are trusted per config: one question covers the config and every
-- .lua file / {% lua %} template it imports; a change to any of them asks again.
local sched = require("dbdash.scheduler")
local trust = require("dbdash.trust")
local dbdash = require("dbdash")
local eq = MiniTest.expect.equality
local real_notify = vim.notify -- restored after each case (nvim_notify needs 3 arguments)

local dir, notes, levels, asked, asked_files, answer
local real_ask = trust.ask
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      os.remove(trust.file())
      notes, levels, asked, asked_files, answer = {}, {}, 0, nil, "cancel"
      vim.notify = function(msg, level)
        notes[#notes + 1] = msg
        levels[#levels + 1] = level
      end
      trust.ask = function(_, files)
        asked = asked + 1
        asked_files = vim.tbl_map(function(f)
          return vim.fs.basename(f.path) .. ":" .. f.kind
        end, files)
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
      os.remove(trust.file())
    end,
  },
})

local function write(name, lines)
  local path = dir .. "/" .. name
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
---A SQL config importing a .lua module (and a template that imports nothing with Lua).
local function importing(lua_file)
  return {
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  sql: |",
    ("    {%% import '%s' as h %%}"):format(lua_file),
    "    {% from 'plain.sql' import m %}",
    "    SELECT 1 AS x",
  }
end

local function started(path)
  sched.start(path, { no_show = true })
  local ok = sched.get(sched.normalize(path)) ~= nil
  if ok then
    sched.stop(sched.normalize(path))
  end
  return ok
end

T["configs without Lua never ask"] = function()
  write("plain.sql", { "{% macro m() %}1{% endmacro %}" })
  eq(started(write("plain.yaml", PLAIN)), true)
  eq(started(write("sql_import.yaml", { "database: { url: 'sqlite:///:memory:' }", "query:", "  sql: \"{% from 'plain.sql' import m %}SELECT {{ m() }}\"" })), true)
  eq(asked, 0)
end

T["collect: the config first, then imported .lua files and {% lua %} templates"] = function()
  write("helpers.lua", { "return {}" })
  write("plain.sql", { "{% macro m() %}1{% endmacro %}" })
  write("deep.lua", { "return {}" })
  write("with_lua.sql", { "{% import 'deep.lua' as d %}{% lua %}return 1{% endlua %}" })
  local path = write("board.yaml", {
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  sql: |",
    "    {% import 'helpers.lua' as h %}{% from \"with_lua.sql\" import x %}{% import 'plain.sql' as p %}",
    "    SELECT 1",
  })
  local files, has_lua = trust.collect(path, require("dbdash.config").load(path))
  eq(has_lua, true)
  eq(vim.tbl_map(function(f)
    return vim.fs.basename(f.path) .. ":" .. f.kind
  end, files), { "board.yaml:config", "deep.lua:lua", "helpers.lua:lua", "with_lua.sql:template" })
  -- a {% lua %} block in the config itself
  path = write("block.yaml", PLAIN)
  vim.fn.writefile({ "database: { url: 'sqlite:///:memory:' }", "query: { sql: '{% lua %}return 1{% endlua %}' }" }, path)
  files, has_lua = trust.collect(path, require("dbdash.config").load(path))
  eq({ #files, has_lua }, { 1, true })
end

T["one question per config, listing every file; allowed until any of them changes"] = function()
  write("helpers.lua", { "return {}" })
  write("plain.sql", { "{% macro m() %}1{% endmacro %}" })
  local path = write("board.yaml", importing("helpers.lua"))
  answer = "allow"
  eq(started(path), true)
  eq(asked_files, { "board.yaml:config", "helpers.lua:lua" })
  answer = "cancel"
  eq(started(path), true) -- not asked again
  eq(asked, 1)
  -- the imported file changes: asked again
  write("helpers.lua", { "return { changed = true }" })
  eq(started(path), false)
  eq(asked, 2)
  eq(notes[#notes]:find("board.yaml not started (not trusted yet)", 1, true) ~= nil, true)
  eq(levels[#levels], vim.log.levels.INFO)
  answer = "allow"
  eq(started(path), true)
  -- the config changes: asked again
  vim.fn.writefile(vim.list_extend(importing("helpers.lua"), { "# edited" }), path)
  answer = "cancel"
  eq(started(path), false)
  eq(asked, 4)
end

T["two configs sharing a .lua file are asked about separately"] = function()
  write("helpers.lua", { "return {}" })
  write("plain.sql", { "{% macro m() %}1{% endmacro %}" })
  local a = write("a.yaml", importing("helpers.lua"))
  local b = write("b.yaml", importing("helpers.lua"))
  answer = "allow"
  eq(started(a), true)
  eq(started(b), true)
  eq(asked, 2)
  eq({ trust.state(a, trust.collect(a, require("dbdash.config").load(a))) }, { "allowed" })
end

T["Deny is remembered; :DbDashTrust allow / remove decide without the question"] = function()
  local path = write("lua.yaml", LUA)
  answer = "deny"
  eq(started(path), false)
  eq(started(path), false)
  eq(asked, 1) -- a denied config is not asked about again
  eq(notes[#notes]:find("lua.yaml was denied (:DbDashTrust allow", 1, true) ~= nil, true)
  eq(levels[#levels], vim.log.levels.WARN)
  require("dbdash.commands").trust({ "allow", path }) -- :DbDashTrust allow <path>
  eq(started(path), true)
  eq(asked, 1)
  require("dbdash.commands").trust({ "remove", path })
  answer = "cancel"
  eq(started(path), false)
  eq(asked, 2)
  require("dbdash.commands").trust({ "deny", path })
  eq(started(path), false)
  eq(asked, 2)
end

---Choose View, then press `key` in the float; returns what the float showed.
local function view_then(path, key)
  answer = "view"
  local before = #vim.api.nvim_list_wins()
  sched.start(path, { no_show = true })
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_get_namespaces().dbdash_trust
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local shown = {
    floating = vim.api.nvim_win_get_config(win).relative ~= "",
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    title = vim.api.nvim_win_get_config(win).title,
    separators = vim.tbl_map(function(m)
      return { m[2], m[4].line_hl_group }
    end, marks),
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

T["View shows every file after a separator naming it; a allows and starts"] = function()
  write("helpers.lua", { "return {}", "-- helper" })
  write("plain.sql", { "{% macro m() %}1{% endmacro %}" })
  local path = write("board.yaml", importing("helpers.lua"))
  local shown = view_then(path, "a")
  eq(shown.floating, true)
  eq(vim.inspect(shown.title):find("a allow, d deny, q close", 1, true) ~= nil, true)
  local l = shown.lines
  local function separator(line, label)
    return vim.startswith(line, "━━━━ ") and line:find(label, 1, true) ~= nil and vim.endswith(line, "━")
  end
  eq(separator(l[1], "board.yaml (config) "), true)
  eq(vim.list_slice(l, 2, 7), importing("helpers.lua"))
  eq(l[8], "")
  eq(separator(l[9], "helpers.lua (Lua) "), true)
  eq(vim.list_slice(l, 10, 11), { "return {}", "-- helper" })
  eq(shown.separators, { { 0, "DbDashTrustFile" }, { 8, "DbDashTrustFile" } })
  eq(trust.state(path, trust.collect(path, require("dbdash.config").load(path))), "allowed")
  eq(sched.get(sched.normalize(path)) ~= nil, true) -- started after allowing
  eq(asked, 1)
end

T["View: d denies, q closes without deciding (no split window either way)"] = function()
  local path = write("lua.yaml", LUA)
  local wins = #vim.api.nvim_list_wins()
  view_then(path, "d")
  eq(trust.state(path, trust.collect(path, require("dbdash.config").load(path))), "denied")
  eq(sched.get(sched.normalize(path)), nil)
  eq(levels[#levels], vim.log.levels.WARN)
  eq(#vim.api.nvim_list_wins(), wins)
  local other = write("other.yaml", TRANSFORM)
  view_then(other, "q")
  eq(trust.state(other, trust.collect(other, require("dbdash.config").load(other))), "unknown")
  eq(sched.get(sched.normalize(other)), nil)
  eq(notes[#notes]:find("other.yaml not started (not trusted yet)", 1, true) ~= nil, true)
  eq(levels[#levels], vim.log.levels.INFO)
  eq(#vim.api.nvim_list_wins(), wins)
end

T["confirm = false and trusted_dirs skip the question"] = function()
  local path = write("lua.yaml", LUA)
  trust.record(path, "deny")
  dbdash.setup({ lua = { confirm = false } })
  eq(started(path), true)
  dbdash.setup({ lua = { trusted_dirs = { dir } } })
  eq(started(path), true)
  dbdash.setup({ lua = { trusted_dirs = { dir .. "-other" } } }) -- a prefix is not enough
  eq(started(path), false)
  eq(asked, 0) -- denied earlier: not asked
end

return T
