-- luacheck on Neovim's LuaJIT: the luacheck and argparse sources from deps/tools, lfs from
-- scripts/lfs_shim.lua. Arguments are luacheck's.
--   nvim -l scripts/luacheck.lua lua tests plugin scripts
local tools = require("scripts.tools")

local luacheck = tools.dir(tools.get("luacheck"))
local argparse = tools.dir(tools.get("argparse"))
package.path = table.concat({
  luacheck .. "/src/?.lua",
  luacheck .. "/src/?/init.lua",
  argparse .. "/src/?.lua",
  package.path,
}, ";")
package.preload["lfs"] = function()
  return require("scripts.lfs_shim")
end

-- luacheck reads its arguments from `arg` (nvim -l sets it to this script's arguments).
_G.arg[0] = "luacheck"
require("luacheck.main")
