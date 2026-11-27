-- Push sources at the driver level (db.run): cutting output into items, exec:// and
-- luastream://. The panels' side is in tests/test_push.lua.
local db = require("dbdash.db")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local RUN_LUA = vim.fs.normalize(vim.fn.fnamemodify("tests/fixtures/run_lua.lua", ":p"))
local LUA = { vim.v.progpath, "--clean", "-l", RUN_LUA } -- exec:// interpreter running Lua

---Run a stream to its end (or `stop_after` ms); returns { items = { {value, vars} }, err }.
local function run(url, query, opts, stop_after)
  local res = { items = {} }
  local h = db.run(
    url,
    query,
    vim.tbl_extend("force", { raw = true }, opts or {}),
    function(_, value, vars)
      res.items[#res.items + 1] = { value, vars }
    end,
    function(err)
      res.ended, res.err = true, err
    end
  )
  res.handle = h
  if stop_after then
    vim.wait(stop_after, function()
      return res.ended
    end, 10)
    if not res.ended then
      h:stop("test")
    end
  end
  vim.wait(10000, function()
    return res.ended
  end, 10)
  assert(res.ended, "stream did not end")
  return res
end

local function values(res)
  return vim.tbl_map(function(it)
    return it[1]
  end, res.items)
end

-- Cutting ----------------------------------------------------------------------------------

T["splitter: delimiters, pieces across writes, the rest at the end, empty pieces"] = function()
  local function cut(delim, chunks, max)
    local out, stats = {}, { truncated = 0 }
    local write, flush = db.splitter(delim, max or 100, function(p)
      out[#out + 1] = p
    end, stats)
    for _, c in ipairs(chunks) do
      write(c)
    end
    flush()
    return out, stats.truncated
  end
  eq(cut(nil, { "a\nb\n", "c" }), { "a", "b", "c" })
  eq(cut("\n", { "a\r\nb\r\n" }), { "a", "b" })
  eq(cut("\n", { "x\n\n\ny\n" }), { "x", "y" }) -- empty pieces are skipped
  eq(cut(";;", { "a;", ";b;;c;", ";" }), { "a", "b", "c" })
  eq(cut("\0", { "a\0b" }), { "a", "b" })
  eq(cut("\n", { "par", "tial\nnext" }), { "partial", "next" })
  -- Too long without a delimiter: the first `max` bytes, then the next piece.
  local out, n = cut("\n", { "0123456789", "abc\nok\n" }, 4)
  eq({ out, n }, { { "0123", "ok" }, 1 })
end

-- exec:// ------------------------------------------------------------------------------------

local function exec_opts(o)
  return {
    options = vim.tbl_extend("force", { interpreter = LUA }, o or {}),
    base_dir = vim.fn.getcwd(),
  }
end

T["exec: each stdout line is one item; the stream ends with the script"] = function()
  local res =
    run("exec://", [[io.write("one\ntwo\n") io.stdout:flush() io.write('{"n": 3}')]], exec_opts())
  eq(res.err, nil)
  eq(values(res), { "one", "two", '{"n": 3}' })
  eq(res.items[1][2].stream, "stdout")
end

T["exec: capture stdout, stderr or both, each with its stream"] = function()
  local code =
    [[io.write("o1\n") io.stdout:flush() io.stderr:write("e1\n") io.stderr:flush() io.write("o2\n")]]
  eq(values(run("exec://", code, exec_opts({ capture = "stderr" }))), { "e1" })
  local both = run("exec://", code, exec_opts({ capture = "both" }))
  local seen = {}
  for _, it in ipairs(both.items) do
    seen[#seen + 1] = it[2].stream .. ":" .. it[1]
  end
  table.sort(seen)
  eq(seen, { "stderr:e1", "stdout:o1", "stdout:o2" })
end

T["exec: exit codes: ok_codes end normally, others fail with the end of stderr"] = function()
  local res = run("exec://", [[io.stderr:write("bad thing\n") os.exit(2)]], exec_opts())
  eq(res.err.phase, "query")
  eq(res.err.message:find("exited with code 2", 1, true) ~= nil, true)
  eq(res.err.message:find("bad thing", 1, true) ~= nil, true)
  eq(run("exec://", [[os.exit(2)]], exec_opts({ ok_codes = { 0, 2 } })).err, nil)
  eq(
    run("exec://", [[os.exit(0)]], exec_opts({ ok_codes = { 1 } })).err.message:find(
      "code 0",
      1,
      true
    ) ~= nil,
    true
  )
end

T["exec: cwd (default: the config directory), env, stdin and the delimiter"] = function()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir .. "/sub", "p")
  local code =
    [[io.write(vim.uv.cwd(), "|", tostring(os.getenv("DBDASH_X")), "|", io.read("*a"), "|")]]
  local o = exec_opts({ delimiter = "|", env = { DBDASH_X = "x1" }, stdin = "in" })
  o.base_dir = dir
  eq(values(run("exec://", code, o)), { vim.uv.fs_realpath(dir), "x1", "in" })
  o.options.cwd = "sub"
  eq(values(run("exec://", code, o))[1], vim.uv.fs_realpath(dir .. "/sub"))
  o.options.cwd = "nope"
  eq(run("exec://", code, o).err.message:find("not a directory", 1, true) ~= nil, true)
  -- The environment is inherited.
  vim.env.DBDASH_INHERITED = "yes"
  eq(values(run("exec://", [[io.write(os.getenv("DBDASH_INHERITED"))]], exec_opts())), { "yes" })
end

T["exec: unknown or wrong options are config errors"] = function()
  eq(
    run("exec://", "x", exec_opts({ nope = 1 })).err.message:find(
      "unknown option database.options.nope",
      1,
      true
    ) ~= nil,
    true
  )
  eq(run("exec://", "x", exec_opts({ capture = "all" })).err.phase, "config")
  eq(run("exec://", "x", exec_opts({ ok_codes = {} })).err.phase, "config")
  eq(
    run("exec://", "x", { options = { interpreter = { "/no/such/program" } } }).err.message:find(
      "cannot run",
      1,
      true
    ) ~= nil,
    true
  )
end

T["exec: stopping kills the script"] = function()
  local pidfile = vim.fn.tempname()
  local code = ([[local f = io.open(%q, "w") f:write(vim.fn.getpid()) f:close() io.write("started\n") io.stdout:flush() while true do vim.uv.sleep(50) end]]):format(
    pidfile
  )
  local res = run("exec://", code, exec_opts(), 1500)
  eq(res.err.phase, "cancelled")
  eq(values(res), { "started" })
  local pid = tonumber(vim.fn.readfile(pidfile)[1])
  local function alive()
    return vim.uv.kill(pid, 0) == 0 -- (returns nil and an error once it is gone)
  end
  vim.wait(5000, function()
    return not alive()
  end, 50)
  eq(alive(), false)
end

T["exec: the default interpreter is the system shell"] = function()
  if jit.os == "Windows" then
    eq(require("dbdash.db.drivers.exec").default_interpreter()[1], "cmd.exe")
    return
  end
  local v = values(run("exec://", "echo a; echo b >&2; echo c", { options = { capture = "both" } }))
  table.sort(v) -- (stdout and stderr are separate pipes: no order between them)
  eq(v, { "a", "b", "c" })
end

T["a push source cannot be queried"] = function()
  local r = require("tests.helpers").query("exec://", "echo 1")
  eq(r.err.message:find("is a push source", 1, true) ~= nil, true)
end

-- luastream:// ---------------------------------------------------------------------------

T["luastream: print and io.write are cut into items; emit passes one value as it is"] = function()
  local res = run(
    "luastream://",
    [[
    print("a", 1)
    io.write("b\nc")
    io.write("d\n")
    dbdash.emit({ { n = 1 } })
    return { { last = true } }
  ]],
    { base_dir = vim.fn.getcwd() }
  )
  eq(res.err, nil)
  eq(values(res), { "a\t1", "b", "cd", { { n = 1 } }, { { last = true } } })
end

T["luastream: delimiter, errors, waiting and stopping"] = function()
  eq(
    values(run("luastream://", [[io.write("x;y;")]], { options = { delimiter = ";" } })),
    { "x", "y" }
  )
  local res = run("luastream://", [[print("before") error("boom")]], {})
  eq({ values(res), res.err.message:find("boom", 1, true) ~= nil }, { { "before" }, true })
  -- It waits without blocking (dbdash.sleep) and stops when stopped.
  res = run("luastream://", [[while true do print("tick") dbdash.sleep(100) end]], {}, 450)
  eq(res.err.phase, "cancelled")
  eq(#res.items >= 3, true)
  -- A loop that never waits would freeze Neovim: it stops after the query timeout.
  res = run("luastream://", [[local i = 0 while true do i = i + 1 end]], { timeout = 300 })
  eq(res.err.phase, "timeout")
  eq(res.err.message:find("without waiting", 1, true) ~= nil, true)
end

T["luastream: cwd for files and commands; Neovim's own directory stays"] = function()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir .. "/data", "p")
  vim.fn.writefile({ "l1", "l2" }, dir .. "/data/in.txt")
  vim.fn.writefile({ "return 'from dofile'" }, dir .. "/data/m.lua")
  local before = vim.fn.getcwd()
  local res = run(
    "luastream://",
    [[
    for l in io.lines("in.txt") do print(l) end
    local f = io.open("in.txt") print(f:read("*l")) f:close()
    print(dofile("m.lua"))
    print(dbdash.cwd)
    print(vim.trim(dbdash.system(jit.os == "Windows" and "cd" or "pwd").stdout))
  ]],
    { base_dir = dir, options = { cwd = "data" } }
  )
  eq(res.err, nil)
  local real = vim.uv.fs_realpath(dir .. "/data")
  local v = values(res)
  eq({ v[1], v[2], v[3], v[4] }, { "l1", "l2", "l1", "from dofile" })
  eq(vim.uv.fs_realpath(v[5]), real)
  eq(vim.uv.fs_realpath(vim.fs.normalize(v[6])), real)
  eq(vim.fn.getcwd(), before)
  if jit.os ~= "Windows" then
    res = run(
      "luastream://",
      [[local p = io.popen("pwd") print(vim.trim(p:read("*a"))) p:close()]],
      { base_dir = dir, options = { cwd = "data" } }
    )
    eq(vim.uv.fs_realpath(values(res)[1]), real)
  end
end

return T
