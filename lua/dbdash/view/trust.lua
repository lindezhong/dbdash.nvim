-- The View float of a config's trust prompt: every file it would run, `a` allows, `d`
-- denies (recorded in dbdash.trust), `q` closes without deciding.
local trust = require("dbdash.trust")

local M = {}

local KIND = { config = "config", lua = "Lua", template = "template with Lua" }

---The lines of the View float: the config first (the float's title names it), then every
---imported file after a separator line naming it; the separators' row numbers (0-based)
---for highlighting.
function M.lines(files, width)
  local lines, seps = {}, {}
  for _, f in ipairs(files) do
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    if f.kind ~= "config" then
      -- The file name centered in a line of ━ as wide as the float.
      local label = (" %s (%s) "):format(vim.fn.fnamemodify(f.path, ":~:."), KIND[f.kind])
      local fill = math.max(width - vim.fn.strdisplaywidth(label), 8)
      local left = math.floor(fill / 2)
      seps[#seps + 1] = #lines
      lines[#lines + 1] = ("━"):rep(left) .. label .. ("━"):rep(fill - left)
    end
    for _, l in ipairs(vim.split(f.text:gsub("\n$", ""), "\n", { plain = true })) do
      lines[#lines + 1] = l
    end
  end
  return lines, seps
end

---Show every file in a floating window where the user decides: `a` allows, `d` denies
---(both recorded), `q` / <Esc> close without deciding. `on_decided(answer)` gets "allow",
---"deny" or "cancel" once the window is closed.
function M.view(config_path, files, on_decided)
  local width = math.min(
    require("dbdash.util.size").resolve(
      require("dbdash.options").current.popup.max_width,
      vim.o.columns
    ),
    vim.o.columns - 4
  )
  local lines, seps = M.lines(files, width - 2)
  local win, buf = require("dbdash.view.popup").open(lines, {
    title = ("%s: Lua code - a allow, d deny, q close"):format(
      vim.fn.fnamemodify(config_path, ":t")
    ),
    filetype = "lua",
  })
  local ns = vim.api.nvim_create_namespace("dbdash_trust")
  for _, row in ipairs(seps) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "DbDashTrustFile" })
  end
  local decision = "cancel"
  local function decide(answer)
    decision = answer
    trust.record(config_path, answer, files)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for lhs, answer in pairs({ a = "allow", d = "deny" }) do
    vim.keymap.set("n", lhs, function()
      decide(answer)
    end, { buffer = buf, nowait = true, desc = "dbdash: " .. answer .. " this config" })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        on_decided(decision)
      end)
    end,
  })
  return win, buf
end

return M
