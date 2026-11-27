-- `make deps`: install the development tools of scripts/tools.lua into deps/tools/.
-- Tools already installed are kept, so this works offline once done. Archives are checked
-- against their SHA-256 before they are unpacked.
--   nvim -l scripts/deps.lua
local tools = require("scripts.tools")

local function run(cmd, cwd)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return r.code == 0, (r.stderr or "") .. (r.stdout or "")
end

local function fail(msg)
  io.stderr:write("deps: " .. msg .. "\n")
  os.exit(1)
end

local function sha256(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return vim.fn.sha256(data)
end

---Unpack an archive into dir: tar reads tar.gz everywhere and zip where it is bsdtar
---(macOS, Windows); GNU tar cannot read zip, then unzip or python3 do.
local function unpack(archive, dir)
  local tries = { { "tar", "-xf", archive, "-C", dir } }
  if archive:match("%.zip$") then
    vim.list_extend(tries, {
      { "unzip", "-q", "-o", archive, "-d", dir },
      { "python3", "-I", "-m", "zipfile", "-e", archive, dir },
    })
  end
  local errors = {}
  for _, cmd in ipairs(tries) do
    if vim.fn.executable(cmd[1]) == 1 then
      local ok, out = run(cmd)
      if ok then
        return
      end
      errors[#errors + 1] = cmd[1] .. ": " .. vim.trim(out)
    end
  end
  fail(("cannot unpack %s (%s)"):format(archive, table.concat(errors, "; ")))
end

local function install(tool)
  local dir = tools.dir(tool)
  local tmp = dir .. ".tmp"
  vim.fn.delete(tmp, "rf")
  if tool.git then
    local ok, out =
      run({ "git", "clone", "-q", "--depth", "1", "--branch", tool.version, tool.git, tmp })
    if not ok then
      fail(("cannot clone %s %s: %s"):format(tool.git, tool.version, out))
    end
  else
    local asset = tool.assets[tools.platform]
    if not asset then
      fail(("%s has no build for %s"):format(tool.name, tools.platform))
    end
    local url, want = asset[1], asset[2]
    vim.fn.mkdir(tmp, "p")
    local archive = tmp .. "/" .. url:match("[^/]+$")
    local ok, out = run({ "curl", "-fsSL", "-o", archive, url })
    if not ok then
      fail(("cannot download %s: %s"):format(url, out))
    end
    local got = sha256(archive)
    if got ~= want then
      fail(("%s: SHA-256 is %s, expected %s"):format(url, got, want))
    end
    unpack(archive, tmp)
    os.remove(archive)
    local bin = tmp .. "/" .. tool.bin .. tools.exe
    if not vim.uv.fs_stat(bin) then
      fail(("%s: no %s in the archive"):format(url, tool.bin))
    end
    vim.uv.fs_chmod(bin, tonumber("755", 8))
  end
  assert(vim.uv.fs_rename(tmp, dir))
  print(("deps: %s %s installed"):format(tool.name, tool.version))
end

vim.fn.mkdir(tools.ROOT, "p")
for _, tool in ipairs(tools.tools) do
  if not tools.installed(tool) then
    install(tool)
  end
end
