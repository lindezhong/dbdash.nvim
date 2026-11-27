-- Passwords outside config files: ${ENV}, password_cmd, passwords.json.
local cred = require("dbdash.db.credentials")
local url = require("dbdash.db.url")
local async = require("dbdash.util.async")
local h = require("tests.helpers")
local eq = MiniTest.expect.equality

local file
local function remove_file()
  if vim.uv.fs_stat(file) then
    assert(vim.uv.fs_unlink(file))
  end
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      file = cred.file()
      vim.fn.mkdir(vim.fs.dirname(file), "p")
      remove_file()
    end,
    post_case = remove_file,
  },
})

local function run(fn)
  local res
  async.run(fn, function(err, ...)
    res = { err = err, ... }
  end)
  vim.wait(10000, function()
    return res ~= nil
  end, 5)
  return res
end

T["the data directory is isolated from the user's"] = function()
  local xdg = vim.fs.normalize(assert(vim.env.XDG_DATA_HOME))
  eq(vim.startswith(vim.fs.normalize(file), xdg), true)
  eq(xdg:find("/deps/xdg", 1, true) ~= nil, true)
end

T["${ENV} expands, percent-encodes URL characters, $${ stays literal"] = function()
  vim.uv.os_setenv("DBDASH_T_PW", "p@ss:w/rd")
  eq(cred.expand_env("postgres://u:${DBDASH_T_PW}@h/db"), "postgres://u:p%40ss%3Aw%2Frd@h/db")
  eq(url.parse(assert(cred.expand_env("postgres://u:${DBDASH_T_PW}@h/db"))).password, "p@ss:w/rd")
  eq(cred.expand_env("x$${HOME}y"), "x${HOME}y")
  local v, err = cred.expand_env("postgres://u:${DBDASH_T_UNSET}@h/db")
  eq({ v, err }, { nil, "environment variable DBDASH_T_UNSET is not set" })
  vim.uv.os_unsetenv("DBDASH_T_PW")
end

T["passwords.json: most specific key first"] = function()
  vim.fn.writefile({
    vim.json.encode({
      ["postgres://app@db:5432/shop"] = "shop-pw",
      ["postgres://app@db:5432"] = "port-pw",
      ["postgres://app@db"] = "host-pw",
      ["redis://cache:6379"] = "redis-pw",
    }),
  }, file)
  local function pw(raw)
    local info = url.parse(raw)
    info.port = info.port or 5432
    return cred.from_file(info)
  end
  eq(pw("postgres://app@db/shop"), "shop-pw")
  eq(pw("postgres://app@db/other"), "port-pw")
  eq(pw("postgres://app@db:6543/other"), "host-pw")
  eq(pw("postgres://bob@db/shop"), nil)
  local r = url.parse("redis://cache/0")
  r.port = 6379
  eq(cred.from_file(r), "redis-pw")
  -- changes are picked up (mtime), invalid files are reported
  vim.fn.writefile({ "[1, 2]" }, file)
  vim.uv.fs_utime(file, os.time() + 5, os.time() + 5)
  eq(pcall(pw, "postgres://app@db/shop"), false)
end

local WIN = jit.os == "Windows"

T["password_cmd: output is the password, cached, failures reported"] = function()
  local count = vim.fn.tempname()
  -- string commands run through sh -c, on Windows through cmd /c
  local cmd = WIN and ("echo x>>%s& echo secret& echo ignored"):format(count)
    or ("echo x >> %s; printf 'secret\\nignored'"):format(count)
  local info = url.parse("postgres://app@db/shop")
  local r = run(function()
    return cred.from_cmd(cmd, info), cred.from_cmd(cmd, info)
  end)
  eq({ r.err, r[1], r[2] }, { nil, "secret", "secret" })
  eq(#vim.fn.readfile(count), 1) -- second call used the cache
  cred.forget(cmd, info)
  run(function()
    return cred.from_cmd(cmd, info)
  end)
  eq(#vim.fn.readfile(count), 2)
  r = run(function()
    local argv = WIN and { "cmd.exe", "/c", "echo nope 1>&2& exit /b 3" }
      or { "sh", "-c", "echo nope >&2; exit 3" }
    return cred.from_cmd(argv, info)
  end)
  eq({ r.err.phase, vim.trim(r.err.message) }, { "connect", "password_cmd failed (exit 3): nope" })
  r = run(function()
    return cred.from_cmd(WIN and "rem" or "true", info)
  end)
  eq(r.err.message, "password_cmd printed no password")
end

T["precedence: URL password, then password_cmd, then passwords.json"] = function()
  vim.fn.writefile({ vim.json.encode({ ["postgres://app@db:5432/shop"] = "file-pw" }) }, file)
  local function fill(raw, cmd)
    local info = url.parse(raw)
    info.port = info.port or 5432
    local r = run(function()
      cred.fill(info, cmd)
    end)
    eq(r.err, nil)
    return info.password
  end
  eq(fill("postgres://app:url-pw@db/shop", "echo cmd-pw"), "url-pw")
  eq(fill("postgres://app@db/shop", "echo cmd-pw"), "cmd-pw")
  eq(fill("postgres://app@db/shop"), "file-pw")
  eq(fill("postgres://app@db/none"), nil)
end

T["config: password_cmd is validated, unset ${ENV} reported with its line"] = function()
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile(
    { "database:", "  url: postgres://u:${DBDASH_T_UNSET}@h/db", "query: { sql: x }" },
    f
  )
  local _, err = require("dbdash.config").load(f)
  assert(err)
  eq(err.message:find(":2:%d+: environment variable DBDASH_T_UNSET is not set") ~= nil, true)
  vim.fn.writefile(
    { "database:", "  url: postgres://u@h/db", "  password_cmd: 3", "query: { sql: x }" },
    f
  )
  _, err = require("dbdash.config").load(f)
  assert(err)
  eq(err.message:find("password_cmd must be a command string") ~= nil, true)
  vim.fn.writefile({
    "database:",
    "  url: postgres://u@h/db",
    "  password_cmd: [pass, show, db]",
    "query: { sql: x }",
  }, f)
  local cfg = assert(require("dbdash.config").load(f))
  eq(assert(cfg.database).password_cmd, { "pass", "show", "db" })
end

T["integration: password_cmd, passwords.json and ${ENV} against PostgreSQL"] = function()
  h.require_it()
  local q = "SELECT 1 AS one"
  local raw = "postgres://dbdash@127.0.0.1:15432/dbdash_test"
  eq(h.ok(raw, q, { password_cmd = "echo dbdash_pw" }).row_count, 1)
  local r = h.query(raw, q, { password_cmd = "echo wrong" })
  eq(r.err.phase, "auth")
  vim.fn.writefile(
    { vim.json.encode({ ["postgres://dbdash@127.0.0.1:15432/dbdash_test"] = "dbdash_pw" }) },
    file
  )
  eq(h.ok(raw, q).row_count, 1)
  vim.uv.os_setenv("DBDASH_T_PW", "dbdash_pw")
  eq(h.ok("postgres://dbdash:${DBDASH_T_PW}@127.0.0.1:15432/dbdash_test", q).row_count, 1)
  vim.uv.os_unsetenv("DBDASH_T_PW")
end

return T
