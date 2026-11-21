-- Dashboard buffer (design §3.3): scratch buffer named dbdash://<abs path>, content written
-- with extmark highlights; countdown and errors are extmarks, never buffer text.
local M = {}

M.ns = vim.api.nvim_create_namespace("dbdash")
M.ns_status = vim.api.nvim_create_namespace("dbdash_status")

local PREFIX = "dbdash://"

---@param path string absolute config path
function M.name(path)
  return PREFIX .. path
end

---Config path from a buffer name, or nil.
---@param name string
---@return string?
function M.path_of(name)
  local p = name:sub(1, #PREFIX) == PREFIX and name:sub(#PREFIX + 1) or nil
  return p ~= "" and p or nil
end

---Existing buffer with exactly this name.
local function find(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
end

-- dashboard.keys action -> command function and description.
local ACTIONS = {
  modify = { "modify_variable", "Modify an argument" },
  show_args = { "show_variables", "Show arguments" },
  refresh = { "restart", "Refresh now" },
  reset = { "reset_variables", "Reset arguments to defaults" },
  show_sql = { "show_sql", "Show the rendered query" },
  export = { "export", "Export the result" },
}

---(Re)define the buffer keys from setup({ dashboard = { keys = ... } }).
function M.apply_keys(buf)
  for _, lhs in ipairs(vim.b[buf].dbdash_keys or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  local keys = require("dbdash").options.dashboard.keys
  local mapped = {}
  for action, def in pairs(ACTIONS) do
    local lhs = keys[action]
    if lhs then
      vim.keymap.set("n", lhs, function()
        if action == "export" then
          return require("dbdash.commands").export({}, false, vim.v.register) -- "xe: register x
        end
        require("dbdash.commands")[def[1]]()
      end, { buffer = buf, nowait = true, silent = true, desc = "dbdash: " .. def[2] })
      mapped[#mapped + 1] = lhs
    end
  end
  vim.b[buf].dbdash_keys = mapped
end

---Create (or adopt) the buffer for a dashboard.
---@param path string
---@param buf integer? buffer to adopt (session restore, :edit dbdash://...)
---@return integer buf
function M.create(path, buf)
  local name = M.name(path)
  buf = buf or find(name)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  local bo = vim.bo[buf]
  -- A normal buffer, not nofile/acwrite: :mksession treats those as having no file name
  -- and skips their windows unless 'sessionoptions' has "blank" (often removed). Reads and
  -- writes of dbdash://* go to BufReadCmd / a no-op BufWriteCmd (plugin/dbdash.lua).
  bo.buftype = ""
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.buflisted = true
  bo.modifiable = false
  bo.modified = false
  bo.filetype = "dbdash"
  vim.b[buf].dbdash_path = path
  M.apply_keys(buf)
  return buf
end

---Replace buffer content and highlights.
---@param buf integer
---@param lines string[]
---@param hl { row: integer, col_s: integer, col_e: integer, group: string }[]
function M.draw(buf, lines, hl)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, h.row, h.col_s, {
      end_col = h.col_e,
      hl_group = h.group,
      priority = 100,
    })
  end
end

---Countdown and error display.
---Single panel: `countdown` on the first line and `error` as virtual lines above it.
---Multiple panels: `panels` lists { row, col, text } marks at fixed window columns.
---@param buf integer
---@param status { countdown: string?, error: string?, position: string?, panels: { row: integer, col: integer, text: string }[]? }
function M.set_status(buf, status)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns_status, 0, -1)
  if status.panels then
    local last = vim.api.nvim_buf_line_count(buf) - 1
    for _, m in ipairs(status.panels) do
      if m.row <= last then
        vim.api.nvim_buf_set_extmark(buf, M.ns_status, m.row, 0, {
          virt_text = { { m.text, "DbDashCountdown" } },
          virt_text_win_col = math.max(0, m.col),
          priority = 200,
        })
      end
    end
    return
  end
  if status.countdown then
    vim.api.nvim_buf_set_extmark(buf, M.ns_status, 0, 0, {
      virt_text = { { status.countdown, "DbDashCountdown" } },
      virt_text_pos = status.position or "right_align",
      priority = 200,
    })
  end
  if status.error then
    local vl = {}
    for line in (status.error .. "\n"):gmatch("([^\n]*)\n") do
      vl[#vl + 1] = { { (#vl == 0 and "✗ " or "  ") .. line, "DbDashError" } }
    end
    vim.api.nvim_buf_set_extmark(buf, M.ns_status, 0, 0, {
      virt_lines = vl,
      virt_lines_above = true,
      priority = 200,
    })
    -- Lines above the first buffer line are only visible with topfill.
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        if view.topline == 1 then
          view.topfill = #vl
          vim.fn.winrestview(view)
        end
      end)
    end
  end
end

---Text area size of the windows showing `buf` (smallest), or the editor size.
---@return integer width, integer height
function M.size(buf)
  local w, h
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    local ww = info.width - info.textoff
    w = w and math.min(w, ww) or ww
    h = h and math.min(h, info.height) or info.height
  end
  return w or vim.o.columns, h or (vim.o.lines - 2)
end

return M
