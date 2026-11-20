-- Floating windows for SQL, arguments and status (design §3.5).
local M = {}

---Open a centered floating window.
---@param lines string[]
---@param opts { title: string?, filetype: string?, hl: table[]? }?
---@return integer win, integer buf
function M.open(lines, opts)
  opts = opts or {}
  local W = require("dbdash.util.width")
  local longest = 0
  for _, l in ipairs(lines) do
    longest = math.max(longest, W.width(l))
  end
  local width = math.max(60, math.min(longest + 4, 120))
  width = math.min(width, vim.o.columns - 4)
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  local ns = require("dbdash.view.buffer").ns
  for _, h in ipairs(opts.hl or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.row, h.col_s, { end_col = h.col_e, hl_group = h.group })
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

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
