-- An interpreter for exec:// that works wherever Neovim does (example/push/push.yaml):
--   interpreter: ["nvim", "--clean", "-l", "modules/run.lua"]
-- runs the script (query.sql, Lua) with stdout and stderr as its output.
local code = assert(_G.arg[1], "no script")
local fn = assert(loadstring(code, "=query.sql"))
local ok, err = pcall(fn)
if not ok then
  io.stderr:write(tostring(err), "\n")
  os.exit(3)
end
