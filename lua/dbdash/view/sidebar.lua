-- Sidebar listing config files (design §3.4). Configured by setup({ sidebar = ... }).
local M = {}

local function opts()
  return require("dbdash").options.sidebar
end

local HEADER_LINES = 6
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

---Config files in `dir` matching sidebar.pattern and not sidebar.exclude (globs on the
---file name), as paths relative to `dir`, sorted. With sidebar.recursive, hidden
---directories are skipped.
---@param dir string
---@return string[]
function M.config_files(dir)
  local o = opts()
  local include, exclude = matcher(o.pattern), matcher(o.exclude)
  local out = {}
  local iter = vim.fs.dir(dir, {
    depth = o.recursive and 20 or 1,
    skip = function(name)
      return vim.fs.basename(name):sub(1, 1) ~= "."
    end,
  })
  for rel, kind in iter do
    local base = vim.fs.basename(rel)
    if (kind == "file" or kind == "link") and include(base) and not exclude(base) then
      out[#out + 1] = rel
    end
  end
  table.sort(out)
  return out
end

---Fill the sidebar buffer; the line -> file mapping is stored in b:dbdash_sidebar_files.
function M.render(buf)
  local sched = require("dbdash.scheduler")
  local dir = M.dir()
  local files = M.config_files(dir)
  local lines = {
    "DbDash Sidebar",
    "Directory: " .. vim.fn.fnamemodify(dir, ":~"),
    "",
    "▸ = Not running",
    "▾ = Running",
    "",
  }
  local mapping = {}
  for _, f in ipairs(files) do
    local path = vim.fs.joinpath(dir, f)
    lines[#lines + 1] = (sched.get(path) and "▾ " or "▸ ") .. f
    mapping[tostring(#lines)] = path
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.b[buf].dbdash_sidebar_files = mapping
  return #files, dir
end

---Re-render the sidebar if it exists (after dashboards start or stop).
function M.refresh()
  local buf = sidebar_buf()
  if buf then
    M.render(buf)
  end
end

local function selected(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return (vim.b[buf].dbdash_sidebar_files or {})[tostring(lnum)]
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
  local path = selected(buf)
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

---Open the sidebar (sidebar.position), or jump to it when already open.
function M.open()
  local dir = M.dir()
  if #M.config_files(dir) == 0 then
    vim.notify("No config files found in " .. dir, vim.log.levels.WARN)
    vim.cmd.edit(vim.fn.fnameescape(dir))
    return
  end
  local buf = sidebar_buf() or create_buf()
  apply_keys(buf)
  local win = sidebar_win(buf)
  if win then
    vim.api.nvim_set_current_win(win)
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
  wo.cursorline = true
  wo.number = false
  wo.relativenumber = false
  wo.wrap = false
  wo.winfixwidth = true
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  M.render(buf)
  local first = math.min(HEADER_LINES + 1, vim.api.nvim_buf_line_count(buf))
  vim.api.nvim_win_set_cursor(win, { first, 0 })
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
