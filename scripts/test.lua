-- `make test` / `make it`: the tests (mini.test) in a Neovim of their own, with their own
-- data, state and cache directories (not the user's passwords.json, shada...). Works the
-- same from a POSIX shell, cmd.exe and PowerShell.
--   nvim -l scripts/test.lua [--it] [FILE]   --it: the integration tests too (DBDASH_IT)
local it, file = false, ""
for _, a in ipairs(arg) do
  if a == "--it" then
    it = true
  else
    file = a
  end
end

local root = vim.fs.normalize(vim.uv.cwd())
local env = {
  XDG_DATA_HOME = root .. "/deps/xdg/data",
  XDG_STATE_HOME = root .. "/deps/xdg/state",
  XDG_CACHE_HOME = root .. "/deps/xdg/cache",
}
if it then
  env.DBDASH_IT = "1"
end

local function pass(stream)
  return function(_, data)
    if data then
      stream:write(data)
    end
  end
end

local cmd = {
  vim.v.progpath,
  "--headless",
  "--noplugin",
  "-u",
  "tests/minimal_init.lua",
  "-c",
  ("lua require('tests.runner').run(%q)"):format(file),
}
local r = vim.system(cmd, { env = env, stdout = pass(io.stdout), stderr = pass(io.stderr) }):wait()
os.exit(r.code)
