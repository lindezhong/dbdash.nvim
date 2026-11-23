-- Trust for configs that run Lua code (lua:// or query.transform). Decisions live in
-- Neovim's trust database (stdpath("state")/trust, the one :trust and 'exrc' use), keyed by
-- the file's real path and the SHA-256 of its contents: an edited file is asked about again.
-- The question is dbdash's own: vim.secure.read() speaks of exrc and cannot allow a file.
local M = {}

---"allowed" | "denied" | "unknown" (never asked, or changed since it was allowed).
---@param path string
function M.state(path)
  local full = vim.uv.fs_realpath(path)
  if not full then
    return "unknown"
  end
  local db = {}
  local f = io.open(vim.fs.joinpath(vim.fn.stdpath("state"), "trust"), "r")
  if f then
    for line in f:lines() do
      local hash, file = line:match("^(%S+) (.+)$")
      if hash then
        db[file] = hash
      end
    end
    f:close()
  end
  local entry = db[full]
  if entry == "!" then
    return "denied"
  end
  local cf = io.open(full, "rb")
  if not cf then
    return "unknown"
  end
  local contents = cf:read("*a")
  cf:close()
  return entry == vim.fn.sha256(contents) and "allowed" or "unknown"
end

---Ask the user (vim.fn.confirm). Returns "allow" | "view" | "deny" | "cancel".
---Replaceable in tests.
function M.ask(path)
  local ok, choice = pcall(
    vim.fn.confirm,
    ("dbdash: %s contains Lua code (lua:// or query.transform) that runs with your permissions.\nRun it?"):format(
      vim.fn.fnamemodify(path, ":~:.")
    ),
    "&Allow\n&View\n&Deny\n&Not now",
    4
  )
  if not ok then
    return "cancel"
  end
  return ({ "allow", "view", "deny" })[choice] or "cancel"
end

---Show the config read-only in a floating window where the user decides: `a` allows,
---`d` denies (both recorded), `q` / <Esc> close without deciding. `on_decided(answer)`
---gets "allow", "deny" or "cancel" once the window is closed.
function M.view(path, on_decided)
  local lines = vim.fn.readfile(path)
  local win, buf = require("dbdash.view.popup").open(lines, {
    title = ("%s: Lua code - a allow, d deny, q close"):format(vim.fn.fnamemodify(path, ":t")),
    filetype = "yaml",
  })
  vim.wo[win].number = true
  local decision = "cancel"
  local function decide(answer)
    decision = answer
    vim.secure.trust({ action = answer, path = path })
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

---True when `path` may run. Asks when its trust is unknown; records Allow and Deny.
---Otherwise returns false, a message for the user and its level (viewing the file or
---answering "Not now" is not an error; no message while the file is being viewed).
---@param path string
---@param on_viewed fun(answer: "allow"|"deny"|"cancel")? the decision made in the View float
---@return boolean ok, string? message, integer? level
function M.check(path, on_viewed)
  local name = vim.fn.fnamemodify(path, ":~:.")
  local hint = (":trust %s to allow it"):format(vim.fn.fnameescape(name))
  local state = M.state(path)
  if state == "allowed" then
    return true
  elseif state == "denied" then
    return false, ("%s was denied (%s)"):format(name, hint), vim.log.levels.WARN
  end
  local answer = M.ask(path)
  if answer == "allow" then
    vim.secure.trust({ action = "allow", path = path })
    return true
  elseif answer == "deny" then
    vim.secure.trust({ action = "deny", path = path })
    return false, ("%s denied; it will not run (%s)"):format(name, hint), vim.log.levels.WARN
  elseif answer == "view" then
    -- Read it in a float and decide there (no message now; on_viewed reports).
    M.view(path, on_viewed or function() end)
    return false
  end
  return false, ("%s not started (not trusted yet)"):format(name), vim.log.levels.INFO
end

return M
