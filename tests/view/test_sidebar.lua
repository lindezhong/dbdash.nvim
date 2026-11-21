-- Sidebar tree: listing (sidebar.dir, pattern, exclude), rendering and highlights.
local sidebar = require("dbdash.view.sidebar")
local dbdash = require("dbdash")
local eq = MiniTest.expect.equality

local dir
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      for _, f in ipairs({
        "a.yaml", "b.yml", "c.schema.yaml", "notes.txt", "d.dash.yaml",
        "sub/e.yaml", "sub/deeper/f.yaml", ".hidden/g.yaml", "node_modules/h.yaml",
      }) do
        vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. f), "p")
        vim.fn.writefile({}, dir .. "/" .. f)
      end
      vim.fn.mkdir(dir .. "/empty", "p")
    end,
    post_case = function()
      dbdash.setup({})
    end,
  },
})

T["entries: config files and all non-hidden directories of one level"] = function()
  dbdash.setup({})
  eq(sidebar.entries(dir), { files = { "a.yaml", "b.yml", "d.dash.yaml" }, dirs = { "empty", "node_modules", "sub" } })
  eq(sidebar.entries(dir .. "/sub"), { files = { "e.yaml" }, dirs = { "deeper" } })
end

T["entries: pattern for files, exclude for files and directories"] = function()
  dbdash.setup({ sidebar = { pattern = { "*.dash.yaml" }, exclude = { "node_modules", "a.*" } } })
  eq(sidebar.entries(dir), { files = { "d.dash.yaml" }, dirs = { "empty", "sub" } })
end

T["dir: path, relative path, function, default cwd"] = function()
  dbdash.setup({ sidebar = { dir = dir .. "/sub" } })
  eq(sidebar.dir(), vim.fs.normalize(dir .. "/sub"))
  dbdash.setup({ sidebar = { dir = function()
    return dir
  end } })
  eq(sidebar.dir(), dir)
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  dbdash.setup({ sidebar = { dir = "sub" } })
  eq(sidebar.dir(), vim.fs.normalize(vim.fn.getcwd() .. "/sub"))
  dbdash.setup({})
  eq(sidebar.dir(), vim.fs.normalize(vim.fn.getcwd()))
  vim.cmd.cd(vim.fn.fnameescape(cwd))
end

local function render()
  local buf = vim.api.nvim_create_buf(false, true)
  sidebar.render(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, sidebar.HEADER_LINES, -1, false)
  local marks = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, require("dbdash.view.buffer").ns, 0, -1, { details = true })) do
    local line = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1]
    marks[#marks + 1] = { m[4].hl_group, line:sub(m[3] + 1, m[4].end_col) }
  end
  return lines, marks, buf
end

T["tree: files first, then directories; expanded ones show their content indented"] = function()
  dbdash.setup({ sidebar = { dir = dir } })
  eq((render()), { "○ a.yaml", "○ b.yml", "○ d.dash.yaml", "▸ empty/", "▸ node_modules/", "▸ sub/" })
  sidebar.toggle(dir, dir .. "/sub")
  sidebar.toggle(dir, dir .. "/sub/deeper")
  sidebar.toggle(dir, dir .. "/empty")
  local lines, _, buf = render()
  eq(lines, {
    "○ a.yaml", "○ b.yml", "○ d.dash.yaml",
    "▾ empty/",
    "▸ node_modules/",
    "▾ sub/",
    "  ○ e.yaml",
    "  ▾ deeper/",
    "    ○ f.yaml",
  })
  -- line -> node mapping
  local nodes = vim.b[buf].dbdash_sidebar_nodes
  eq(nodes[tostring(sidebar.HEADER_LINES + 7)], { path = dir .. "/sub/e.yaml" })
  eq(nodes[tostring(sidebar.HEADER_LINES + 8)], { path = dir .. "/sub/deeper", dir = true })
  sidebar.toggle(dir, dir .. "/sub") -- collapse: its children are hidden, state kept
  eq(#render(), 6)
  sidebar.toggle(dir, dir .. "/sub")
  eq((render())[9], "    ○ f.yaml")
end

T["highlights: directories with their arrow, running and idle markers"] = function()
  dbdash.setup({ sidebar = { dir = dir .. "/sub" } })
  local _, marks = render()
  eq(marks, {
    { "DbDashSidebarRunning", "●" }, -- legend
    { "DbDashSidebarPaused", "◐" },
    { "DbDashSidebarIdle", "○" },
    { "DbDashSidebarIdle", "○" },
    { "DbDashSidebarDir", "▸ deeper/" },
  })
  local links = {}
  for _, g in ipairs({ "DbDashSidebarDir", "DbDashSidebarRunning", "DbDashSidebarPaused", "DbDashSidebarIdle" }) do
    links[g] = vim.api.nvim_get_hl(0, { name = g }).link
  end
  eq(links, {
    DbDashSidebarDir = "Directory",
    DbDashSidebarRunning = "DiagnosticOk",
    DbDashSidebarPaused = "DiagnosticWarn",
    DbDashSidebarIdle = "Normal",
  })
end

T["an empty directory says so"] = function()
  local empty = vim.fn.tempname()
  vim.fn.mkdir(empty, "p")
  dbdash.setup({ sidebar = { dir = empty } })
  eq((render()), { "(no config files matching *.yaml, *.yml)" })
end

return T
