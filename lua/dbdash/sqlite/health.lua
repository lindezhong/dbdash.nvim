-- :checkhealth dbdash.sqlite — the system SQLite library (loaded through LuaJIT FFI).
local M = {}

function M.check()
  local health = vim.health
  health.start("Driver")
  if not require("dbdash.health_util").driver("sqlite") then
    return
  end

  health.start("SQLite library")
  local ffi = require("ffi")
  pcall(ffi.cdef, "const char *sqlite3_libversion(void);")
  local candidates = require("dbdash.db.drivers.sqlite").lib_candidates()
  local errors = {}
  for _, name in ipairs(candidates) do
    local ok, lib = pcall(ffi.load, name)
    if ok then
      local vok, version = pcall(function()
        return ffi.string(lib.sqlite3_libversion())
      end)
      if vok then
        health.ok(("%s, SQLite %s"):format(name, version))
      else
        health.error(name .. " loads but is not SQLite: " .. tostring(version))
      end
      return
    end
    errors[#errors + 1] = tostring(lib)
  end
  local advice = jit.os == "Windows"
      and "Put sqlite3.dll (from https://sqlite.org/download.html) next to nvim.exe or on PATH, or set database.options.lib_path"
    or "Install the SQLite library (e.g. libsqlite3-0 / sqlite-libs), or set database.options.lib_path in the config"
  health.error(
    "cannot load the SQLite library (tried " .. table.concat(candidates, ", ") .. "): " .. table.concat(errors, "; "),
    advice
  )
end

return M
