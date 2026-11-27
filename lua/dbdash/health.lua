-- :checkhealth dbdash — the plugin itself. What a database needs (the SQLite library, CA
-- certificates, DNS) is checked by :checkhealth dbdash.<database>, e.g. dbdash.sqlite.
local M = {}

local DATABASES = { "sqlite", "postgres", "mysql", "redis", "mongodb", "cassandra", "mssql" }
M.DATABASES = DATABASES

function M.check()
  local health = vim.health
  local options = require("dbdash.options")

  health.start("Neovim")
  if vim.fn.has("nvim-0.12") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.12 or newer is required (found " .. tostring(vim.version()) .. ")")
  end
  if jit then
    health.ok(jit.version .. " (" .. jit.os .. "/" .. jit.arch .. ")")
  else
    health.error("LuaJIT is required (FFI for SQLite, bit operations for the protocols)")
  end
  for _, mod in ipairs({ "ffi", "bit" }) do
    if not pcall(require, mod) then
      health.error(("Lua module %q is not available"):format(mod))
    end
  end

  health.start("Setup")
  if #options.setup_errors == 0 then
    health.ok("setup() options are valid")
  else
    for _, e in ipairs(options.setup_errors) do
      health.warn(e, "The default is used for this option; see :help dbdash-setup")
    end
  end

  health.start("Passwords")
  local cred = require("dbdash.db.credentials")
  local file = cred.file()
  local st = vim.uv.fs_stat(file)
  if not st then
    health.info(file .. " does not exist; it is optional, see :help dbdash-passwords")
  else
    local data, err = cred.load_file()
    if err then
      health.error(err)
    else
      health.ok(("%s: %d entries"):format(file, vim.tbl_count(data or {})))
    end
    if jit.os ~= "Windows" and require("bit").band(st.mode, 63) ~= 0 then -- 0o077
      health.warn(file .. " can be read by other users", "chmod 600 " .. vim.fn.shellescape(file))
    end
  end

  health.start("Dashboards")
  local running = require("dbdash.scheduler").list()
  health.info(("%d running"):format(#running))
  health.info("Database requirements: :checkhealth " .. table.concat(
    vim.tbl_map(function(d)
      return "dbdash." .. d
    end, DATABASES),
    " "
  ) .. " (or :checkhealth dbdash* for all)")
end

return M
