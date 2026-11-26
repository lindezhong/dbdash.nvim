-- An interpreter for exec:// tests that works everywhere: nvim -l run_lua.lua <code>
-- runs <code> (Lua) with stdout / stderr as the script's.
local code = assert(_G.arg[1], "no code")
local fn = assert(loadstring(code))
local ok, err = pcall(fn)
if not ok then
  io.stderr:write(tostring(err), "\n")
  os.exit(3)
end
