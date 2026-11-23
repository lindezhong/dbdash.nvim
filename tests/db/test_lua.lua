-- lua:// queries and the shared script runner (db/lua_env.lua, db/lua_result.lua).
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local NULL = vim.NIL

local function cols(rs)
  return vim.tbl_map(function(c)
    return c.name .. ":" .. c.type
  end, rs.columns)
end

T["columns and rows by position; nil is NULL"] = function()
  local rs = h.ok("lua://", 'return { columns = { "a", "b" }, rows = { { 1, "x" }, { 2, nil } } }')
  eq(cols(rs), { "a:integer", "b:string" })
  eq(rs.rows, { { 1, "x" }, { 2, NULL } })
end

T["rows by name, records with sorted or given columns"] = function()
  eq(h.ok("lua://", 'return { columns = { "b", "a" }, rows = { { a = 1, b = 2 } } }').rows, { { 2, 1 } })
  local rs = h.ok("lua://", 'return { { name = "n1", v = 1.5, ok = true }, { name = "n2", v = 2 } }')
  eq(cols(rs), { "name:string", "ok:boolean", "v:number" })
  eq(rs.rows, { { "n1", true, 1.5 }, { "n2", NULL, 2 } })
  eq(h.ok("lua://", 'return { { a = 1, b = 2 }, columns = { "b", "a" } }').rows, { { 2, 1 } })
  eq(h.ok("lua://", "return { { 1, 2 } }").columns[2].name, "c2")
  eq(h.ok("lua://", "return {}").row_count, 0)
  eq(cols(h.ok("lua://", 'return { { t = { x = 1 } } }')), { "t:json" })
end

T["max_rows truncates"] = function()
  local rs = h.ok("lua://", "local r = {} for i = 1, 50 do r[i] = { i } end return r", { max_rows = 10 })
  eq({ rs.row_count, rs.truncated }, { 10, true })
end

T["args, dbdash.system and dbdash.query"] = function()
  eq(h.ok("lua://", "return { { n = args.n * 2 } }", { args = { n = 21 } }).rows, { { 42 } })
  local cmd = jit.os == "Windows" and "echo hi" or "printf hi"
  local rs = h.ok("lua://", ('local r = dbdash.system(%q) return { { out = vim.trim(r.stdout), code = r.code } }'):format(cmd))
  eq(rs.rows, { { 0, "hi" } })
  rs = h.ok("lua://", 'local rs = dbdash.query("sqlite:///:memory:", "SELECT 40 + 2 AS x") return { { x = rs.rows[1][1] } }')
  eq(rs.rows, { { 42 } })
end

T["dbdash.system waits without blocking the editor"] = function()
  local cmd = jit.os == "Windows" and "ping -n 2 127.0.0.1 >NUL" or "sleep 0.4"
  local maxgap, last = 0, vim.uv.hrtime()
  local t = vim.uv.new_timer()
  t:start(1, 1, function()
    local n = vim.uv.hrtime()
    maxgap = math.max(maxgap, (n - last) / 1e6)
    last = n
  end)
  h.ok("lua://", ("dbdash.system(%q) return { { done = true } }"):format(cmd))
  t:stop()
  t:close()
  eq(maxgap < 100, true)
end

T["errors carry the config file and line"] = function()
  local r = h.query("lua://", "local x = nil\nreturn x.y", { source = "board.yaml", line = 10 })
  eq({ r.err.phase, r.err.message }, { "query", "board.yaml:11: attempt to index local 'x' (a nil value)" })
  r = h.query("lua://", "return {", { source = "board.yaml", line = 10 })
  eq(r.err.message:find("^syntax error: board.yaml:10:") ~= nil, true)
  r = h.query("lua://", "return 42")
  eq(r.err.message, "the script must return a table of rows (got number)")
  r = h.query("lua://", 'error({ message = "custom" })')
  eq(r.err.message, "custom")
  r = h.query("lua://", 'dbdash.query("sqlite:///:memory:", "SELEC")')
  eq(r.err.message:find("syntax error", 1, true) ~= nil, true) -- the nested query's error
end

T["a runaway loop stops at the timeout"] = function()
  local r = h.query("lua://", "while true do end", { timeout = 300 })
  eq({ r.err.phase, r.err.message }, { "timeout", "script did not finish within 0.3s" })
end

T["config: lua:// is a database type; the template renders the script"] = function()
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile({
    "database: { url: 'lua://' }",
    "query:",
    "  args: [{ name: n, type: int, default: 3 }]",
    "  sql: |",
    "    local rows = {}",
    "    for i = 1, {{ n }} do rows[i] = { i, i * args.n } end",
    "    return { columns = { 'i', 'x' }, rows = rows }",
    "show: { type: bar, x_column: i, y_column: x }",
  }, f)
  local cfg = assert(require("dbdash.config").load(f))
  eq(cfg.database.type, "lua")
end

return T
