-- Sidebar listing config files in the current directory (design §3.4).
local M = {}

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

---Config files (*.yaml, *.yml) in `dir`, sorted, not recursive.
function M.config_files(dir)
  local out = {}
  for name, kind in vim.fs.dir(dir) do
    if (kind == "file" or kind == "link") and (name:match("%.ya?ml$")) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---Fill the sidebar buffer; the line -> file mapping is stored in b:dbdash_sidebar_files.
function M.render(buf)
  local sched = require("dbdash.scheduler")
  local dir = vim.fs.normalize(vim.fn.getcwd())
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

---A window to the right of the sidebar for dashboards (created if needed).
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
  vim.cmd("rightbelow vnew")
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(side_win)
  vim.cmd("vertical resize 30")
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
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, function()
      fn(buf)
    end, { buffer = buf, nowait = true, silent = true })
  end
  map("<CR>", on_enter)
  map("t", on_stop)
  map("r", on_refresh)
  map("q", function()
    M.close()
  end)
  return buf
end

---Open the sidebar on the left, or jump to it when already open.
function M.open()
  local dir = vim.fn.getcwd()
  if #M.config_files(dir) == 0 then
    vim.notify("No config files found in " .. dir, vim.log.levels.WARN)
    vim.cmd.edit(vim.fn.fnameescape(dir))
    return
  end
  local buf = sidebar_buf() or create_buf()
  local win = sidebar_win(buf)
  if win then
    vim.api.nvim_set_current_win(win)
    M.render(buf)
    return
  end
  vim.cmd("topleft 30vnew")
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
