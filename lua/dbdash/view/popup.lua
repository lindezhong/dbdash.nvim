-- Floating windows for SQL, arguments and status (ARCHITECTURE.md#drawing).
local M = {}

---Set the filetype of a float's buffer. The built-in lua and markdown filetype plugins start
---treesitter and fail when Neovim has no parser for the language (seen on Windows); such an
---error in a FileType autocmd is only printed, it cannot be caught. So without a parser
---the filetype is set with FileType ignored and the Vim syntax highlights the text;
---with one, FileType runs as usual (filetype plugins, the user's autocmds).
local function set_filetype(buf, ft)
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local ok, has_parser = pcall(vim.treesitter.language.add, lang)
  if ok and has_parser then
    vim.bo[buf].filetype = ft
    return
  end
  local ei = vim.o.eventignore
  vim.o.eventignore = "FileType"
  pcall(function()
    vim.bo[buf].filetype = ft
  end)
  vim.o.eventignore = ei
  vim.bo[buf].syntax = ft
end
M.set_filetype = set_filetype

---Open a centered floating window.
---@param lines string[]
---@param opts { title: string?, filetype: string?, hl: table[]?, markdown: boolean? }?
---  markdown: wrapped text at most 80 columns wide, highlighted (treesitter) and concealed
---@return integer win, integer buf
function M.open(lines, opts)
  opts = opts or {}
  local W = require("dbdash.util.width")
  local longest = 0
  for _, l in ipairs(lines) do
    longest = math.max(longest, W.width(l))
  end
  local o = require("dbdash.options").current.popup
  local size = require("dbdash.util.size")
  -- Fit the content, within popup.max_width / max_height and the editor.
  local max_w = math.min(size.resolve(o.max_width, vim.o.columns), vim.o.columns - 4)
  local max_h = math.min(size.resolve(o.max_height, vim.o.lines), vim.o.lines - 6)
  local width = math.max(1, math.min(math.max(60, longest + 4), max_w))
  local rows = #lines
  if opts.markdown then
    width = math.max(1, math.min(80, max_w))
    rows = 0
    for _, l in ipairs(lines) do
      rows = rows + math.max(1, math.ceil(W.width(l) / width))
    end
  end
  local height = math.max(1, math.min(rows, max_h))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  if opts.markdown or opts.filetype then
    set_filetype(buf, opts.markdown and "markdown" or opts.filetype)
  end
  local ns = require("dbdash.view.buffer").ns
  for _, h in ipairs(opts.hl or {}) do
    pcall(
      vim.api.nvim_buf_set_extmark,
      buf,
      ns,
      h.row,
      h.col_s,
      { end_col = h.col_e, hl_group = h.group }
    )
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = o.border,
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  if opts.markdown then
    local wo = vim.wo[win]
    wo.wrap, wo.linebreak, wo.breakindent = true, true, true
    wo.conceallevel, wo.concealcursor = 2, "n"
    wo.cursorline = false
    -- Neovim ships the markdown parsers; the markdown syntax is the fallback.
    if not pcall(vim.treesitter.start, buf, "markdown") then
      vim.bo[buf].syntax = "markdown"
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", close)
  map("<Esc>", close)
  map("y", function()
    local text = table.concat(lines, "\n")
    vim.fn.setreg('"', text)
    if vim.fn.has("clipboard") == 1 then
      pcall(vim.fn.setreg, "+", text)
    end
    close()
  end)
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
  return win, buf
end

return M
