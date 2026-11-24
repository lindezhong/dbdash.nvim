-- Trust for configs that run Lua code. The unit of trust is a config: one question covers
-- all the Lua it runs - its own (lua:// queries, query.transform, {% lua %} blocks) and the
-- files it imports (.lua modules and templates with {% lua %} blocks). Decisions are stored
-- in stdpath("state")/dbdash/trust.json by the config's real path, with a fingerprint of
-- the config and those files: when any of them changes, the config is asked about again.
-- Configs sharing a .lua file are asked about separately.
local M = {}

---@class dbdash.trust.File
---@field path string absolute, normalized
---@field kind "config"|"lua"|"template"
---@field text string contents

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end
M.real = real

---True when template text contains a {% lua %} block.
function M.has_lua_block(text)
  return text:find("{%%%-?%s*lua%s*%-?%%}") ~= nil
end

---Targets of {% import '...' %} / {% from '...' import %} written as string literals.
function M.import_targets(text)
  local out = {}
  for kw, rest in text:gmatch("{%%%-?%s*(%a+)%s+(.-)%-?%%}") do
    if kw == "import" or kw == "from" then
      local target = rest:match("^'([^']*)'") or rest:match('^"([^"]*)"')
      if target then
        out[#out + 1] = target
      end
    end
  end
  return out
end

---Resolve an import target like the template loader: relative to the config's directory.
function M.resolve(base_dir, name)
  if name:match("^/") or name:match("^%a:[/\\]") then
    return vim.fs.normalize(name)
  end
  return vim.fs.normalize(vim.fs.joinpath(base_dir, name))
end

---The files whose Lua a config runs: the config itself (always first, as the unit of
---trust) and the .lua files and {% lua %} templates reachable through literal imports.
---@param path string config path
---@param cfg table loaded config
---@return dbdash.trust.File[] files, boolean has_lua
function M.collect(path, cfg)
  local cfg_text = read(path) or ""
  local files = { { path = real(path), kind = "config", text = cfg_text } }
  local has_lua = false
  local seen = {}
  local function visit(text)
    for _, target in ipairs(M.import_targets(text)) do
      local p = M.resolve(cfg.dir, target)
      if not seen[p] then
        seen[p] = true
        local t = read(p)
        if t then
          if p:match("%.lua$") then
            has_lua = true
            files[#files + 1] = { path = real(p), kind = "lua", text = t }
          else
            if M.has_lua_block(t) then
              has_lua = true
              files[#files + 1] = { path = real(p), kind = "template", text = t }
            end
            visit(t)
          end
        end
      end
    end
  end
  for _, p in ipairs(cfg.panels) do
    local q = p.query
    if p.database.type == "lua" or q.transform or M.has_lua_block(q.sql or "") or M.has_lua_block(q.transform or "") then
      has_lua = true
    end
    visit(q.sql or "")
    visit(q.transform or "")
  end
  table.sort(files, function(a, b)
    if (a.kind == "config") ~= (b.kind == "config") then
      return a.kind == "config"
    end
    return a.path < b.path
  end)
  return files, has_lua
end

---Fingerprint of the files (paths and contents).
function M.fingerprint(files)
  local parts = {}
  for _, f in ipairs(files) do
    parts[#parts + 1] = f.path .. "\0" .. vim.fn.sha256(f.text)
  end
  return vim.fn.sha256(table.concat(parts, "\n"))
end

-- The decisions file -------------------------------------------------------------------------

function M.file()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "dbdash", "trust.json")
end

local function load_db()
  local text = read(M.file())
  if not text or text == "" then
    return {}
  end
  local ok, db = pcall(vim.json.decode, text)
  return ok and type(db) == "table" and db or {}
end

local function save_db(db)
  local file = M.file()
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local tmp = file .. ".tmp"
  local f = assert(io.open(tmp, "wb"))
  f:write(vim.json.encode(db))
  f:close()
  assert(vim.uv.fs_rename(tmp, file))
end

local function file_hashes(files)
  local out = {}
  for _, f in ipairs(files) do
    out[f.path] = vim.fn.sha256(f.text)
  end
  return out
end

---Record a decision for a config: "allow" (for these files) | "deny" | "remove".
---@param config_path string
---@param action "allow"|"deny"|"remove"
---@param files dbdash.trust.File[]?
function M.record(config_path, action, files)
  local db = load_db()
  local key = real(config_path)
  if action == "remove" then
    db[key] = nil
  elseif action == "deny" then
    db[key] = { denied = true }
  else
    db[key] = { hash = M.fingerprint(files), files = file_hashes(files) }
  end
  save_db(db)
end

---"allowed" | "denied" | "unknown" (never asked, or one of the files is new or changed).
---The decision may cover more files than `files` (ones imported through a computed path).
function M.state(config_path, files)
  local e = load_db()[real(config_path)]
  if not e then
    return "unknown"
  elseif e.denied then
    return "denied"
  end
  for _, f in ipairs(files) do
    if not e.files or e.files[f.path] ~= vim.fn.sha256(f.text) then
      return "unknown"
    end
  end
  return "allowed"
end

---True when `path` (a .lua module or a template loaded while rendering) is part of the
---trusted files of the config, with the same contents.
function M.covers(config_path, path, text)
  local e = load_db()[real(config_path)]
  return e ~= nil and not e.denied and e.files ~= nil and e.files[real(path)] == vim.fn.sha256(text)
end

-- Asking -------------------------------------------------------------------------------------

local function names(files)
  local out = {}
  for _, f in ipairs(files) do
    out[#out + 1] = vim.fn.fnamemodify(f.path, ":~:.")
  end
  return table.concat(out, ", ")
end

---Ask the user (vim.fn.confirm). Returns "allow" | "view" | "deny" | "cancel".
---Replaceable in tests.
function M.ask(config_path, files)
  local ok, choice = pcall(
    vim.fn.confirm,
    ("dbdash: %s runs Lua code with your permissions, from: %s\nRun it?"):format(
      vim.fn.fnamemodify(config_path, ":~:."),
      names(files)
    ),
    "&Allow\n&View\n&Deny\n&Not now",
    4
  )
  if not ok then
    return "cancel"
  end
  return ({ "allow", "view", "deny" })[choice] or "cancel"
end

local KIND = { config = "config", lua = "Lua", template = "template with Lua" }

---The lines of the View float: every file after a separator line naming it; the
---separators' row numbers (0-based) for highlighting.
function M.view_lines(files, width)
  local lines, seps = {}, {}
  for _, f in ipairs(files) do
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    local label = (" %s (%s) "):format(vim.fn.fnamemodify(f.path, ":~:."), KIND[f.kind])
    local fill = math.max(width - vim.fn.strdisplaywidth(label) - 4, 4)
    seps[#seps + 1] = #lines
    lines[#lines + 1] = ("━━━━%s%s"):format(label, ("━"):rep(fill))
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
  local width = math.min(require("dbdash.util.size").resolve(require("dbdash").options.popup.max_width, vim.o.columns), vim.o.columns - 4)
  local lines, seps = M.view_lines(files, width - 2)
  local win, buf = require("dbdash.view.popup").open(lines, {
    title = ("%s: Lua code - a allow, d deny, q close"):format(vim.fn.fnamemodify(config_path, ":t")),
    filetype = "lua",
  })
  local ns = vim.api.nvim_create_namespace("dbdash_trust")
  for _, row in ipairs(seps) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "DbDashTrustFile" })
  end
  local decision = "cancel"
  local function decide(answer)
    decision = answer
    M.record(config_path, answer, files)
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

---True when the config may run with these files. Asks when its trust is unknown and
---records Allow and Deny. Otherwise returns false, a message and its level (viewing or
---"Not now" is not an error; no message while the files are being viewed).
---@param config_path string
---@param files dbdash.trust.File[]
---@param on_viewed fun(answer: "allow"|"deny"|"cancel")? the decision made in the View float
---@return boolean ok, string? message, integer? level
function M.check(config_path, files, on_viewed)
  local name = vim.fn.fnamemodify(config_path, ":~:.")
  local hint = (":DbDashTrust allow %s to allow it"):format(vim.fn.fnameescape(name))
  local state = M.state(config_path, files)
  if state == "allowed" then
    return true
  elseif state == "denied" then
    return false, ("%s was denied (%s)"):format(name, hint), vim.log.levels.WARN
  end
  local answer = M.ask(config_path, files)
  if answer == "allow" then
    M.record(config_path, "allow", files)
    return true
  elseif answer == "deny" then
    M.record(config_path, "deny")
    return false, ("%s denied; it will not run (%s)"):format(name, hint), vim.log.levels.WARN
  elseif answer == "view" then
    M.view(config_path, files, on_viewed or function() end)
    return false
  end
  return false, ("%s not started (not trusted yet)"):format(name), vim.log.levels.INFO
end

return M
