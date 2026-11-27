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
M.ACTIONS = {
  modify = { "modify_variable", "Modify an argument" },
  show_args = { "show_variables", "Show arguments" },
  refresh = { "restart", "Refresh now" },
  reset = { "reset_variables", "Reset arguments to defaults" },
  show_sql = { "show_sql", "Show the rendered query" },
  export = { "export", "Export the result" },
  describe = { "describe", "Show the description" },
}

---(Re)define the buffer keys from setup({ dashboard = { keys = ... } }).
function M.apply_keys(buf)
  for _, lhs in ipairs(vim.b[buf].dbdash_keys or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  local keys = require("dbdash.options").current.dashboard.keys
  local mapped = {}
  for action, def in pairs(M.ACTIONS) do
    local lhs = keys[action]
    if lhs then
      vim.keymap.set("n", lhs, function()
        -- an event at the cursor: hit test, then capture and bubble (events/); the
        -- default action listens on the document root
        local register = vim.v.register
        for _, d in ipairs(require("dbdash.dashboard").list()) do
          if d.buf == buf and d.doc then
            require("dbdash.events").at_cursor(d, action, { register = register })
            return
          end
        end
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

-- What each buffer shows (for the diff): row -> signature (text + highlights).
local shown = {}

---Counters of written rows (tests): stats[buf] = { rows = n, draws = n }.
M.stats = {}

local function add_marks(buf, list)
  for _, h in ipairs(list or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, h.row, h.col_s, {
      end_col = h.col_e,
      hl_group = h.group,
      priority = h.priority or 100, -- backgrounds (style.background) lie below
    })
  end
end

---Replace buffer content and highlights, writing only the rows that changed (the
---compositor's diff: unchanged lines keep their text and extmarks).
---@param buf integer
---@param lines string[]
---@param hl { row: integer, col_s: integer, col_e: integer, group: string, priority: integer? }[]
function M.draw(buf, lines, hl)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local by_row = {}
  for _, h in ipairs(hl) do
    by_row[h.row] = by_row[h.row] or {}
    table.insert(by_row[h.row], h)
  end
  local sig = {}
  for r = 0, #lines - 1 do
    local parts = { lines[r + 1] }
    for _, h in ipairs(by_row[r] or {}) do
      parts[#parts + 1] = ("%d:%d:%s:%s"):format(h.col_s, h.col_e, h.group, tostring(h.priority))
    end
    sig[r] = table.concat(parts, "\0")
  end
  local prev = shown[buf]
  local st = M.stats[buf] or { rows = 0, draws = 0 }
  M.stats[buf] = st
  st.draws = st.draws + 1
  vim.bo[buf].modifiable = true
  if not prev or prev.n ~= #lines or vim.api.nvim_buf_line_count(buf) ~= #lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    add_marks(buf, hl)
    st.rows = st.rows + #lines
  else
    local r = 0
    while r < #lines do
      if sig[r] ~= prev.sig[r] then
        local e = r
        while e + 1 < #lines and sig[e + 1] ~= prev.sig[e + 1] do
          e = e + 1
        end
        vim.api.nvim_buf_set_lines(buf, r, e + 1, false, { unpack(lines, r + 1, e + 1) })
        vim.api.nvim_buf_clear_namespace(buf, M.ns, r, e + 1)
        for row = r, e do
          add_marks(buf, by_row[row])
        end
        st.rows = st.rows + (e - r + 1)
        r = e + 1
      else
        r = r + 1
      end
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  shown[buf] = { n = #lines, sig = sig }
end

---Forget what a buffer shows (its next draw writes everything).
function M.forget(buf)
  shown[buf] = nil
end

---@class dbdash.view.buffer.Status
---@field header string?
---@field countdown string?
---@field row integer?
---@field error string?
---@field position string?
---@field panels { row: integer, col: integer, text: string }[]?
---@field countdown_hl string?
---@field error_hl string?

---Countdown and error display.
---`header`: the global countdown, right-aligned on the first line (the header).
---Single panel: `countdown` on line `row` (the first after the header) and `error` as
---virtual lines above it.
---Multiple panels: `panels` lists { row, col, text } marks at fixed window columns.
---@param buf integer
---@param status dbdash.view.buffer.Status
function M.set_status(buf, status)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns_status, 0, -1)
  -- colors come from the computed styles of `countdown` and `error` (css)
  local cd_hl, err_hl = status.countdown_hl or "DbDashCountdown", status.error_hl or "DbDashError"
  if status.header then
    vim.api.nvim_buf_set_extmark(buf, M.ns_status, 0, 0, {
      virt_text = { { status.header, cd_hl } },
      virt_text_pos = "right_align",
      priority = 200,
    })
  end
  if status.panels then
    local last = vim.api.nvim_buf_line_count(buf) - 1
    for _, m in ipairs(status.panels) do
      if m.row <= last then
        vim.api.nvim_buf_set_extmark(buf, M.ns_status, m.row, 0, {
          virt_text = { { m.text, cd_hl } },
          virt_text_win_col = math.max(0, m.col),
          priority = 200,
        })
      end
    end
    return
  end
  local row = math.min(status.row or 0, vim.api.nvim_buf_line_count(buf) - 1)
  if status.countdown then
    vim.api.nvim_buf_set_extmark(buf, M.ns_status, row, 0, {
      virt_text = { { status.countdown, cd_hl } },
      virt_text_pos = status.position or "right_align",
      priority = 200,
    })
  end
  if status.error then
    local vl = {}
    for line in (status.error .. "\n"):gmatch("([^\n]*)\n") do
      vl[#vl + 1] = { { (#vl == 0 and "✗ " or "  ") .. line, err_hl } }
    end
    vim.api.nvim_buf_set_extmark(buf, M.ns_status, row, 0, {
      virt_lines = vl,
      virt_lines_above = true,
      priority = 200,
    })
    -- Lines above the first buffer line are only visible with topfill.
    for _, win in ipairs(row == 0 and vim.fn.win_findbuf(buf) or {}) do
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
