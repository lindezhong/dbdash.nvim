-- Sidebar listing config files (design §3.4). Configured by setup({ sidebar = ... }).
local M = {}

local function opts()
  return require("dbdash").options.sidebar
end

local HEADER_LINES = 5
local NAME = "dbdash-sidebar"

local function sidebar_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "dbdash-sidebar" then
      return b
    end
  end
end

local function sidebar_win(buf)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
end

---The directory the sidebar lists: sidebar.dir (a path or a function returning one,
---relative paths from the current directory), or the current directory.
---@return string
function M.dir()
  local d = opts().dir
  if type(d) == "function" then
    d = d()
  end
  if type(d) ~= "string" or d == "" then
    d = vim.fn.getcwd()
  end
  d = vim.fs.normalize(d)
  if not d:match("^/") and not d:match("^%a:[/\\]") then
    d = vim.fs.joinpath(vim.fn.getcwd(), d)
  end
  return vim.fs.normalize(d)
end

local function matcher(globs)
  local pats = {}
  for i, g in ipairs(globs) do
    pats[i] = vim.glob.to_lpeg(g)
  end
  return function(name)
    for _, p in ipairs(pats) do
      if p:match(name) then
        return true
      end
    end
    return false
  end
end

---One directory level: config files (matching sidebar.pattern, not sidebar.exclude) and
---subdirectories (not hidden, not matching sidebar.exclude), each sorted by name.
---@param dir string
---@return { files: string[], dirs: string[] }
function M.entries(dir)
  local o = opts()
  local include, exclude = matcher(o.pattern), matcher(o.exclude)
  local files, dirs = {}, {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "link" then
      kind = (vim.uv.fs_stat(vim.fs.joinpath(dir, name)) or {}).type
    end
    if kind == "directory" then
      if name:sub(1, 1) ~= "." and not exclude(name) then
        dirs[#dirs + 1] = name
      end
    elseif kind == "file" and include(name) and not exclude(name) then
      files[#files + 1] = name
    end
  end
  table.sort(files)
  table.sort(dirs)
  return { files = files, dirs = dirs }
end

-- Expanded directories per sidebar root: expanded[root][abs dir] = true. Kept while
-- Neovim runs, so closing and reopening the sidebar keeps the tree as it was.
local expanded = {}

local function is_expanded(root, dir)
  return expanded[root] ~= nil and expanded[root][dir] == true
end

---Expand or collapse a directory of the tree rooted at `root`.
function M.toggle(root, dir)
  expanded[root] = expanded[root] or {}
  expanded[root][dir] = not expanded[root][dir] or nil
end

M.HEADER = {
  "DbDash Sidebar",
  "", -- Directory: ...
  "",
  "● = Running  ◐ = Paused  ○ = Not running",
  "",
}

local sidebar_doc

---Style queries on the sidebar's document (rebuilt when the user sheet changes).
function M.css()
  local user = require("dbdash.css").user_rules()
  if not sidebar_doc or sidebar_doc.user ~= user then
    sidebar_doc = { doc = require("dbdash.dom.build").view("sidebar"), user = user }
  end
  return require("dbdash.css").scope(sidebar_doc.doc.root)
end

---Fill the sidebar buffer with the tree; b:dbdash_sidebar_nodes maps line numbers to
---{ path, dir } nodes.
function M.render(buf)
  require("dbdash.render.highlight").setup()
  local sched = require("dbdash.scheduler")
  local root = M.dir()
  local lines = vim.deepcopy(M.HEADER)
  lines[2] = "Directory: " .. vim.fn.fnamemodify(root, ":~")
  -- colors from the sidebar's own document (css: sidebar-item.running, sidebar-dir, ...)
  local css = M.css()
  local function item(state)
    return css:hl("sidebar-item", { classes = { state } })
  end
  local hl = {
    { row = 3, col_s = 0, col_e = #"●", group = item("running") },
    { row = 3, col_s = #"● = Running  ", col_e = #"● = Running  ◐", group = item("paused") },
    {
      row = 3,
      col_s = #"● = Running  ◐ = Paused  ",
      col_e = #"● = Running  ◐ = Paused  ○",
      group = item("idle"),
    },
  }
  local nodes = {}

  local function walk(dir, depth)
    local e = M.entries(dir)
    local indent = string.rep("  ", depth)
    for _, f in ipairs(e.files) do
      local path = vim.fs.joinpath(dir, f)
      local d = sched.get(path)
      local mark, group = "○", item("idle")
      if d and d.paused then
        mark, group = "◐", item("paused")
      elseif d then
        mark, group = "●", item("running")
      end
      lines[#lines + 1] = indent .. mark .. " " .. f
      hl[#hl + 1] = { row = #lines - 1, col_s = #indent, col_e = #indent + #mark, group = group }
      nodes[tostring(#lines)] = { path = path, name_col = #indent + #mark + 1 }
    end
    for _, d in ipairs(e.dirs) do
      local path = vim.fs.joinpath(dir, d)
      local open = is_expanded(root, path)
      lines[#lines + 1] = indent .. (open and "▾" or "▸") .. " " .. d .. "/"
      hl[#hl + 1] =
        { row = #lines - 1, col_s = #indent, col_e = #lines[#lines], group = css:hl("sidebar-dir") }
      nodes[tostring(#lines)] = { path = path, dir = true, name_col = #indent }
      if open then
        walk(path, depth + 1)
      end
    end
    return #e.files + #e.dirs
  end

  if walk(root, 0) == 0 then
    lines[#lines + 1] = "(no config files matching " .. table.concat(opts().pattern, ", ") .. ")"
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  local ns = require("dbdash.view.buffer").ns
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    vim.api.nvim_buf_set_extmark(buf, ns, h.row, h.col_s, { end_col = h.col_e, hl_group = h.group })
  end
  vim.b[buf].dbdash_sidebar_nodes = nodes
  M.update_cursor(buf)
  return root
end

local CURSOR_NS = vim.api.nvim_create_namespace("dbdash_sidebar_cursor")
M.CURSOR_NS = CURSOR_NS

---With sidebar.cursorline = "name": mark the cursor line's name with DbDashSidebarCursor
---(an underline by default), leaving out the running/paused/idle marker so it keeps its
---own color; the window's CursorLine is then DbDashSidebarCursorLine (empty by default).
function M.update_cursor(buf)
  vim.api.nvim_buf_clear_namespace(buf, CURSOR_NS, 0, -1)
  local win = sidebar_win(buf)
  if not win or opts().cursorline ~= "name" then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local node = (vim.b[buf].dbdash_sidebar_nodes or {})[tostring(lnum)]
  local s = node and node.name_col or 0
  if #line > s then
    vim.api.nvim_buf_set_extmark(
      buf,
      CURSOR_NS,
      lnum - 1,
      s,
      { end_col = #line, hl_group = M.css():hl("sidebar-item", { classes = { "cursor" } }) }
    )
  end
end

---Re-render the sidebar if it exists (after dashboards start or stop).
function M.refresh()
  local buf = sidebar_buf()
  if buf then
    M.render(buf)
  end
end

---The node under the cursor: { path, dir }.
local function node_at_cursor(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return (vim.b[buf].dbdash_sidebar_nodes or {})[tostring(lnum)]
end

---The config file under the cursor (nil on directories and other lines).
local function selected(buf)
  local n = node_at_cursor(buf)
  return n and not n.dir and n.path or nil
end

---Sidebar width in columns.
local function width()
  return require("dbdash.util.size").resolve(opts().width, vim.o.columns)
end

---A window beside the sidebar for dashboards (created if needed).
local function target_win(side_win)
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev ~= 0 and prev ~= side_win and vim.api.nvim_win_get_config(prev).relative == "" then
    return prev
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= side_win and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
  vim.cmd(opts().position == "right" and "leftabove vnew" or "rightbelow vnew")
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(side_win)
  vim.cmd("vertical resize " .. width())
  return w
end

local function on_enter(buf)
  local n = node_at_cursor(buf)
  if n and n.dir then
    M.toggle(M.dir(), n.path)
    local cursor = vim.api.nvim_win_get_cursor(0)
    M.render(buf)
    vim.api.nvim_win_set_cursor(0, cursor) -- the directory line does not move
    return
  end
  local path = n and n.path
  if not path then
    return
  end
  local sched = require("dbdash.scheduler")
  local side_win = vim.api.nvim_get_current_win()
  local win = target_win(side_win)
  sched.start(path, { win = win })
  M.refresh()
end

local function on_stop(buf)
  local path = selected(buf)
  if path then
    require("dbdash.scheduler").stop(path)
    M.refresh()
  end
end

local function on_refresh(buf)
  local path = selected(buf)
  if not path then
    return
  end
  local d = require("dbdash.scheduler").get(path)
  if not d then
    vim.notify("DbDash not running for this config", vim.log.levels.WARN)
    return
  end
  d:restart()
end

local function create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, NAME)
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.buflisted = false
  bo.filetype = "dbdash-sidebar"
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      M.update_cursor(buf)
    end,
  })
  return buf
end

local ACTIONS = {
  select = on_enter,
  stop = on_stop,
  refresh = on_refresh,
  close = function()
    M.close()
  end,
}

---Cursor line of the sidebar window per sidebar.cursorline (see M.update_cursor).
function M.set_cursorline(win)
  local mode = opts().cursorline
  vim.wo[win].cursorline = mode ~= false
  vim.wo[win].winhighlight = mode == "name" and "CursorLine:DbDashSidebarCursorLine" or ""
end

---(Re)define the buffer keys from sidebar.keys; keys of a previous setup() are removed.
local function apply_keys(buf)
  for _, lhs in ipairs(vim.b[buf].dbdash_keys or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  local mapped = {}
  for action, fn in pairs(ACTIONS) do
    local lhs = opts().keys[action]
    if lhs then
      vim.keymap.set("n", lhs, function()
        fn(buf)
      end, { buffer = buf, nowait = true, silent = true, desc = "dbdash sidebar: " .. action })
      mapped[#mapped + 1] = lhs
    end
  end
  vim.b[buf].dbdash_keys = mapped
end

---Open the sidebar (sidebar.position), or jump to it when already open. Without config
---files it says so in the list; it does not open the directory itself, which file
---explorers may take over (and close Neovim with their last-window rules).
function M.open()
  local buf = sidebar_buf() or create_buf()
  apply_keys(buf)
  local win = sidebar_win(buf)
  if win then
    vim.api.nvim_set_current_win(win)
    M.set_cursorline(win)
    M.render(buf)
    return
  end
  vim.cmd((opts().position == "right" and "botright " or "topleft ") .. width() .. "vnew")
  local scratch = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(0, buf)
  if scratch ~= buf and vim.api.nvim_buf_is_valid(scratch) then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end
  win = vim.api.nvim_get_current_win()
  local wo = vim.wo[win]
  M.set_cursorline(win)
  wo.number = false
  wo.relativenumber = false
  wo.wrap = false
  wo.winfixwidth = true
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  M.render(buf)
  local first = math.min(HEADER_LINES + 1, vim.api.nvim_buf_line_count(buf))
  vim.api.nvim_win_set_cursor(win, { first, 0 })
  M.update_cursor(buf)
end

---Close the sidebar window(s) in the current tab.
function M.close()
  local buf = sidebar_buf()
  local win = buf and sidebar_win(buf)
  if win then
    if #vim.api.nvim_tabpage_list_wins(0) == 1 then
      vim.cmd("enew")
    else
      vim.api.nvim_win_close(win, true)
    end
  end
end

M.HEADER_LINES = HEADER_LINES

return M
