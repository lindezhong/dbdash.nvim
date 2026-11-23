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
  eq(child.lua_get("vim.api.nvim_buf_get_name(0)"), "dbdash://" .. vim.fs.normalize(dir) .. "/board.yaml")
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
    "● = Running  ◐ = Paused  ○ = Not running",
    "",
    "○ board.yaml",
    "○ broken.yaml",
  })
  eq(child.lua_get("{ vim.bo.filetype, vim.api.nvim_win_get_width(0), vim.wo.winfixwidth, vim.wo.number }"), { "dbdash-sidebar", 30, true, false })
  child.type_keys("r")
  eq(child.lua_get("_G.notes[#_G.notes].msg"), "DbDash not running for this config")
  child.type_keys("<CR>")
  wait_loaded()
  eq(child.lua_get("vim.bo.filetype"), "dbdash")
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
  child.cmd("wincmd h")
  eq(lines()[6], "● board.yaml")
  child.type_keys("t")
  eq(lines()[6], "○ board.yaml")
  eq(child.lua_get("#vim.tbl_keys(require('dbdash.scheduler').dashboards)"), 0)
  child.cmd("DbDash") -- already open: jump to it
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
  child.type_keys("q")
  eq(child.lua_get("vim.bo.filetype ~= 'dbdash-sidebar'"), true)
end

T["sidebar directories expand, collapse and open nested dashboards"] = function()
  vim.fn.mkdir(dir .. "/team/daily", "p")
  vim.fn.writefile(vim.split(CFG, "\n"), dir .. "/team/daily/nested.yaml")
  child.cmd("DbDash")
  eq(lines()[8], "▸ team/")
  child.api.nvim_win_set_cursor(0, { 8, 0 })
  child.type_keys("<CR>")
  eq({ lines()[8], lines()[9], child.api.nvim_win_get_cursor(0)[1] }, { "▾ team/", "  ▸ daily/", 8 })
  child.api.nvim_win_set_cursor(0, { 9, 0 })
  child.type_keys("<CR>")
  eq(lines()[10], "    ○ nested.yaml")
  child.type_keys("t") -- stop/refresh do nothing on directories
  eq(child.lua_get("#require('dbdash.scheduler').list()"), 0)
  child.api.nvim_win_set_cursor(0, { 10, 0 })
  child.type_keys("<CR>")
  wait_loaded()
  eq(child.fn.expand("%:t"), "nested.yaml")
  child.cmd("wincmd h")
  eq(lines()[10], "    ● nested.yaml")
  -- closing and reopening keeps the tree expanded
  child.type_keys("q")
  child.cmd("DbDash")
  eq(lines()[10], "    ● nested.yaml")
  -- collapse the top directory
  child.api.nvim_win_set_cursor(0, { 8, 0 })
  child.type_keys("<CR>")
  eq({ #lines(), lines()[8] }, { 8, "▸ team/" })
end

T["sidebar cursorline: the usual CursorLine by default, or none"] = function()
  child.cmd("DbDash")
  eq(child.lua_get("{ vim.wo.cursorline, vim.wo.winhighlight }"), { true, "" })
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(0, require('dbdash.view.sidebar').CURSOR_NS, 0, -1, {})"), 0)
  child.lua([[require("dbdash").setup({ sidebar = { cursorline = false } })]])
  child.cmd("DbDash") -- reapplied to the open sidebar
  eq(child.lua_get("vim.wo.cursorline"), false)
  child.lua([[require("dbdash").setup({ sidebar = { cursorline = "under" } })]])
  eq(child.lua_get("_G.notes[#_G.notes].msg"):find('sidebar.cursorline: must be "line", "name" or false', 1, true) ~= nil, true)
end

T["sidebar cursorline = name: underline after the marker, marker keeps its color"] = function()
  vim.fn.mkdir(dir .. "/team", "p")
  child.lua([[require("dbdash").setup({ sidebar = { cursorline = "name" } })]])
  child.cmd("DbDash")
  eq(child.lua_get("vim.wo.winhighlight"), "CursorLine:DbDashSidebarCursorLine")
  -- no attributes of its own (no underline, no background)
  eq(child.lua_get("vim.tbl_keys(vim.api.nvim_get_hl(0, { name = 'DbDashSidebarCursorLine' }))"), { "default" })
  eq(child.lua_get("vim.api.nvim_get_hl(0, { name = 'DbDashSidebarCursor' }).underline"), true)
  local function cursor_mark()
    return child.lua_get([[(function()
      local m = vim.api.nvim_buf_get_extmarks(0, require("dbdash.view.sidebar").CURSOR_NS, 0, -1, { details = true })
      if #m ~= 1 then return #m end
      local line = vim.api.nvim_buf_get_lines(0, m[1][2], m[1][2] + 1, false)[1]
      return { m[1][2] + 1, line:sub(m[1][3] + 1, m[1][4].end_col), m[1][4].hl_group }
    end)()]])
  end
  local function marker(lnum)
    return child.lua_get(([[(function()
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, require("dbdash.view.buffer").ns, { %d, 0 }, { %d, -1 }, { details = true })) do
        return m[4].hl_group
      end
    end)()]]):format(lnum - 1, lnum - 1))
  end
  -- start board.yaml, come back: its line is ● and the cursor is on it
  child.cmd("6")
  child.type_keys("<CR>")
  wait_loaded()
  child.cmd("wincmd h")
  child.cmd("6")
  eq(lines()[6], "● board.yaml")
  eq(cursor_mark(), { 6, "board.yaml", "DbDashSidebarCursor" }) -- not the ●
  eq(marker(6), "DbDashSidebarRunning")
  child.cmd("7")
  eq(cursor_mark(), { 7, "broken.yaml", "DbDashSidebarCursor" })
  child.cmd("8") -- a directory: arrow and name share a color, the whole entry is underlined
  eq(cursor_mark(), { 8, "▸ team/", "DbDashSidebarCursor" })
  child.cmd("1")
  eq(cursor_mark(), { 1, "DbDash Sidebar", "DbDashSidebarCursor" })
  child.cmd("3") -- empty line: nothing
  eq(cursor_mark(), 0)
end

T["sidebar width, position and keys come from setup()"] = function()
  child.o.columns = 160
  child.lua([[require("dbdash").setup({
    sidebar = { width = "25%", position = "right", keys = { select = "o", stop = false } },
  })]])
  child.cmd("DbDash")
  local win = child.api.nvim_get_current_win()
  eq(child.api.nvim_win_get_width(win), 40) -- 25% of 160
  eq(child.fn.win_screenpos(win)[2] > 80, true) -- on the right
  eq(child.fn.maparg("<CR>", "n"), "")
  eq(child.fn.maparg("t", "n"), "")
  child.type_keys("o")
  wait_loaded()
  -- the dashboard opens left of the sidebar, which keeps its width
  eq(child.fn.win_screenpos(child.api.nvim_get_current_win())[2], 1)
  eq(child.api.nvim_win_get_width(win), 40)
  -- a later setup() changes the keys of the existing sidebar buffer
  child.lua([[require("dbdash").setup({})]])
  child.cmd("DbDash")
  eq(child.fn.maparg("o", "n"), "")
  eq(child.fn.maparg("<CR>", "n") ~= "", true)
end

T["dashboard keys come from setup()"] = function()
  child.lua([[require("dbdash").setup({ dashboard = { keys = { show_sql = "S", reset = false } } })]])
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  eq(child.fn.maparg("s", "n"), "")
  eq(child.fn.maparg("R", "n"), "")
  eq(child.lua_get("vim.fn.maparg('S', 'n', false, true).desc"), "dbdash: Show the rendered query")
  eq(child.lua_get("vim.fn.maparg('a', 'n', false, true).buffer"), 1)
end

T["dashboard.open: vsplit, split, tab; a visible dashboard is jumped to"] = function()
  local function layout()
    return child.lua_get("{ #vim.api.nvim_tabpage_list_wins(0), #vim.api.nvim_list_tabpages(), vim.bo.filetype }")
  end
  child.lua([[require("dbdash").setup({ dashboard = { open = "vsplit" } })]])
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  eq(layout(), { 2, 1, "dbdash" })
  child.cmd("wincmd p")
  child.cmd("DbDashStart board.yaml") -- already visible: jump, no new window
  eq(layout(), { 2, 1, "dbdash" })
  child.cmd("only")
  child.lua([[require("dbdash").setup({ dashboard = { open = "split" } })]])
  child.cmd("enew")
  child.cmd("DbDashStart board.yaml")
  eq(layout(), { 2, 1, "dbdash" })
  eq(child.fn.winlayout()[1], "col")
  child.cmd("only")
  child.cmd("enew")
  child.lua([[require("dbdash").setup({ dashboard = { open = "tab" } })]])
  local unnamed = "#vim.tbl_filter(function(b) return vim.fn.buflisted(b) == 1 and vim.fn.bufname(b) == '' end, vim.api.nvim_list_bufs())"
  local before = child.lua_get(unnamed)
  child.cmd("DbDashStart board.yaml")
  eq(layout(), { 1, 2, "dbdash" })
  eq(child.lua_get(unnamed), before) -- tabnew's empty buffer was removed
  child.cmd("tabprevious")
  child.cmd("DbDashStart board.yaml") -- shown in the other tab: go there
  eq({ child.fn.tabpagenr(), #child.api.nvim_list_tabpages() }, { 2, 2 })
end

T["defaults.history caps the status history"] = function()
  child.lua([[require("dbdash").setup({ defaults = { history = 2 } })]])
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  for _ = 1, 4 do
    child.cmd("DbDashRestart")
    child.lua([[_G.wait_for(function() return not require("dbdash.scheduler").list()[1].panels[1].running end)]])
  end
  eq(child.lua_get("#require('dbdash.scheduler').list()[1].panels[1].history"), 2)
end

T["popup border and maximum size come from setup()"] = function()
  child.o.columns, child.o.lines = 160, 40
  child.lua([[require("dbdash").setup({ popup = { border = "single", max_width = "50%", max_height = 3 } })]])
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  child.cmd("DbDashStatus") -- several lines, wider than 80 columns
  local cfg = child.api.nvim_win_get_config(0)
  eq(cfg.relative, "editor")
  eq(cfg.border[1], "┌")
  eq({ cfg.width <= 80, cfg.height }, { true, 3 })
end

T["sidebar without configs says so and keeps the windows"] = function()
  local empty = vim.fn.tempname()
  vim.fn.mkdir(empty, "p")
  child.cmd("cd " .. empty)
  child.cmd("edit notes.txt")
  child.cmd("DbDash")
  eq(lines()[6], "(no config files matching *.yaml, *.yml)")
  eq(child.lua_get("{ vim.bo.filetype, #vim.api.nvim_tabpage_list_wins(0) }"), { "dbdash-sidebar", 2 })
  child.type_keys("<CR>") -- nothing to open
  eq(child.lua_get("{ vim.bo.filetype, #vim.api.nvim_tabpage_list_wins(0) }"), { "dbdash-sidebar", 2 })
  child.type_keys("q")
  eq(child.fn.expand("%:t"), "notes.txt")
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

T["mksession(file) and load_session(file) keep changed arguments"] = function()
  child.cmd("DbDashStart board.yaml n=9")
  wait_loaded()
  child.cmd("DbDashUpdateVariable ids 3,4")
  local file = dir .. "/Session.vim.dbdash"
  eq(child.lua_get("{ require('dbdash').mksession(...) }", { file }), { true })
  local path = child.lua_get("require('dbdash.scheduler').list()[1].path")
  eq(vim.json.decode(table.concat(vim.fn.readfile(file), "\n")),
    { version = 1, dashboards = { [path] = { n = "9", ids = "3,4" } } }) -- label is its default
  -- load into a running dashboard
  child.cmd("DbDashResetVariables")
  eq(child.lua_get("{ require('dbdash').load_session(...) }", { file }), { true })
  -- the argument line is redrawn when the refreshed query finishes
  child.lua([[_G.wait_for(function() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "n=9  label=hello  ids=3,4" end)]])
  eq(lines()[1], "n=9  label=hello  ids=3,4")
  -- load before the dashboard runs (as when a session is sourced): applied when it
  -- starts; unknown arguments and invalid values are skipped
  child.cmd("DbDashStop")
  vim.fn.writefile({ vim.json.encode({ version = 1, dashboards = { [path] = { n = "nine", ids = "5", gone = "x" } } }) }, file)
  child.lua("require('dbdash').load_session(...)", { file })
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  eq(lines()[1], "n=1  label=hello  ids=5")
  -- missing file: nothing to do; broken file: an error, not an exception
  eq(child.lua_get("{ require('dbdash').load_session(...) }", { dir .. "/none" }), { true })
  vim.fn.writefile({ "{" }, file)
  eq(child.lua_get("require('dbdash').load_session(...)", { file }), false)
end

T["on exit dashboards stop refreshing but mksession() still sees them"] = function()
  -- Session managers often save on VimLeave, after dbdash's VimLeavePre cleanup.
  child.cmd("DbDashStart board.yaml n=4")
  wait_loaded()
  child.api.nvim_exec_autocmds("VimLeavePre", {})
  eq(child.lua_get("require('dbdash.scheduler').list()[1].gtimer == nil and require('dbdash.scheduler').list()[1].ctimer == nil"), true)
  eq(child.lua_get("require('dbdash.scheduler').list()[1].panels[1].timer == nil"), true)
  local file = dir .. "/exit.dbdash"
  child.lua("require('dbdash').mksession(...)", { file })
  local data = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  eq(vim.tbl_values(data.dashboards), { { n = "4" } })
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

local function fast_board()
  local fast = CFG:gsub("interval: 1h", "interval: 1s")
  vim.fn.writefile(vim.split(fast, "\n"), dir .. "/fast.yaml")
  child.cmd("DbDashStart fast.yaml")
  wait_loaded()
end

local function runs()
  return child.lua_get("#require('dbdash.scheduler').list()[1].panels[1].history")
end

local function paused()
  return child.lua_get("require('dbdash.scheduler').list()[1].paused == true")
end

local function settle(ms)
  child.lua(("vim.wait(%d, function() return false end, 20)"):format(ms))
end

T["changing an argument while a query runs re-runs it with the new value"] = function()
  -- Regression: the refresh for the new value was skipped because the previous query
  -- was still running, so the dashboard showed the old value until the next interval.
  local slow = CFG:gsub(
    "SELECT {{ n }} AS n,",
    "SELECT {{ n }} AS n, (WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 1500000) SELECT count(*) FROM c) AS big,"
  )
  vim.fn.writefile(vim.split(slow, "\n"), dir .. "/slow.yaml")
  child.cmd("DbDashStart slow.yaml")
  child.lua([[_G.wait_for = function(fn) return vim.wait(20000, fn, 10) end]])
  child.lua([[_G.wait_for(function() return require("dbdash.scheduler").list()[1].panels[1].rs ~= nil end)]])
  child.cmd("DbDashRestart")
  eq(child.lua_get("require('dbdash.scheduler').list()[1].panels[1].running"), true)
  child.cmd("DbDashUpdateVariable n 5") -- while the query runs
  child.lua([[_G.wait_for(function()
    local p = require("dbdash.scheduler").list()[1].panels[1]
    return not p.running and p.rs.rows[1][1] == 5
  end)]])
  eq(child.lua_get("require('dbdash.scheduler').list()[1].panels[1].rs.rows[1][1]"), 5)
end

T["hidden dashboards pause; showing them again refreshes what is due"] = function()
  fast_board()
  child.cmd("enew") -- the buffer stays, another buffer is shown
  settle(100)
  eq(paused(), true)
  eq(child.lua_get("require('dbdash.scheduler').list()[1]:status_word()"), "paused")
  local before = runs()
  settle(2500)
  eq(runs(), before) -- no queries while hidden
  child.cmd("buffer fast.yaml")
  child.lua([[_G.wait_for(function() return not require("dbdash.scheduler").list()[1].paused end)]])
  child.lua(([[_G.wait_for(function() return #require("dbdash.scheduler").list()[1].panels[1].history > %d end)]]):format(before))
  eq(runs() > before, true) -- due: refreshed right away
  settle(2200)
  eq(runs() >= before + 2, true) -- and the timer runs again
end

T["visible in a split without the cursor keeps refreshing"] = function()
  fast_board()
  child.cmd("vsplit")
  child.cmd("enew") -- cursor in the other window, dashboard still on screen
  settle(100)
  eq(paused(), false)
  local before = runs()
  settle(2200)
  eq(runs() >= before + 1, true)
  -- two windows show it; closing one does not pause
  child.cmd("buffer fast.yaml")
  child.cmd("close")
  settle(100)
  eq(paused(), false)
end

T["shown only in another tab page: paused until that tab is entered"] = function()
  fast_board()
  child.cmd("tabnew")
  settle(100)
  eq(paused(), true)
  local before = runs()
  settle(1500)
  eq(runs(), before)
  child.cmd("tabprevious")
  settle(100)
  eq(paused(), false)
end

T["resuming before the next refresh keeps the remaining time"] = function()
  child.cmd("DbDashStart board.yaml") -- interval 1h
  wait_loaded()
  child.cmd("enew")
  settle(100)
  eq(paused(), true)
  local before = runs()
  child.cmd("buffer board.yaml")
  settle(200)
  eq({ paused(), runs() }, { false, before }) -- not due: no refresh
  eq(child.lua_get("require('dbdash.scheduler').list()[1]:remaining() > 3500"), true)
end

T["the sidebar marks paused dashboards with ◐"] = function()
  fast_board()
  child.cmd("enew")
  settle(100)
  child.cmd("DbDash")
  eq(vim.tbl_contains(lines(), "◐ fast.yaml"), true)
end

T["pause_hidden = false keeps hidden dashboards refreshing"] = function()
  child.lua([[require("dbdash").setup({ dashboard = { pause_hidden = false } })]])
  fast_board()
  child.cmd("enew")
  settle(100)
  eq(paused(), false)
  local before = runs()
  settle(2200)
  eq(runs() >= before + 1, true)
end

T[":DbDashExport: register, named register, file, overwrite with !"] = function()
  child.cmd("DbDashStart board.yaml")
  wait_loaded()
  child.cmd("DbDashExport csv")
  eq(child.fn.getreg('"'), "n,label,ids_sql\n1,hello,\"(1, 2)\"\n")
  eq(child.fn.getregtype('"'), "V")
  eq(child.lua_get("_G.notes[#_G.notes].msg"), 'dbdash: exported 1 rows as csv to register "')
  child.cmd('normal! "xyy') -- make sure x is set before
  child.type_keys('"x', ":DbDashExport json<CR>")
  eq(vim.json.decode(child.fn.getreg("x")), { { n = 1, label = "hello", ids_sql = "(1, 2)" } })
  local file = dir .. "/out.md"
  child.cmd("DbDashExport markdown " .. file)
  eq(vim.fn.readfile(file), { "| n | label | ids_sql |", "| ---: | --- | --- |", "| 1 | hello | (1, 2) |" })
  child.cmd("DbDashExport tsv " .. file)
  eq(child.lua_get("_G.notes[#_G.notes].msg"):find("exists %(add ! to overwrite%)") ~= nil, true)
  eq(vim.fn.readfile(file)[1], "| n | label | ids_sql |")
  child.cmd("DbDashExport! tsv " .. file)
  eq(vim.fn.readfile(file), { "n\tlabel\tids_sql", "1\thello\t(1, 2)" })
  child.cmd("DbDashExport xml")
  eq(child.lua_get("_G.notes[#_G.notes].msg"):find("unknown export format") ~= nil, true)
  eq(child.lua_get("vim.fn.getcompletion('DbDashExport j', 'cmdline')"), { "json" })
end

T["export key picks a format; with panels the one under the cursor"] = function()
  child.cmd("DbDashStart " .. ROOT .. "/example/multi_panel.yaml")
  child.lua([[_G.wait_for(function()
    local d = require("dbdash.scheduler").list()[1]
    for _, p in ipairs(d.panels) do if not p.rs then return false end end
    return true
  end)]])
  child.lua([[vim.ui.select = function(items, _, cb) cb("csv") end]])
  local r = child.lua_get("require('dbdash.scheduler').list()[1].regions[2]")
  child.api.nvim_win_set_cursor(0, { r.row_s + 2, r.x + 1 })
  child.type_keys("e")
  local second = child.lua_get("require('dbdash.export').format(require('dbdash.scheduler').list()[1].panels[2].rs, 'csv')")
  eq(child.fn.getreg('"'), second)
end

T["stat dashboards keep recent values for the change and the sparkline"] = function()
  vim.fn.writefile({
    "database: { url: 'sqlite:///:memory:' }",
    "query: { sql: 'SELECT abs(random() % 1000) AS v' }",
    "show: { type: stat, title: Orders, interval: 1s }",
  }, dir .. "/stat.yaml")
  child.cmd("DbDashStart stat.yaml")
  child.lua([[_G.wait_for = function(fn) return vim.wait(8000, fn, 20) end]])
  child.lua([[_G.wait_for(function()
    return #(require("dbdash.scheduler").list()[1].panels[1].values or {}) >= 3
  end)]])
  local text = table.concat(lines(), "\n")
  eq(text:find("Orders", 1, true) ~= nil, true)
  eq(text:find("[↑↓=] ") ~= nil, true) -- change since the previous refresh
  eq(text:find("[▁▂▃▄▅▆▇█][▁▂▃▄▅▆▇█]") ~= nil, true) -- sparkline
end

T["thresholds notify once when a value rises to a notify step"] = function()
  vim.fn.writefile({
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  sql: SELECT {{ v }} AS errors",
    "  args: [{ name: v, type: int, default: 5 }]",
    "show:",
    "  type: stat",
    "  thresholds: [{ value: 10, color: yellow }, { value: 50, color: red, notify: true }]",
  }, dir .. "/alert.yaml")
  child.cmd("DbDashStart alert.yaml")
  child.lua([[_G.wait_for(function() return require("dbdash.scheduler").list()[1].panels[1].rs ~= nil end)]])
  local function set(v)
    child.cmd("DbDashUpdateVariable v " .. v)
    child.lua(([[_G.wait_for(function()
      local p = require("dbdash.scheduler").list()[1].panels[1]
      return not p.running and p.rs.rows[1][1] == %d
    end)]]):format(v))
  end
  local function warnings()
    return child.lua_get([[vim.tbl_map(function(n) return n.msg end,
      vim.tbl_filter(function(n) return n.level == vim.log.levels.WARN end, _G.notes))]])
  end
  set(20) -- yellow: no notify on that step
  eq(warnings(), {})
  set(60)
  eq(warnings(), { "dbdash: alert.yaml: 60 ≥ 50" })
  set(70) -- still on the red step: no new notification
  eq(#warnings(), 1)
  set(20)
  set(80) -- crossed again
  eq(warnings(), { "dbdash: alert.yaml: 60 ≥ 50", "dbdash: alert.yaml: 80 ≥ 50" })
end

local BROKEN = {
  "database: { url: 'sqlite:///:memory:' }",
  "query:",
  "  sql: SELECT {{ v }} AS n",
  "  args: [{ name: v, default: oops }]", -- SELECT oops: no such column
  "show: { type: table, title: Broken, interval: 1s }",
}

local function panel(expr)
  return child.lua_get("require('dbdash.scheduler').list()[1].panels[1]." .. expr)
end

T["backoff: consecutive failures wait 2x, 4x... the interval; success resets"] = function()
  eq(child.lua_get("require('dbdash.scheduler').backoff_delay(1000, 1, 8)"), 1000)
  eq(child.lua_get("require('dbdash.scheduler').backoff_delay(1000, 3, 8)"), 4000)
  eq(child.lua_get("require('dbdash.scheduler').backoff_delay(1000, 6, 8)"), 8000)
  eq(child.lua_get("require('dbdash.scheduler').backoff_delay(1000, 6, 1)"), 1000)
  vim.fn.writefile(BROKEN, dir .. "/broken2.yaml")
  child.cmd("DbDashStart broken2.yaml")
  child.lua([[_G.wait_for = function(fn) return vim.wait(10000, fn, 20) end]])
  child.lua([[_G.wait_for(function() return (require("dbdash.scheduler").list()[1].panels[1].failures or 0) >= 3 end)]])
  eq({ panel("failures"), panel("backoff_mult") }, { 3, 4 })
  eq(child.lua_get("require('dbdash.scheduler').list()[1].panels[1]:remaining() >= 3"), true) -- ~4s, not 1s
  eq(child.lua_get("require('dbdash.scheduler').list()[1]:status_word()"), "retrying")
  child.cmd("DbDashStatus")
  eq(table.concat(lines(), "\n"):find("Retrying:  failed 3 times in a row", 1, true) ~= nil, true)
  child.cmd("close")
  -- the default "once": one notification for the repeated error
  eq(child.lua_get("#vim.tbl_filter(function(n) return n.level == vim.log.levels.ERROR end, _G.notes)"), 1)
  -- a manual refresh is not delayed; success resets the backoff
  child.cmd("DbDashUpdateVariable v 1")
  child.lua([[_G.wait_for(function() return require("dbdash.scheduler").list()[1].panels[1].error == nil end)]])
  eq({ panel("failures"), panel("retry_at") }, { 0, vim.NIL })
  eq(child.lua_get("require('dbdash.scheduler').list()[1].panels[1]:remaining() <= 1"), true)
end

T["errors.notify always / never; backoff = 1 keeps the interval"] = function()
  vim.fn.writefile(BROKEN, dir .. "/broken3.yaml")
  child.lua([[require("dbdash").setup({ errors = { notify = "always", backoff = 1 } })]])
  child.cmd("DbDashStart broken3.yaml")
  child.lua([[_G.wait_for = function(fn) return vim.wait(10000, fn, 20) end]])
  child.lua([[_G.wait_for(function() return (require("dbdash.scheduler").list()[1].panels[1].failures or 0) >= 3 end)]])
  eq(panel("retry_at"), vim.NIL)
  -- "always": one notification per failure
  eq(child.lua_get("#_G.notes == require('dbdash.scheduler').list()[1].panels[1].failures"), true)
  child.cmd("DbDashStop")
  child.lua([[_G.notes = {}; require("dbdash").setup({ errors = { notify = "never" } })]])
  child.cmd("DbDashStart broken3.yaml")
  child.lua([[_G.wait_for(function() return (require("dbdash.scheduler").list()[1].panels[1].failures or 0) >= 2 end)]])
  eq(child.lua_get("#_G.notes"), 0)
  -- still shown in the dashboard (a virtual line above the first line)
  local marks = child.lua_get([[vim.tbl_map(function(m) return m[4].virt_lines and m[4].virt_lines[1][1][1] or "" end,
    vim.api.nvim_buf_get_extmarks(0, require("dbdash.view.buffer").ns_status, 0, -1, { details = true }))]])
  eq(table.concat(marks, "\n"):find("✗ ", 1, true) ~= nil, true)
end

T["backoff with panels: the global interval skips a panel that is backing off"] = function()
  vim.fn.writefile({
    "database: { url: 'sqlite:///:memory:' }",
    "interval: 1s",
    "panels:",
    "  - query: { sql: SELECT oops }",
    "    show: { title: Broken }",
    "  - query: { sql: SELECT 1 AS ok }",
    "    show: { title: Fine }",
  }, dir .. "/mixed.yaml")
  child.cmd("DbDashStart mixed.yaml")
  child.lua([[vim.wait(4500, function() return false end, 50)]])
  local broken = child.lua_get("#require('dbdash.scheduler').list()[1].panels[1].history")
  local fine = child.lua_get("#require('dbdash.scheduler').list()[1].panels[2].history")
  eq(fine >= 4, true)
  eq(broken < fine, true) -- 1s, 2s, 4s apart instead of every second
end

T["lua:// dashboards: template, args, chart; errors point at the YAML line"] = function()
  vim.fn.writefile({
    "database: { url: 'lua://' }",
    "query:",
    "  args: [{ name: n, type: int, default: 3 }]",
    "  sql: |",
    "    local rows = {}",
    "    for i = 1, {{ n }} do rows[i] = { 'k' .. i, i * args.n } end",
    "    return { columns = { 'k', 'v' }, rows = rows }",
    "show: { type: table, title: Lua board }",
  }, dir .. "/lua.yaml")
  child.cmd("DbDashStart lua.yaml")
  child.lua([[_G.wait_for(function() return require("dbdash.scheduler").list()[1].panels[1].rs ~= nil end)]])
  eq(child.lua_get("require('dbdash.scheduler').list()[1].panels[1].rs.rows"), { { "k1", 3 }, { "k2", 6 }, { "k3", 9 } })
  child.cmd("DbDashUpdateVariable n 2")
  child.lua([[_G.wait_for(function() return require("dbdash.scheduler").list()[1].panels[1].rs.row_count == 2 end)]])
  eq(child.lua_get("require('dbdash.scheduler').list()[1].panels[1].rs.rows[2]"), { "k2", 4 })
  -- a runtime error is reported with the line of the YAML file
  vim.fn.writefile({
    "database: { url: 'lua://' }",
    "query:",
    "  sql: |",
    "    local t = nil",
    "    return t.rows",
  }, dir .. "/lua_err.yaml")
  child.cmd("DbDashStart lua_err.yaml")
  child.lua([[_G.wait_for(function()
    for _, d in ipairs(require("dbdash.scheduler").list()) do
      if d.path:find("lua_err") and d.panels[1].error then return true end
    end
  end)]])
  eq(child.lua_get("_G.notes[#_G.notes].msg"):find("lua_err.yaml:5: attempt to index local 't'", 1, true) ~= nil, true)
end

T["query.transform: shown by :DbDashShowSQL, exported as transformed"] = function()
  vim.fn.writefile({
    "database: { url: 'sqlite:///:memory:' }",
    "query:",
    "  sql: SELECT 'a' AS k, 2 AS v",
    "  transform: |",
    "    return { { k = rs.rows[1][1], v = rs.rows[1][2] * 10 } }",
    "show: { type: table }",
  }, dir .. "/tf.yaml")
  child.cmd("DbDashStart tf.yaml")
  child.lua([[_G.wait_for(function() return require("dbdash.scheduler").list()[1].panels[1].rs ~= nil end)]])
  child.cmd("DbDashExport csv")
  eq(child.fn.getreg('"'), "k,v\na,20\n")
  child.cmd("DbDashShowSQL")
  eq(lines(), { "SELECT 'a' AS k, 2 AS v", "", "-- query.transform", "return { { k = rs.rows[1][1], v = rs.rows[1][2] * 10 } }" })
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
