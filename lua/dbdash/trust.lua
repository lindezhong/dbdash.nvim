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

---True when `path` may run. Asks when its trust is unknown; records Allow and Deny.
---@param path string
---@return boolean ok, string? why
function M.check(path)
  local state = M.state(path)
  if state == "allowed" then
    return true
  elseif state == "denied" then
    return false, "denied earlier (:trust to allow it)"
  end
  local answer = M.ask(path)
  if answer == "allow" then
    vim.secure.trust({ action = "allow", path = path })
    return true
  elseif answer == "deny" then
    vim.secure.trust({ action = "deny", path = path })
    return false, "denied"
  elseif answer == "view" then
    vim.cmd("sview " .. vim.fn.fnameescape(path))
    return false, "review it, then start it again"
  end
  return false, "not trusted yet"
end

return M
