-- The part of LuaFileSystem (lfs) that luacheck uses, on vim.uv: luacheck runs on Neovim's
-- LuaJIT (scripts/luacheck.lua) without the lfs C module.
local uv = vim.uv

local M = { _VERSION = "LuaFileSystem 1.8.0 (vim.uv shim)" }

local MODES = { file = "file", directory = "directory", link = "link" }

function M.attributes(path, what)
  local st, err = uv.fs_stat(path)
  if not st then
    return nil, err
  end
  local attrs = { mode = MODES[st.type] or st.type, modification = st.mtime.sec, size = st.size }
  if what then
    return attrs[what]
  end
  return attrs
end

function M.dir(path)
  local handle, err = uv.fs_scandir(path)
  if not handle then
    error("cannot open " .. path .. ": " .. tostring(err))
  end
  local entries, i = { ".", ".." }, 0
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    entries[#entries + 1] = name
  end
  return function()
    i = i + 1
    return entries[i]
  end
end

function M.mkdir(path)
  local ok, err = uv.fs_mkdir(path, tonumber("755", 8))
  if not ok then
    return nil, err
  end
  return true
end

function M.currentdir()
  return uv.cwd()
end

return M
