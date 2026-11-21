-- UI behavior from design §3, exercised in a child Neovim.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ROOT = vim.fn.getcwd()
local dir -- temp directory with configs, created per test

local CFG = [[
database:
  url: "sqlite:///:memory:"
query:
  sql: |
    SELECT {{ n }} AS n, '{{ label }}' AS label, {{ ids|sql_in|sql_quote }} AS ids_sql
  args_show: true
  args:
    - name: n
      type: int
      default: 1
    - name: label
      default: hello
      choices: [hello, world]
    - name: ids
      type: list
      default: [1, 2]
show:
  type: table
  title: Test board
  interval: 1h
  show_countdown: true
  countdown_format: "next {time}s"
]]

---Restart the child; a fresh temp directory with configs unless `keep_dir`.
local function setup_child(keep_dir)
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.o.columns = 160
  child.lua(([[
    vim.opt.runtimepath:prepend(%q)
    vim.cmd("runtime plugin/dbdash.lua")
    _G.notes = {}
    vim.notify = function(msg, level) table.insert(_G.notes, { msg = msg, level = level }) end
    _G.wait_for = function(fn) return vim.wait(5000, fn, 10) end
  ]]):format(ROOT))
  if keep_dir ~= true then
    -- Created by the test process: the child's own tempdir is removed when it exits.
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(CFG, "\n"), dir .. "/board.yaml")
    vim.fn.writefile({ "database:", "  url: sqlite:///:memory:", "query:", "  sql: SELEC oops" }, dir .. "/broken.yaml")
    vim.fn.writefile({ "type: object" }, dir .. "/board.schema.yaml") -- not a dashboard: hidden
  end
  child.cmd("cd " .. dir)
end

local function lines()
  return child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)")
end

local function wait_loaded()
  child.lua([[_G.wait_for(function()
    local l = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    return #l > 1 and table.concat(l, "\n"):find("Test board") ~= nil
  end)]])
end

local function find_line(pat)
  for _, l in ipairs(lines()) do
    if l:find(pat) then
      return l
    end
  end
end

local T = MiniTest.new_set({
  hooks = { pre_case = setup_child, post_once = child.stop },
})

T["commands and global mappings are registered"] = function()
  for _, c in ipairs({
    "DbDashStart", "DbDashRestart", "DbDashStop", "DbDashList", "DbDashStatus", "DbDash",
    "DbDashClose", "DbDashShowVariables", "DbDashModifyVariable", "DbDashUpdateVariable",
    "DbDashResetVariables", "DbDashShowSQL", "DbDashMksession", "Mksession",
  }) do
    eq({ c, child.fn.exists(":" .. c) }, { c, 2 })
  end
  eq(child.fn.maparg("<leader>dd", "n"), "<Cmd>DbDash<CR>")
  eq(child.fn.maparg("<leader>ds", "n"), ":DbDashStart ")
  child.lua("require('dbdash').setup({ mappings = false })")
  eq(child.fn.maparg("<leader>dd", "n"), "")
end

T["start shows a dashboard buffer"] = function()
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  eq(child.lua_get("vim.api.nvim_buf_get_name(0)"), "dbdash://" .. dir .. "/board.yaml")
  eq(child.lua_get("{ vim.bo.buftype, vim.bo.filetype, vim.bo.modifiable, vim.bo.swapfile }"), { "", "dbdash", false, false })
  child.cmd("write") -- nothing to write, no error
  eq(child.lua_get("vim.bo.modified"), false) -- never blocks :quit
  child.cmd("edit") -- reloading keeps the running dashboard
  eq({ child.lua_get("vim.bo.filetype"), child.lua_get("#require('dbdash.scheduler').list()") }, { "dbdash", 1 })
  eq(lines()[1], "n=1  label=hello  ids=1,2")
  eq(find_line("│%s+1 │ hello │ %(1, 2%)") ~= nil, true)
  for _, k in ipairs({ "a", "A", "r", "R", "s" }) do
    eq(child.lua_get("vim.fn.maparg(..., 'n', false, true).buffer", { k }), 1)
  end
  -- countdown is an extmark, not text
  local marks = child.lua_get([[vim.tbl_map(function(m) return m[4].virt_text[1][1] end,
    vim.api.nvim_buf_get_extmarks(0, require("dbdash.view.buffer").ns_status, 0, -1, { details = true }))]])
  eq(marks[1]:match("^next %d+s$") ~= nil, true)
  eq(child.lua_get("#_G.notes"), 0)
end

T["starting a running config switches to it; args on the command line apply"] = function()
  child.cmd("DbDashStart board.yaml n=5 ids=7,8")
  wait_loaded()
  local buf = child.lua_get("vim.api.nvim_get_current_buf()")
  child.cmd("enew")
  child.cmd("DbDashStart board.yaml")
  eq(child.lua_get("vim.api.nvim_get_current_buf()"), buf)
  eq(lines()[1], "n=5  label=hello  ids=7,8")
end

T["variables: update, reset, show"] = function()
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  child.cmd("DbDashUpdateVariable label world wide")
  child.lua([[_G.wait_for(function() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("world wide") end)]])
  eq(find_line("world wide │") ~= nil, true)
  child.cmd("DbDashUpdateVariable n x")
  eq(child.lua_get("_G.notes[#_G.notes].msg"):find("not a number") ~= nil, true)
  child.type_keys("R")
  child.lua([[_G.wait_for(function() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("label=hello") end)]])
  eq(lines()[1], "n=1  label=hello  ids=1,2")
  child.type_keys("A")
  eq(child.lua_get("vim.api.nvim_win_get_config(0).relative"), "editor")
  eq(lines()[1]:match("^n = 1"), "n = 1")
  child.type_keys("q")
  eq(child.lua_get("vim.api.nvim_win_get_config(0).relative"), "")
end

T["show SQL popup"] = function()
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  child.type_keys("s")
  eq(child.lua_get("{ vim.bo.filetype, vim.api.nvim_win_get_config(0).relative }"), { "sql", "editor" })
  eq(lines()[1], "SELECT 1 AS n, 'hello' AS label, '(1, 2)' AS ids_sql")
  eq(child.lua_get("vim.api.nvim_win_get_width(0)"), 60)
  child.type_keys("y")
  eq(child.fn.getreg('"'), "SELECT 1 AS n, 'hello' AS label, '(1, 2)' AS ids_sql")
end

T["stop closes the buffer; wiping the buffer stops the dashboard"] = function()
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  child.cmd("DbDashStop")
  eq(child.lua_get("#vim.tbl_keys(require('dbdash.scheduler').dashboards)"), 0)
  eq(child.lua_get("vim.fn.bufexists('dbdash://' .. ...)", { dir .. "/board.yaml" }), 0)
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  child.cmd("bwipeout!")
  eq(child.lua_get("#vim.tbl_keys(require('dbdash.scheduler').dashboards)"), 0)
end

T["errors are reported with their phase and shown above the content"] = function()
  child.cmd("DbDashStart broken.yaml")
  child.lua([[_G.wait_for(function() return #_G.notes > 0 end)]])
  local n = child.lua_get("_G.notes[1]")
  eq(n.level, vim.log.levels.ERROR)
  eq(n.msg:find("sqlite query error") ~= nil, true)
  local vl = child.lua_get([[vim.api.nvim_buf_get_extmarks(0, require("dbdash.view.buffer").ns_status, 0, -1, { details = true })[1][4].virt_lines[1][1][1] ]])
  eq(vl:find("^✗ sqlite query error") ~= nil, true)
  child.cmd("DbDashStart missing.yaml")
  eq(child.lua_get("_G.notes[#_G.notes].msg"):find("config file not found") ~= nil, true)
  child.cmd("DbDashStart board.yaml nope=1")
  eq(child.lua_get("_G.notes[#_G.notes].msg"):find("unknown argument 'nope'") ~= nil, true)
end

T["list and status"] = function()
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  local out = child.cmd_capture("DbDashList")
  eq(out:find("board.yaml %- idle, next refresh in %d+s") ~= nil, true)
  child.cmd("DbDashStatus")
  local text = table.concat(lines(), "\n")
  eq(text:find("Config:    board.yaml", 1, true) ~= nil, true)
  eq(text:find("%d+ ms%s+1 rows") ~= nil, true)
end

T["sidebar lists configs and starts/stops them"] = function()
  child.cmd("DbDash")
  eq(lines(), {
    "DbDash Sidebar",
    "Directory: " .. child.lua_get("vim.fn.fnamemodify(vim.fn.getcwd(), ':~')"),
    "",
    "▸ = Not running",
    "▾ = Running",
    "",
    "▸ board.yaml",
    "▸ broken.yaml",
  })
  eq(child.lua_get("{ vim.bo.filetype, vim.api.nvim_win_get_width(0), vim.wo.winfixwidth, vim.wo.number }"), { "dbdash-sidebar", 30, true, false })
  child.type_keys("r")
  eq(child.lua_get("_G.notes[#_G.notes].msg"), "DbDash not running for this config")
  child.type_keys("<CR>")
  wait_loaded()
  eq(child.lua_get("vim.bo.filetype"), "dbdash")
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
  child.cmd("wincmd h")
  eq(lines()[7], "▾ board.yaml")
  child.type_keys("t")
  eq(lines()[7], "▸ board.yaml")
  eq(child.lua_get("#vim.tbl_keys(require('dbdash.scheduler').dashboards)"), 0)
  child.cmd("DbDash") -- already open: jump to it
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
  child.type_keys("q")
  eq(child.lua_get("vim.bo.filetype ~= 'dbdash-sidebar'"), true)
end

T["sidebar without configs opens the directory"] = function()
  local empty = vim.fn.tempname()
  vim.fn.mkdir(empty, "p")
  child.cmd("cd " .. empty)
  child.cmd("DbDash")
  eq(child.lua_get("_G.notes[#_G.notes].msg"):find("No config files found in") ~= nil, true)
end

T["sessions restore running dashboards"] = function()
  child.cmd("DbDashStart board.yaml n=9")
  wait_loaded()
  local session = dir .. "/Session.vim"
  child.type_keys(":mksession " .. session .. "<CR>")
  eq(child.fn.filereadable(session), 1)
  setup_child(true)
  child.cmd("source " .. vim.fn.fnameescape(session))
  wait_loaded()
  eq(child.lua_get("vim.bo.filetype"), "dbdash")
  -- arguments are session-only: defaults after restore
  eq(lines()[1], "n=1  label=hello  ids=1,2")
end

T["sessions without 'blank' in sessionoptions keep dashboard windows"] = function()
  -- Regression: session setups often drop "blank", and :mksession then skipped the windows
  -- of nofile buffers, so dashboards were neither shown nor restarted.
  vim.fn.writefile(vim.split(CFG, "\n"), dir .. "/second.yaml")
  child.cmd("set sessionoptions-=blank")
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  child.cmd("vsplit")
  child.cmd("DbDashStart second.yaml")
  child.lua([[_G.wait_for(function() return #require("dbdash.scheduler").list() == 2 end)]])
  local session = dir .. "/Session2.vim"
  child.cmd("mksession! " .. vim.fn.fnameescape(session))
  setup_child(true)
  child.cmd("source " .. vim.fn.fnameescape(session))
  child.lua([[_G.wait_for(function()
    local ds = require("dbdash.scheduler").list()
    return #ds == 2 and ds[1].panels[1].rs ~= nil and ds[2].panels[1].rs ~= nil
  end)]])
  eq(child.lua_get("#require('dbdash.scheduler').list()"), 2)
  eq(child.lua_get([[vim.tbl_map(function(w)
    return vim.bo[vim.api.nvim_win_get_buf(w)].filetype
  end, vim.api.nvim_list_wins())]]), { "dbdash", "dbdash" })
end

T[":edit dbdash://<path> starts the dashboard"] = function()
  child.cmd("edit dbdash://" .. dir .. "/board.yaml")
  wait_loaded()
  eq(child.lua_get("#vim.tbl_keys(require('dbdash.scheduler').dashboards)"), 1)
end

T["timer refreshes on the interval and restart resets the countdown"] = function()
  local fast = CFG:gsub("interval: 1h", "interval: 1s")
  vim.fn.writefile(vim.split(fast, "\n"), dir .. "/fast.yaml")
  child.lua("require('dbdash').setup({ countdown_interval = 200 })")
  child.cmd("DbDashStart fast.yaml")
  wait_loaded()
  child.lua([[_G.wait_for(function()
    return #require("dbdash.scheduler").list()[1].panels[1].history >= 3
  end)]])
  local h = child.lua_get("require('dbdash.scheduler').list()[1].panels[1].history")
  eq(#h >= 3, true)
  eq(h[1].rows, 1)
  eq(child.lua_get("require('dbdash.scheduler').list()[1]:remaining() <= 1"), true)
end

T[":DbDashStyle re-renders cached data with another style"] = function()
  child.cmd("DbDashStart " .. ROOT .. "/example/line.yaml")
  child.lua([[_G.wait_for(function() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)):find("┌") end)]])
  local function text()
    return table.concat(lines(), "\n")
  end
  -- UTF-8 prefixes: braille U+2800-28FF, block elements U+2580-259F, arcs U+256D-2570.
  local BRAILLE, BLOCKS, ARCS = "\226[\160-\163]", "\226\150[\128-\159]", "\226\149[\173-\176]"
  eq(text():find(BRAILLE) ~= nil, true) -- braille by default
  local runs = child.lua_get("#require('dbdash.scheduler').list()[1].panels[1].history")
  child.cmd("DbDashStyle line quadrant")
  eq(text():find(BRAILLE), nil)
  eq(text():find(BLOCKS) ~= nil, true)
  child.cmd("DbDashStyle canvas ascii")
  eq(text():find("%*") ~= nil, true)
  child.cmd("DbDashStyle line asciichart")
  eq(text():find(ARCS) ~= nil, true)
  child.cmd("DbDashStyle line fancy")
  eq(child.lua_get("_G.notes[#_G.notes].msg"):find("unknown style 'fancy' for line") ~= nil, true)
  child.cmd("DbDashStyle reset")
  eq(text():find(BRAILLE) ~= nil, true)
  -- no new queries were run
  eq(child.lua_get("#require('dbdash.scheduler').list()[1].panels[1].history"), runs)
  eq(child.fn.getcompletion("DbDashStyle line q", "cmdline"), { "quadrant" })
end

T["query templates import macros from files next to the config"] = function()
  vim.fn.writefile({ "{% macro ids(xs) %}{{ xs|sql_in }}{% endmacro %}" }, dir .. "/macros.sql")
  local cfg = CFG:gsub("SELECT {{ n }} AS n", "{%% from 'macros.sql' import ids %%}SELECT {{ n }} AS n, {{ ids([7, 8])|sql_quote }} AS m")
  vim.fn.writefile(vim.split(cfg, "\n"), dir .. "/imports.yaml")
  child.cmd("DbDashStart imports.yaml")
  wait_loaded()
  eq(find_line("%(7, 8%)") ~= nil, true)
  eq(child.lua_get("#_G.notes"), 0)
end

local MULTI = [[
database:
  url: "sqlite:///:memory:"
interval: 3s
layout:
  columns: 2
panels:
  - query:
      sql: SELECT 'alpha' AS a
    show:
      type: table
      title: Fast
      interval: 1s
      show_countdown: true
  - query:
      sql: SELECT 'beta' AS b
    show:
      type: table
      title: Slow
      interval: 1h
  - query:
      sql: SELEC broken
    show:
      title: Broken
      span: 2
]]

local function start_multi()
  vim.fn.writefile(vim.split(MULTI, "\n"), dir .. "/multi.yaml")
  child.cmd("DbDashStart multi.yaml")
  child.lua([[_G.wait_for(function()
    local t = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    return t:find("alpha") and t:find("beta") and t:find("✗")
  end)]])
end

T["multi-panel: grid, per-panel errors and countdowns"] = function()
  start_multi()
  local first = lines()[1]
  eq(first:match("^Fast") ~= nil and first:find("Slow") ~= nil, true) -- side by side
  eq(find_line("^Broken  ✗ .*sqlite query error") ~= nil, true)
  eq(find_line("alpha") ~= nil and find_line("beta") ~= nil, true)
  local regions = child.lua_get("vim.b.dbdash_regions")
  eq(#regions, 3)
  eq(regions[1].row_s, regions[2].row_s)
  eq(regions[3].row_s > regions[1].row_e, true)
  local marks = child.lua_get([[vim.tbl_map(function(m) return { m[2], m[4].virt_text_win_col } end,
    vim.api.nvim_buf_get_extmarks(0, require("dbdash.view.buffer").ns_status, 0, -1, { details = true }))]])
  eq(#marks, 1) -- only the panel with show_countdown
  eq(marks[1][1], regions[1].row_s)
end

T["multi-panel: own intervals, and the top-level interval refreshes everything"] = function()
  start_multi()
  child.lua([[_G.wait_for(function()
    return #require("dbdash.scheduler").list()[1].panels[2].history >= 2
  end)]])
  local n = child.lua_get("vim.tbl_map(function(p) return #p.history end, require('dbdash.scheduler').list()[1].panels)")
  eq(n[2], 2) -- the 1h panel only refreshed through the 3s global timer
  eq(n[1] >= 3, true) -- the 1s panel refreshed on its own in between
end

T["multi-panel: commands act on the panel under the cursor"] = function()
  start_multi()
  local regions = child.lua_get("vim.b.dbdash_regions")
  -- Line inside panel 2; `N|` moves to a screen column (lines hold multi-byte glyphs).
  child.cmd(("normal! %dG%d|"):format(regions[2].row_s + 2, regions[2].x + 2))
  child.type_keys("s")
  eq(lines()[1], "SELECT 'beta' AS b")
  child.type_keys("q")
  child.cmd("DbDashStyle table box")
  local style = child.lua_get("vim.tbl_map(function(p) return p.style.renderer or '' end, require('dbdash.scheduler').list()[1].panels)")
  eq(style, { "", "box", "" })
  local status = (function()
    child.cmd("DbDashStatus")
    return table.concat(lines(), "\n")
  end)()
  eq(status:find("Panel 2: Slow", 1, true) ~= nil, true)
  eq(status:find("Error:", 1, true) ~= nil, true)
end

T["example table.yaml runs"] = function()
  child.cmd("DbDashStart " .. ROOT .. "/example/table.yaml")
  child.lua([[_G.wait_for(function() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)):find("value1") end)]])
  eq(find_line("Time") ~= nil, true)
  eq(find_line("value1") ~= nil, true)
  eq(child.lua_get("#_G.notes"), 0)
end

return T
