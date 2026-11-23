-- :checkhealth dbdash and :checkhealth dbdash.<database>.
local dbdash = require("dbdash")
local cred = require("dbdash.db.credentials")
local eq = MiniTest.expect.equality
local real_notify = vim.notify -- restored after each case (nvim_notify needs 3 arguments)

local function remove_file()
  if vim.uv.fs_stat(cred.file()) then
    assert(vim.uv.fs_unlink(cred.file()))
  end
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.notify = function() end
      remove_file()
    end,
    post_case = function()
      vim.notify = real_notify
      dbdash.setup({})
      remove_file()
    end,
  },
})

---Run :checkhealth for `names` and return its report as one string.
local function check(names)
  vim.cmd("checkhealth " .. names)
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.cmd("bwipeout!")
  return text
end

local function has(text, s)
  return text:find(s, 1, true) ~= nil
end

T["dbdash: Neovim, LuaJIT, setup, passwords file, hints for databases"] = function()
  dbdash.setup({})
  local text = check("dbdash")
  eq(has(text, "OK Neovim 0.12"), true)
  eq(has(text, "OK LuaJIT"), true)
  eq(has(text, "OK setup() options are valid"), true)
  eq(has(text, "passwords.json does not exist"), true)
  eq(has(text, ":checkhealth dbdash.sqlite dbdash.postgres"), true)
  -- database checks are not part of :checkhealth dbdash
  eq(has(text, "SQLite library"), false)
  eq(has(text, "CA store"), false)
end

T["dbdash: setup() errors and passwords.json problems are reported"] = function()
  dbdash.setup({ sidebar = { width = "wide" } })
  vim.fn.mkdir(vim.fs.dirname(cred.file()), "p")
  vim.fn.writefile({ '{ "postgres://app@db": "pw" }' }, cred.file())
  vim.uv.fs_chmod(cred.file(), tonumber("644", 8))
  local text = check("dbdash")
  eq(has(text, "WARNING sidebar.width: invalid size"), true)
  eq(has(text, "passwords.json: 1 entries"), true)
  if jit.os ~= "Windows" then -- no Unix permissions to check there
    eq(has(text, "can be read by other users"), true)
    eq(has(text, "chmod 600"), true)
    vim.uv.fs_chmod(cred.file(), tonumber("600", 8))
    eq(has(check("dbdash"), "can be read by other users"), false)
  else
    eq(has(text, "can be read by other users"), false)
  end
  vim.fn.writefile({ "[" }, cred.file())
  vim.uv.fs_utime(cred.file(), os.time() + 5, os.time() + 5)
  eq(has(check("dbdash"), "ERROR"), true)
end

T["dbdash.sqlite: the library and its version, or how to install it"] = function()
  local text = check("dbdash.sqlite")
  eq(text:match("OK [^\n]*SQLite %d+%.%d+") ~= nil, true)
  local sqlite = require("dbdash.db.drivers.sqlite")
  local orig = sqlite.lib_candidates
  sqlite.lib_candidates = function()
    return { "/nonexistent/libsqlite3.so" }
  end
  text = check("dbdash.sqlite")
  sqlite.lib_candidates = orig
  eq(has(text, "ERROR cannot load the SQLite library"), true)
  eq(has(text, "database.options.lib_path"), true)
end

T["dbdash.<network database>: driver and CA store; mongodb also DNS"] = function()
  for _, db in ipairs({ "postgres", "mysql", "redis", "cassandra", "mssql", "mongodb" }) do
    local text = check("dbdash." .. db)
    eq({ db, has(text, "OK driver loads"), has(text, "CA store") }, { db, true, true })
    eq({ db, has(text, "DNS") }, { db, db == "mongodb" })
  end
  -- every database has a health module
  local text = check("dbdash*")
  for _, db in ipairs(require("dbdash.health").DATABASES) do
    eq({ db, has(text, "dbdash." .. db .. ":") }, { db, true })
  end
end

return T
