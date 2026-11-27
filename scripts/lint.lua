-- `make lint` / `make fmt`: StyLua (format), luacheck (static checks) and
-- lua-language-server (types) on the repository, with the tools of scripts/tools.lua.
--   nvim -l scripts/lint.lua          check everything; exits 1 on a problem
--   nvim -l scripts/lint.lua fmt      format with StyLua
local tools = require("scripts.tools")

local PATHS = { "lua", "tests", "plugin", "scripts" }

local function say(text)
  io.stdout:write(text, "\n")
end

-- lua-language-server findings fail the check from Warning up.
local LUALS_BLOCKING = false

local function run(cmd, env)
  local r = vim.system(cmd, { text = true, env = env }):wait()
  return r.code, (r.stdout or "") .. (r.stderr or "")
end

local function need(name)
  local tool = tools.get(name)
  if not tools.installed(tool) then
    io.stderr:write(("lint: %s is not installed; run make deps\n"):format(name))
    os.exit(1)
  end
  return tool
end

local function stylua(check)
  local cmd = { tools.bin(need("stylua")) }
  if check then
    cmd[#cmd + 1] = "--check"
  end
  vim.list_extend(cmd, PATHS)
  return run(cmd)
end

local function luacheck()
  need("luacheck")
  need("argparse")
  local cmd =
    { vim.v.progpath, "-l", "scripts/luacheck.lua", "--formatter", "plain", "--codes", "--quiet" }
  vim.list_extend(cmd, PATHS)
  return run(cmd)
end

---lua-language-server --check: its findings as "file:line:col: [code] message" lines.
local function luals()
  local log = vim.fn.tempname()
  -- .luarc.json reads Neovim's runtime library from $VIMRUNTIME.
  local code, out = run({
    tools.bin(need("lua-language-server")),
    "--check=.",
    "--checklevel=Warning",
    "--check_format=json",
    "--logpath=" .. log,
  }, { VIMRUNTIME = vim.env.VIMRUNTIME })
  local f = io.open(log .. "/check.json")
  if not f then
    return code ~= 0 and code or 0, code ~= 0 and out or ""
  end
  local found = vim.json.decode(f:read("*a"))
  f:close()
  vim.fn.delete(log, "rf")
  local lines = {}
  for uri, diags in pairs(found) do
    local path = vim.fn.fnamemodify(vim.uri_to_fname(uri), ":.")
    for _, d in ipairs(diags) do
      local s = d.range.start
      lines[#lines + 1] = ("%s:%d:%d: [%s] %s"):format(
        path,
        s.line + 1,
        s.character + 1,
        d.code,
        d.message:gsub("\n", " ")
      )
    end
  end
  table.sort(lines)
  return #lines > 0 and 1 or 0, table.concat(lines, "\n")
end

if arg[1] == "fmt" then
  -- StyLua may need more than one pass to settle (a call it rewraps can then fit).
  for _ = 1, 5 do
    local code, out = stylua(false)
    if code ~= 0 then
      io.write(out)
      os.exit(code)
    end
    if stylua(true) == 0 then
      os.exit(0)
    end
  end
  io.stderr:write("lint: StyLua did not settle after 5 passes\n")
  os.exit(1)
end

local failed = false
for _, step in ipairs({
  {
    "stylua",
    function()
      return stylua(true)
    end,
    true,
  },
  { "luacheck", luacheck, true },
  { "lua-language-server", luals, LUALS_BLOCKING },
}) do
  local name, fn, blocking = step[1], step[2], step[3]
  local code, out = fn()
  if code == 0 then
    say(("lint: %s ok"):format(name))
  elseif blocking then
    failed = true
    say(("lint: %s found problems:\n%s"):format(name, vim.trim(out)))
  else
    local n = select(2, out:gsub("\n", "")) + 1
    say(("lint: %s: %d problems (not blocking yet)"):format(name, n))
  end
end
os.exit(failed and 1 or 0)
