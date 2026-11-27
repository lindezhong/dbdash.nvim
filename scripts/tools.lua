-- Development tools (formatter, linter, type checker): pinned versions, installed into
-- deps/tools/ by `make deps` (scripts/deps.lua) and run by `make lint` (scripts/lint.lua).
-- Nothing is installed on the system: downloads need git, curl and tar (or unzip or
-- python3 for zip files where tar cannot read them, as GNU tar).
local M = {}

M.ROOT = "deps/tools"

local uname = vim.uv.os_uname()
local os_name = uname.sysname == "Darwin" and "macos"
  or (uname.sysname:match("^Windows") and "windows")
  or uname.sysname:lower()
local arch = (uname.machine == "arm64" or uname.machine == "aarch64") and "arm64" or "x64"
M.platform = os_name .. "-" .. arch
M.exe = os_name == "windows" and ".exe" or ""

---Release archives per platform: { url, sha256 }.
---@class dbdash.tools.Tool
---@field name string
---@field version string
---@field git string? a repository cloned at the version tag (pure Lua)
---@field assets table<string, { [1]: string, [2]: string }>? platform -> url, sha256
---@field bin string? the program inside the install directory

local STYLUA = "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.6.0/stylua-"
local LUALS = "https://github.com/LuaLS/lua-language-server/releases/download/3.19.2/"
  .. "lua-language-server-3.19.2-"

---@type dbdash.tools.Tool[]
M.tools = {
  {
    name = "stylua",
    version = "2.6.0",
    bin = "stylua",
    assets = {
      ["linux-x64"] = {
        STYLUA .. "linux-x86_64-musl.zip",
        "48ee7db28346f96f4bd545e190ab080a88a7b5a664e97649cf5d5c60426f402d",
      },
      ["linux-arm64"] = {
        STYLUA .. "linux-aarch64-musl.zip",
        "278495597e3827417f3af7b9ad38011ad4a5ec725503553160ab69b7301059bb",
      },
      ["macos-x64"] = {
        STYLUA .. "macos-x86_64.zip",
        "90779aa873837b2dff8eb3361bd27950303914c24265a59cae0a0d0629d71585",
      },
      ["macos-arm64"] = {
        STYLUA .. "macos-aarch64.zip",
        "dab9b66d340ca5ffc8225211f1dcf89b84783e09b8cbec8c518497eba81f3c42",
      },
      ["windows-x64"] = {
        STYLUA .. "windows-x86_64.zip",
        "fd13b4014e3b779c244bbc03f2c282e357f15bc526de6a6fa5ecbc447538313c",
      },
    },
  },
  {
    name = "lua-language-server",
    version = "3.19.2",
    bin = "bin/lua-language-server",
    assets = {
      ["linux-x64"] = {
        LUALS .. "linux-x64.tar.gz",
        "93ad326b10f6c00911dd8c450fa098332dbd8f9f45d1052f5636a2d54479b947",
      },
      ["linux-arm64"] = {
        LUALS .. "linux-arm64.tar.gz",
        "17b8e401a874440adeb649e5024c364f2bb9d15156c74a40e56d1ae9a1b2e4f2",
      },
      ["macos-x64"] = {
        LUALS .. "darwin-x64.tar.gz",
        "6f2174ece5ec63bcd9d5b22b2c902445c1cd9045fafe48c62602448ebf4c09cc",
      },
      ["macos-arm64"] = {
        LUALS .. "darwin-arm64.tar.gz",
        "79149584320a23bd5fcd5bc31f47a1975acd8a4560a0e89036bb1016fa61687f",
      },
      ["windows-x64"] = {
        LUALS .. "win32-x64.zip",
        "4a3dc851b3b31e7b75a23f645d1ba4a2137579a55f5fa4edbb17a3e2a6254044",
      },
    },
  },
  { name = "luacheck", version = "v1.2.0", git = "https://github.com/lunarmodules/luacheck" },
  { name = "argparse", version = "0.7.2", git = "https://github.com/luarocks/argparse" },
}

---@param name string
---@return dbdash.tools.Tool
function M.get(name)
  for _, t in ipairs(M.tools) do
    if t.name == name then
      return t
    end
  end
  error("unknown tool " .. name)
end

---The install directory of a tool (its version is part of the name).
function M.dir(tool)
  return ("%s/%s-%s"):format(M.ROOT, tool.name, tool.version)
end

---The program of a tool, or nil when it has none.
function M.bin(tool)
  return tool.bin and (M.dir(tool) .. "/" .. tool.bin .. M.exe) or nil
end

---Installed: the install directory exists (it is created last, by a rename).
function M.installed(tool)
  return vim.uv.fs_stat(M.dir(tool)) ~= nil
end

return M
