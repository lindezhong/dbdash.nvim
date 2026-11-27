-- Lua state of a panel across refreshes: `store`, meta.prev_*, dbdash.run() callbacks and
-- assigning arguments (from Lua and {% set args.x %}).
local sched = require("dbdash.dashboard")
local eq = MiniTest.expect.equality

local dir, notes
local real_notify = vim.notify
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      require("dbdash").setup({ lua = { confirm = false } }) -- trust is tested in test_trust.lua
      -- Refresh errors notify; keep them (the cases check the errors) instead of printing.
      notes = {}
      vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
      end
    end,
    post_case = function()
      vim.notify = real_notify
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
    end,
  },
})

---Wait until no panel of `d` runs and each has a result or an error.
local function settle(d)
  vim.wait(10000, function()
    for _, p in ipairs(d.panels) do
      if not (p.rs or p.error) or p.running then
        return false
      end
    end
    return true
  end, 10)
end

---Start a dashboard from config text; wait for the first result of every panel.
local function start(name, text)
  local path = dir .. "/" .. name .. ".yaml"
  vim.fn.writefile(vim.split(text, "\n"), path)
  require("dbdash.view.dashboard").start(path, { no_show = true })
  local d = assert(sched.get(sched.normalize(path)), "dashboard did not start")
  settle(d)
  return d, path
end

---Refresh panel `p` once more and wait for it.
local function again(p)
  local before = p.refresh_count
  p:refresh({ queue = true })
  vim.wait(10000, function()
    return p.refresh_count > before and not p.running
  end, 10)
  return p
end

local function cell(p, r, c)
  assert(p.rs, p.error and sched.format_error(p.error) or "no result")
  return p.rs.rows[r or 1][c or 1]
end

T["store: kept across refreshes, one per panel, shared by all of its Lua"] = function()
  vim.fn.writefile({
    "local M = {}",
    "function M.bump() store.module = (store.module or 0) + 1; return store.module end",
    "return M",
  }, dir .. "/h.lua")
  local d = start(
    "store",
    [[
database: { url: "sqlite:///:memory:" }
panels:
  - query:
      sql: |
        {% import 'h.lua' as h %}
        SELECT {% lua %}store.block = (store.block or 0) + 1; return store.block{% endlua %} AS block,
               {{ h.bump() }} AS module
      transform: |
        store.transform = (store.transform or 0) + 1
        return { { block = rs.rows[1][1], module = rs.rows[1][2], transform = store.transform } }
  - database: { url: "lua://" }
    query:
      sql: |
        store.script = (store.script or 0) + 1
        return { { script = store.script, block = store.block } }
]]
  )
  local p1, p2 = d.panels[1], d.panels[2]
  -- columns of records are sorted by name: block, module, transform
  eq({ cell(p1, 1, 1), cell(p1, 1, 2), cell(p1, 1, 3) }, { 1, 1, 1 })
  again(p1)
  again(p1)
  eq({ cell(p1, 1, 1), cell(p1, 1, 2), cell(p1, 1, 3) }, { 3, 3, 3 })
  -- panel 2 has its own store: no `block` from panel 1
  again(p2)
  eq({ cell(p2, 1, 1), cell(p2, 1, 2) }, { 2, nil })
end

T["store: empty again when the dashboard is started again"] = function()
  local text = [[
database: { url: "lua://" }
query: { sql: "store.n = (store.n or 0) + 1; return { { n = store.n } }" }
]]
  local d, path = start("again", text)
  again(d.panels[1])
  eq(cell(d.panels[1]), 2)
  sched.stop(path)
  d = start("again", text)
  eq(cell(d.panels[1]), 1)
end

T["meta.prev_ok.query / .result: the last success's results, before and after the transform"] = function()
  local d = start(
    "prev",
    [[
database: { url: "sqlite:///:memory:" }
query:
  sql: |
    SELECT {{ meta.refresh_count }} AS n,
           {{ (meta.prev_ok.result.rows[0][0] if meta.prev_ok is not none else 0) }} AS prev_doubled,
           {{ (meta.prev_ok.query.rows[0][0] if meta.prev_ok is not none else 0) }} AS prev_raw,
           {{ 1 if meta.prev is none or meta.prev.error is none else 0 }} AS ok
  transform: |
    local r = rs.rows[1]
    local pq = meta.prev_ok and meta.prev_ok.query.columns[1] or "none"
    return { columns = { "doubled", "prev_doubled", "prev_raw", "ok", "prev_query_col" },
             rows = { { r[1] * 2, r[2], r[3], r[4], pq } } }
]]
  )
  local p = d.panels[1]
  eq(p.rs.rows[1], { 2, 0, 0, 1, "none" })
  again(p)
  -- prev_ok.result is the transformed row (doubled = 2), prev_ok.query the query's own (n = 1)
  eq(p.rs.rows[1], { 4, 2, 1, 1, "n" })
end

T["meta.prev.error: the previous refresh's error; meta.prev_ok keeps the last success"] = function()
  local d = start(
    "err",
    [[
database: { url: "lua://" }
query:
  sql: |
    store.n = (store.n or 0) + 1
    if store.n == 2 then error("boom") end
    return { { n = store.n, prev = meta.prev_ok and meta.prev_ok.result.rows[1][2] or 0, -- (err, n, prev)
               err = meta.prev and meta.prev.error or "" } }
]]
  )
  local p = d.panels[1]
  eq(p.rs.rows[1], { "", 1, 0 }) -- columns sorted: err, n, prev
  again(p)
  eq(p.error ~= nil, true)
  again(p)
  local row = p.rs.rows[1]
  eq({ row[2], row[3] }, { 3, 1 }) -- the last success was refresh 1
  eq(row[1]:find("boom", 1, true) ~= nil, true)
  again(p)
  eq(p.rs.rows[1][1], "") -- refresh 3 succeeded: no meta.prev.error
end

T["show.refresh_hidden: keeps refreshing while the dashboard is paused"] = function()
  local d = start(
    "hidden",
    [[
database: { url: "lua://" }
show: { interval: 1s }
panels:
  - query: { sql: "return { { x = 1 } }" }
    show: { refresh_hidden: true }
  - query: { sql: "return { { x = 2 } }" }
]]
  )
  local p1, p2 = d.panels[1], d.panels[2]
  d:pause()
  local h1, h2 = #p1.history, #p2.history
  vim.wait(2600, function()
    return false
  end, 50)
  eq(#p1.history >= h1 + 2, true)
  eq(#p2.history, h2)
  d:resume()
  vim.wait(1500, function()
    return #p2.history > h2
  end, 50)
  eq(#p2.history > h2, true)
end

T["show.refresh_hidden: with the global refresh, while paused only those panels refresh"] = function()
  local d = start(
    "hidden_global",
    [[
database: { url: "lua://" }
interval: 1s
panels:
  - query: { sql: "return { { x = 1 } }" }
    show: { refresh_hidden: true }
  - query: { sql: "return { { x = 2 } }" }
]]
  )
  local p1, p2 = d.panels[1], d.panels[2]
  eq(p1.cfg.follows_global, true)
  d:pause()
  eq(d.clock:running(), true) -- kept for panel 1
  local h1, h2 = #p1.history, #p2.history
  vim.wait(2600, function()
    return false
  end, 50)
  eq(#p1.history >= h1 + 2, true)
  eq(#p2.history, h2)
  d:resume()
end

T["dbdash.run(): the panel's pipeline with other arguments; meta.run.depth is the depth"] = function()
  local d = start(
    "cb",
    [[
database: { url: "sqlite:///:memory:" }
query:
  args: [{ name: n, type: int, default: 1 }]
  sql: |
    SELECT {{ args.n }} AS n, {{ meta.run.depth }} AS depth,
    {% lua %}
      if meta.run.depth < 2 then
        local r = dbdash.run({ n = args.n * 10 }).rows[1]
        return "'" .. r[1] .. ":" .. r[2] .. "," .. r[3] .. "'"
      end
      return "'-'"
    {% endlua %} AS chain
  transform: |
    return { columns = { "n", "depth", "chain" }, rows = { rs.rows[1] } }
]]
  )
  local p = d.panels[1]
  assert(p.rs, p.error and sched.format_error(p.error))
  -- the refresh: n = 1, depth 0; its callback: n = 10, depth 1; that one's: n = 100, depth 2
  eq(p.rs.rows[1], { 1, 0, "10:1,100:2,-" })
  eq(p.refresh_count, 1) -- callbacks are not refreshes
end

T["dbdash.run(): from imported modules, transforms and lua://; returns the transformed rows"] = function()
  vim.fn.writefile(
    { "local M = {}", "function M.twice() return dbdash.run({ k = 2 }).rows[1][1] end", "return M" },
    dir .. "/m.lua"
  )
  local d = start(
    "cbs",
    [[
database: { url: "lua://" }
panels:
  - query:
      args: [{ name: k, type: int, default: 1 }]
      sql: |
        {% import 'm.lua' as m %}
        return { { v = {{ args.k }} * 7, via_module = {{ m.twice() if meta.run.depth == 0 else 0 }} } }
      transform: |
        local via_transform = meta.run.depth == 0 and dbdash.run({ k = 3 }).rows[1][1] or 0
        return { { v = rs[1].v, via_module = rs[1].via_module, via_transform = via_transform } }
  - query:
      args: [{ name: k, type: int, default: 1 }]
      sql: |
        if meta.run.depth == 0 then return { { v = dbdash.run({ k = 5 }).rows[1][1] } } end
        return { { v = args.k * 11 } }
]]
  )
  local p1, p2 = d.panels[1], d.panels[2]
  assert(p1.rs, p1.error and sched.format_error(p1.error))
  -- columns sorted: v, via_module, via_transform
  eq(p1.rs.rows[1], { 7, 14, 21 })
  eq(p2.rs.rows[1][1], 55)
end

T["dbdash.run(): the depth and total limits fail the refresh"] = function()
  local d = start(
    "loop",
    [[
database: { url: "lua://" }
query: { sql: "dbdash.run(); return {}" }
]]
  )
  local p = d.panels[1]
  eq(
    sched
      .format_error(p.error)
      :find("dbdash.run: callbacks nested deeper than 10 (lua.max_callback_depth)", 1, true)
      ~= nil,
    true
  )
  -- the failed refresh notified it (as an error, once)
  eq(#notes, 1)
  eq(
    { notes[1].level, notes[1].msg:find("nested deeper than 10", 1, true) ~= nil },
    { vim.log.levels.ERROR, true }
  )
  -- shallow but wide: 3 calls per level, 5 levels = 3 + 9 + 27 + 81 + 243 calls
  require("dbdash").setup({ lua = { confirm = false, max_callbacks = 50, max_callback_depth = 5 } })
  d = start(
    "wide",
    [[
database: { url: "lua://" }
query: { sql: "if meta.run.depth < 5 then for _ = 1, 3 do dbdash.run() end end; return { { c = meta.run.depth } }" }
]]
  )
  p = d.panels[1]
  eq(
    sched
      .format_error(p.error)
      :find("dbdash.run: more than 50 callbacks in one refresh (lua.max_callbacks)", 1, true)
      ~= nil,
    true
  )
  -- each refresh counts from 0: 3 + 9 = 12 calls per refresh fit 50 every time
  require("dbdash").setup({ lua = { confirm = false, max_callbacks = 12 } })
  d = start(
    "fits",
    [[
database: { url: "lua://" }
query: { sql: "if meta.run.depth < 2 then for _ = 1, 3 do dbdash.run() end end; return { { c = 1 } }" }
]]
  )
  p = d.panels[1]
  eq(p.error, nil)
  again(p)
  again(p)
  eq({ p.error, p.refresh_count }, { nil, 3 })
end

T["dbdash.run(): unknown arguments and wrong types are errors"] = function()
  local d = start(
    "badrun",
    [[
database: { url: "lua://" }
query:
  args: [{ name: n, type: int }]
  sql: "if meta.run.depth == 0 then dbdash.run({ {{ 'nope' if true }} = 1 }) end; return {}"
]]
  )
  eq(
    sched.format_error(d.panels[1].error):find("'nope' is not an argument of this panel", 1, true)
      ~= nil,
    true
  )
  d = start(
    "badtype",
    [[
database: { url: "lua://" }
query:
  args: [{ name: n, type: int }]
  sql: "if meta.run.depth == 0 then dbdash.run({ n = 'x' }) end; return {}"
]]
  )
  eq(
    sched.format_error(d.panels[1].error):find("argument 'n' is an int, got a string", 1, true)
      ~= nil,
    true
  )
end

T["dbdash.run(): the outer script keeps its timeout after a callback"] = function()
  local d = start(
    "timeout",
    [[
database: { url: "lua://" }
query:
  timeout: 1s
  sql: |
    if meta.run.depth > 0 then return { { x = 1 } } end
    dbdash.run()
    while true do end
]]
  )
  local e = d.panels[1].error
  eq(e ~= nil and sched.format_error(e):find("did not finish within 1.0s", 1, true) ~= nil, true)
end

T["timeouts: a waiting script's deadline does not fire in other code"] = function()
  local d = start(
    "waiting",
    [[
database: { url: "lua://" }
query:
  timeout: 1s
  sql: |
    dbdash.sleep(300)
    return { { x = 1 } }
]]
  )
  -- Another task waits in guarded code past its deadline while this (interpreted) code
  -- runs: LuaJIT's hook is global, but only the running coroutine's deadlines count.
  local task_done = false
  require("dbdash.util.async").run(function()
    require("dbdash.db.lua_env").guard(function()
      require("dbdash.util.async").sleep(400)
    end, 100)
  end, function()
    task_done = true
  end)
  local busy = function()
    local n = 0
    for i = 1, 200000 do
      n = n + i
    end
    return n
  end
  jit.off(busy)
  local ok, err = pcall(function()
    vim.wait(800, function()
      busy()
      return task_done
    end, 5)
  end)
  eq({ ok, err }, { true, nil })
  eq(d.panels[1].error, nil)
end

T["args.x = v in Lua: the rest of the run sees it, and it is kept"] = function()
  vim.fn.writefile(
    { "local M = {}", "function M.set(n) args.n = n; return n end", "return M" },
    dir .. "/s.lua"
  )
  local d = start(
    "assign",
    [[
database: { url: "sqlite:///:memory:" }
query:
  args: [{ name: n, type: int, default: 1 }, { name: tag, default: a }]
  sql: |
    {% import 's.lua' as s %}
    SELECT {{ args.n }} AS before,
    {% lua %}args.n = args.n + 10; return args.n{% endlua %} AS in_block,
    {{ args.n }} AS after_block,
    {{ s.set(args.n * 2) }} AS module,
    {{ args.n }} AS after_module
  transform: |
    local r = rs.rows[1]
    local seen = args.n
    args.tag = "t" .. args.n
    return { columns = { "before", "in_block", "after_block", "module", "after_module", "transform" },
             rows = { { r[1], r[2], r[3], r[4], r[5], seen } } }
]]
  )
  local p = d.panels[1]
  assert(p.rs, p.error and sched.format_error(p.error))
  eq(p.rs.rows[1], { 1, 11, 11, 22, 22, 22 })
  -- kept like an edit: shown, used by the next refresh, reset by R
  local a = require("dbdash.args")
  local function value(name)
    return a.value(a.find(d.cfg.args, name), d.state)
  end
  eq({ value("n"), value("tag") }, { 22, "t22" })
  again(p)
  eq(p.rs.rows[1][1], 22)
  a.reset(d.state)
  eq(value("n"), 1)
end

T["{% set args.x = v %}: like args.x = v, also in macros and imported templates"] = function()
  vim.fn.writefile(
    { "{% macro bump() %}{% set args.n = args.n + 100 %}{% endmacro %}" },
    dir .. "/m.sql"
  )
  local d = start(
    "setarg",
    [[
database: { url: "sqlite:///:memory:" }
query:
  args: [{ name: n, type: int, default: 1 }, { name: ids, type: list, default: [1] }]
  sql: |
    {% import 'm.sql' as m %}
    {% set args.n = args.n + 1 %}
    {% for i in [1, 2] %}{% set args.n = args.n * 2 %}{% endfor %}
    {{ m.bump() }}
    {% set args.ids = [4, 5] %}
    SELECT {{ args.n }} AS n, {{ args.ids | length }} AS ids
  transform: |
    return { columns = { "n", "lua_n", "ids" }, rows = { { rs.rows[1][1], args.n, #args.ids } } }
]]
  )
  local p = d.panels[1]
  assert(p.rs, p.error and sched.format_error(p.error))
  -- (1 + 1) * 2 * 2 + 100; the loop's assignments are not loop-local
  eq(p.rs.rows[1], { 108, 108, 2 })
  local a = require("dbdash.args")
  eq(a.value(a.find(d.cfg.args, "n"), d.state), 108)
end

T["assigning args: a callback keeps its values; the assignment is still kept"] = function()
  local d = start(
    "cbassign",
    [[
database: { url: "lua://" }
query:
  args: [{ name: n, type: int, default: 1 }]
  sql: |
    if meta.run.depth == 0 then
      local inner = dbdash.run().rows[1][1]
      return { { n = args.n, inner = inner } }
    end
    args.n = 50
    return { { n = args.n } }
]]
  )
  local p = d.panels[1]
  assert(p.rs, p.error and sched.format_error(p.error))
  eq(p.rs.rows[1], { 50, 1 }) -- columns: inner, n; the refresh's own n is still 1
  local a = require("dbdash.args")
  eq(a.value(a.find(d.cfg.args, "n"), d.state), 50)
end

T["assigning args: shared or the panel's own (a local one shadows)"] = function()
  local d = start(
    "scopes",
    [[
database: { url: "lua://" }
args: [{ name: region, default: EU }]
panels:
  - query:
      args: [{ name: region, default: US }]
      sql: "args.region = 'CN'; return { { r = args.region } }"
  - query: { sql: "return { { r = args.region } }" }
  - query: { sql: "args.region = 'JP'; return { { r = args.region } }" }
]]
  )
  local a = require("dbdash.args")
  local function value(key)
    return a.value(a.find(d.cfg.args, key), d.state)
  end
  eq({ value("1.region"), value("region") }, { "CN", "JP" })
  again(d.panels[2])
  eq(d.panels[2].rs.rows[1][1], "JP")
end

T["assigning args: unknown names, wrong types, the whole args or meta are errors"] = function()
  local function err_of(name, text)
    local d = start(name, text)
    local e = d.panels[1].error
    return e and sched.format_error(e) or ""
  end
  local db = "database: { url: 'sqlite:///:memory:' }\n"
  eq(
    err_of("e1", db .. 'query:\n  sql: "{% lua %}args.nope = 1{% endlua %}SELECT 1"\n'):find(
      "'nope' is not an argument of this panel",
      1,
      true
    ) ~= nil,
    true
  )
  eq(
    err_of(
      "e2",
      db .. "query:\n  args: [{ name: n, type: int }]\n  sql: \"{% set args.n = 'x' %}SELECT 1\"\n"
    ):find("argument 'n' is an int, got a string", 1, true) ~= nil,
    true
  )
  eq(
    err_of("e3", db .. 'query:\n  sql: "{% set args = 1 %}SELECT 1"\n'):find(
      "'args' is reserved",
      1,
      true
    ) ~= nil,
    true
  )
  eq(
    err_of("e4", db .. 'query:\n  sql: "{% set meta.x = 1 %}SELECT 1"\n'):find(
      "'meta' is read-only",
      1,
      true
    ) ~= nil,
    true
  )
  -- {% set obj.x %} is for namespace() objects (Jinja); here foo is undefined.
  eq(
    err_of("e5", db .. 'query:\n  sql: "{% set foo.x = 1 %}SELECT 1"\n'):find(
      "'foo' is undefined",
      1,
      true
    ) ~= nil,
    true
  )
  eq(
    err_of("e5b", db .. 'query:\n  sql: "{% set foo = {} %}{% set foo.x = 1 %}SELECT 1"\n'):find(
      "cannot assign attribute on non-namespace object",
      1,
      true
    ) ~= nil,
    true
  )
  eq(
    err_of(
      "e6",
      db .. "query:\n  args: [{ name: n }]\n  sql: \"{% set args['n'] = 1 %}SELECT 1\"\n"
    ):find("not supported", 1, true) ~= nil,
    true
  )
  eq(
    err_of(
      "e7",
      "database: { url: 'lua://' }\nquery:\n  args: [{ name: n, type: int }]\n  sql: \"args.n = 'x'; return {}\"\n"
    ):find("argument 'n' is an int, got a string", 1, true) ~= nil,
    true
  )
end

T["{% set args.x %} outside a dashboard is an error"] = function()
  local out, err = require("dbdash.template").render("{% set args.n = 1 %}", {}, {})
  eq(out, nil)
  eq((err.message or ""):find("args can only be assigned in a dashboard", 1, true) ~= nil, true)
end

T["assigning args: the documented callback case (copy, callback assigns 10)"] = function()
  local function run_case(name, copy_expr)
    local d = start(
      name,
      ([[
database: { url: "lua://" }
query:
  args: [{ name: days, type: int, default: 0 }]
  sql: |
    if meta.run.depth > 0 then
      local start = args.days
      args.days = 10
      return { { start = start, after = args.days } }
    end
    local copy = %s
    copy.days = 14
    local r = dbdash.run(copy).rows[1]
    return { { caller = args.days, copy = copy.days, cb_start = r[2], cb_after = r[1] } }
]]):format(copy_expr)
    )
    local p = d.panels[1]
    assert(p.rs, p.error and sched.format_error(p.error))
    local a = require("dbdash.args")
    -- columns sorted: caller, cb_after, cb_start, copy
    return p.rs.rows[1], a.value(a.find(d.cfg.args, "days"), d.state)
  end
  local row, kept = run_case("deep", "vim.deepcopy(args)")
  eq({ row, kept }, { { 0, 10, 14, 14 }, 10 })
  -- the same table: the caller assigned 14 itself, applied after the callback's 10
  row, kept = run_case("same", "args")
  eq({ row, kept }, { { 14, 10, 14, 14 }, 14 })
end

-- The callback case of :help dbdash-assign-args, edge by edge. Scripts log what they see
-- into `store.log`; kept() is the dashboard's value of `days`.
local function kept(d, name)
  local a = require("dbdash.args")
  return a.value(a.find(d.cfg.args, name or "days"), d.state)
end

---A lua:// panel with argument days (default 0); `body` is its script.
local function lua_case(name, body)
  local d = start(
    name,
    ([[
database: { url: "lua://" }
query:
  args: [{ name: days, type: int, default: 0 }]
  sql: |
    store.log = store.log or {}
%s
    return { { ok = 1 } }
]]):format(body:gsub("\n", "\n    "):gsub("^", "    "))
  )
  local p = d.panels[1]
  assert(p.rs or p.error, "no result")
  return d, p, p.store.log
end

T["callback case: assigned in query.sql before use, the callback's query uses 10"] = function()
  local d = start(
    "cb_sql",
    [[
database: { url: "sqlite:///:memory:" }
query:
  args: [{ name: days, type: int, default: 0 }]
  sql: |
    {% if meta.run.depth > 0 %}{% set args.days = 10 %}{% endif %}
    SELECT {{ args.days }} AS used
  transform: |
    if meta.run.depth > 0 then return rs end
    local copy = vim.deepcopy(args)
    copy.days = 14
    local r = dbdash.run(copy).rows[1]
    return { { caller = args.days, copy = copy.days, callback_query = r[1] } }
]]
  )
  local p = d.panels[1]
  assert(p.rs, p.error and sched.format_error(p.error))
  -- columns sorted by name: callback_query, caller, copy
  eq(p.rs.rows[1], { 10, 0, 14 })
  eq(kept(d), 10)
end

T["callback case: assigned in its query.transform, the callback's query used 14"] = function()
  local d = start(
    "cb_transform",
    [[
database: { url: "sqlite:///:memory:" }
query:
  args: [{ name: days, type: int, default: 0 }]
  sql: SELECT {{ args.days }} AS used
  transform: |
    if meta.run.depth > 0 then
      local before = args.days
      args.days = 10
      return { { used = rs.rows[1][1], before = before, after = args.days } }
    end
    local copy = vim.deepcopy(args)
    copy.days = 14
    local r = dbdash.run(copy).rows[1]  -- after, before, used
    return { { caller = args.days, cb_used = r[3], cb_before = r[2], cb_after = r[1] } }
]]
  )
  local p = d.panels[1]
  assert(p.rs, p.error and sched.format_error(p.error))
  -- columns: caller, cb_after, cb_before, cb_used
  eq(p.rs.rows[1], { 0, 10, 14, 14 })
  eq(kept(d), 10)
end

T["callback case: a callback that does not assign changes nothing kept"] = function()
  local d, p, log = lua_case(
    "cb_noassign",
    [[
if meta.run.depth > 0 then table.insert(store.log, args.days); return { { ok = 1 } } end
dbdash.run({ days = 14 })
table.insert(store.log, args.days)]]
  )
  eq(log, { 14, 0 })
  eq(kept(d), 0)
  again(p)
  eq(p.store.log[3], 14) -- the next refresh's callback: 14 again (given), caller 0
  eq(p.store.log[4], 0)
end

T["callback case: the caller assigned before calling; the callback starts from it"] = function()
  local d, _, log = lua_case(
    "cb_before",
    [[
if meta.run.depth > 0 then table.insert(store.log, args.days); return { { ok = 1 } } end
args.days = 5
dbdash.run()
dbdash.run({ days = 14 })]]
  )
  -- dbdash.run() starts with the caller's 5 (same table, not yet kept); given 14 wins
  eq(log, { 5, 14 })
  eq(kept(d), 5)
end

T["callback case: the caller assigns the same argument after the callback; it wins"] = function()
  local d, _, log = lua_case(
    "cb_after",
    [[
if meta.run.depth > 0 then args.days = 10; return { { ok = 1 } } end
dbdash.run({ days = 14 })
table.insert(store.log, args.days)
args.days = 3
table.insert(store.log, args.days)]]
  )
  eq(log, { 0, 3 })
  eq(kept(d), 3)
end

T["callback case: the same table (copy = args); the caller's 14 wins over the callback's 10"] = function()
  local d, _, log = lua_case(
    "cb_same",
    [[
if meta.run.depth > 0 then table.insert(store.log, args.days); args.days = 10; return { { ok = 1 } } end
local copy = args
copy.days = 14
dbdash.run(copy)
table.insert(store.log, args.days)]]
  )
  eq(log, { 14, 14 })
  eq(kept(d), 14)
end

T["callback case: two callbacks in one refresh; the second starts from the caller's values"] = function()
  local d, _, log = lua_case(
    "cb_twice",
    [[
if meta.run.depth > 0 then
  table.insert(store.log, args.days)
  if args.days == 14 then args.days = 10 end
  return { { ok = 1 } }
end
local copy = vim.deepcopy(args)
copy.days = 14
dbdash.run(copy)
dbdash.run()
table.insert(store.log, args.days)]]
  )
  -- first callback: 14 -> assigns 10; second: the caller's 0 (not 10); caller: 0
  eq(log, { 14, 0, 0 })
  eq(kept(d), 10)
end

T["callback case: nested callbacks; each level keeps its own values"] = function()
  local d, _, log = lua_case(
    "cb_nested",
    [[
if meta.run.depth == 2 then
  table.insert(store.log, "2:" .. args.days)
  args.days = 20
  return { { ok = 1 } }
end
if meta.run.depth == 1 then
  table.insert(store.log, "1:" .. args.days)
  dbdash.run({ days = args.days + 1 })
  table.insert(store.log, "1:" .. args.days)
  return { { ok = 1 } }
end
dbdash.run({ days = 14 })
table.insert(store.log, "0:" .. args.days)]]
  )
  eq(log, { "1:14", "2:15", "1:14", "0:0" })
  eq(kept(d), 20)
end

T["callback case: assignments before a failure are kept, within the failing code not"] = function()
  local d, p = lua_case(
    "cb_fail_after",
    [[
if meta.run.depth > 0 then args.days = 10; return { { ok = 1 } } end
dbdash.run()
error("later")]]
  )
  eq(p.error ~= nil, true)
  eq(kept(d), 10) -- the callback's script returned before the failure
  d, p = lua_case(
    "cb_fail_within",
    [[
if meta.run.depth > 0 then args.days = 10; error("inside") end
dbdash.run()]]
  )
  eq(p.error ~= nil, true)
  eq(kept(d), 0) -- assigned in the code that failed: not applied
end

T["callback case: assigning the current value keeps nothing; R resets an assignment"] = function()
  local d, p = lua_case(
    "cb_same_value",
    [[
if meta.run.depth > 0 then args.days = 14; return { { ok = 1 } } end
dbdash.run({ days = 14 })
args.days = 0]]
  )
  eq(p.error, nil)
  eq(d.state.modified.days, nil) -- 14 was the callback's value already; 0 the caller's
  local d2 = lua_case(
    "cb_reset",
    [[
if meta.run.depth > 0 then args.days = 10; return { { ok = 1 } } end
dbdash.run()]]
  )
  eq(kept(d2), 10)
  require("dbdash.args").reset(d2.state)
  eq(kept(d2), 0)
  again(d2.panels[1])
  eq(kept(d2), 10) -- the next refresh's callback assigns it again
end

-- Run records: meta.run, meta.runs, meta.prev, meta.prev_ok, meta.prev_runs, meta.prev_ok_runs.

---A lua:// panel whose script logs `meta` into store.seen (one entry per run) and may call
---back once; `fail` makes refresh number `fail` fail after its callback.
local function runs_case(name, fail)
  local d = start(
    name,
    ([[
database: { url: "lua://" }
query:
  args: [{ name: n, type: int, default: 1 }]
  sql: |
    store.seen = store.seen or {}
    local entry = { run = meta.run, runs_before = #meta.runs, prev = meta.prev, prev_ok = meta.prev_ok,
                    prev_runs = meta.prev_runs, prev_ok_runs = meta.prev_ok_runs }
    table.insert(store.seen, entry)
    if meta.run.depth == 0 then
      local r = dbdash.run({ n = args.n * 10 })
      entry.callback_result = r
      entry.runs_after = #meta.runs
      entry.runs = meta.runs
      if meta.refresh_count == %d then error("fail " .. meta.refresh_count) end
    end
    return { { n = args.n, count = meta.refresh_count } }
]]):format(fail or -1)
  )
  return d, d.panels[1]
end

T["run records: the refresh and its callback, ids, kinds, parents, times"] = function()
  local _, p = runs_case("rec1")
  assert(p.rs, p.error and sched.format_error(p.error))
  local refresh, callback = p.store.seen[1], p.store.seen[2]
  local r, c = refresh.run, callback.run
  eq({ r.kind, r.depth, r.parent_id, r.refresh_id }, { "refresh", 0, nil, r.id })
  eq({ c.kind, c.depth, c.parent_id, c.refresh_id, c.args.n }, { "callback", 1, r.id, r.id, 10 })
  eq(r.id:match("^%x+%-%x+%-7") ~= nil and c.id > r.id, true)
  eq(type(r.started_at) == "number" and c.started_at >= r.started_at, true)
  -- first refresh: nothing before it
  eq(
    { refresh.prev, refresh.prev_ok, refresh.prev_runs, refresh.prev_ok_runs },
    { nil, nil, nil, nil }
  )
  -- meta.runs is live in Lua: the callback is in it, finished, once dbdash.run() returned
  eq({ refresh.runs_before, refresh.runs_after }, { 1, 2 })
  local done = refresh.runs[2]
  eq(
    { done.id, done.ok, done.elapsed_ms, done.finished_at - done.started_at },
    { c.id, true, done.elapsed_ms, done.elapsed_ms }
  )
  -- its data: rendered sql, query result, result (what dbdash.run() returned)
  eq(type(done.sql), "string")
  eq(done.result, refresh.callback_result)
  eq(done.result.rows[1], { 1, 10 }) -- columns: count, n
end

T["run records: meta.prev is the last refresh, finished, with its data"] = function()
  local _, p = runs_case("rec2")
  again(p)
  local first, second = p.store.seen[1], p.store.seen[3]
  local prev = second.prev
  eq({ prev.id, prev.kind, prev.ok, prev.error }, { first.run.id, "refresh", true, nil })
  eq(
    { prev.finished_at >= prev.started_at, prev.elapsed_ms == prev.finished_at - prev.started_at },
    { true, true }
  )
  eq(type(prev.sql), "string")
  eq(prev.result.rows[1], { 1, 1 }) -- count 1, n 1
  -- prev_ok is the same refresh
  eq(second.prev_ok.id, first.run.id)
  eq(second.prev_ok, prev)
  -- the previous life: the refresh and its callback
  eq(
    vim.tbl_map(function(x)
      return x.kind
    end, second.prev_runs),
    { "refresh", "callback" }
  )
  eq(second.prev_ok_runs, second.prev_runs)
end

T["run records: after a failed refresh, prev is it, prev_ok the last success"] = function()
  local _, p = runs_case("rec3", 2)
  again(p) -- refresh 2 fails after its callback
  eq(p.error ~= nil, true)
  again(p) -- refresh 3 sees both
  local first, second, third = p.store.seen[1], p.store.seen[3], p.store.seen[5]
  eq({ third.prev.id, third.prev.ok }, { second.run.id, false })
  eq(third.prev.error:find("fail 2", 1, true) ~= nil, true)
  eq(third.prev_ok.id, first.run.id)
  eq(third.prev_ok.result.rows[1][1], 1) -- refresh 1's rows (count 1), not 2's
  -- the failed refresh still recorded what it got: its callback finished fine
  eq({ #third.prev_runs, third.prev_runs[1].id, third.prev_runs[2].ok }, { 2, second.run.id, true })
  eq(third.prev_ok_runs[1].id, first.run.id)
end

T["run records: nested and sibling callbacks, failed callbacks"] = function()
  local d = start(
    "rec4",
    [[
database: { url: "lua://" }
query:
  sql: |
    if meta.run.depth == 0 then
      dbdash.run()
      pcall(dbdash.run, { })  -- a second one, at depth 1 it calls once more
      store.runs = meta.runs
      return { { x = 1 } }
    end
    if meta.run.depth == 1 and meta.runs[#meta.runs].kind == "callback" and #meta.runs == 3 then
      dbdash.run()
    end
    if meta.run.depth == 2 then error("deep") end
    return { { x = meta.run.depth } }
]]
  )
  local p = d.panels[1]
  local runs = p.store.runs
  -- refresh, callback A (1), callback B (1), B's callback (2, failed); the records are live:
  -- the refresh has finished by now
  eq(
    vim.tbl_map(function(x)
      return { x.kind, x.depth, x.ok }
    end, runs),
    {
      { "refresh", 0, true },
      { "callback", 1, true },
      { "callback", 1, false },
      { "callback", 2, false },
    }
  )
  eq(
    { runs[2].parent_id, runs[3].parent_id, runs[4].parent_id },
    { runs[1].id, runs[1].id, runs[3].id }
  )
  eq({ runs[4].refresh_id, runs[4].error:find("deep", 1, true) ~= nil }, { runs[1].id, true })
  eq(runs[3].error ~= nil, true) -- failed because its callback failed
end

T["run records: in templates, meta.runs follows the Lua that ran"] = function()
  local d = start(
    "rec5",
    [[
database: { url: "sqlite:///:memory:" }
query:
  sql: |
    {% if meta.run.depth == 0 %}{% lua %}dbdash.run(){% endlua %}{% endif %}
    SELECT {{ meta.runs | length }} AS runs, '{{ meta.run.kind }}' AS kind,
           '{{ meta.run.parent_id }}' AS parent, '{{ meta.prev.id if meta.prev is not none else "-" }}' AS prev
]]
  )
  local p = d.panels[1]
  assert(p.rs, p.error and sched.format_error(p.error))
  eq(p.rs.rows[1], { 2, "refresh", "None", "-" })
  local first = p.prev.id
  again(p)
  eq(p.rs.rows[1][4], first)
end

T["run records: showing the SQL or a description is not a run"] = function()
  local _, p = runs_case("rec6")
  local runs, prev = #p.prev_runs, p.prev.id
  local done = false
  p:render_async(function()
    done = true
  end)
  vim.wait(3000, function()
    return done
  end, 10)
  eq({ #p.prev_runs, p.prev.id }, { runs, prev })
end

T["run records: a query that worked and a transform that failed"] = function()
  local d = start(
    "rec7",
    [[
database: { url: "sqlite:///:memory:" }
query:
  sql: SELECT 7 AS x
  transform: |
    error("bad transform")
]]
  )
  local p = d.panels[1]
  eq(p.error ~= nil, true)
  local r = p.prev
  eq(
    { r.ok, r.query.rows[1][1], r.result, r.error:find("bad transform", 1, true) ~= nil },
    { false, 7, nil, true }
  )
  eq(r.sql, "SELECT 7 AS x")
  eq(p.prev_ok, nil)
end

T["meta.callback, prev_query, prev_result and prev_error are gone (meta.run, prev, prev_ok)"] = function()
  local d = start(
    "gone",
    [[
database: { url: "lua://" }
query:
  sql: |
    return { { cb = tostring(meta.callback), pq = tostring(meta.prev_query),
               pr = tostring(meta.prev_result), pe = tostring(meta.prev_error) } }
]]
  )
  eq(d.panels[1].rs.rows[1], { "nil", "nil", "nil", "nil" })
  for i, name in ipairs({ "callback", "prev_query", "prev_result", "prev_error" }) do
    local e = start(
      "gone" .. i,
      ("database: { url: 'sqlite:///:memory:' }\nquery: { sql: 'SELECT {{ meta.%s }}' }\n"):format(
        name
      )
    )
    eq({ name, e.panels[1].error ~= nil }, { name, true })
  end
end

T["callbacks of callbacks stop at a meta.run.depth (the :help dbdash-callback example)"] = function()
  local d = start(
    "depth",
    [[
database: { url: "sqlite:///:memory:" }
query:
  args: [{ name: days, type: int, default: 7 }]
  sql: SELECT {{ args.days }} AS days
  transform: |
    if meta.run.depth < 3 then
      dbdash.run({ days = args.days * 2 })
    end
    if meta.run.kind == "callback" then
      return rs
    end
    local out = {}
    for _, r in ipairs(meta.runs) do
      out[#out + 1] = { depth = r.depth, days = r.args.days }
    end
    return out
]]
  )
  local p = d.panels[1]
  assert(p.rs, p.error and sched.format_error(p.error))
  -- columns sorted by name: days, depth
  eq(p.rs.rows, { { 7, 0 }, { 14, 1 }, { 28, 2 }, { 56, 3 } })
end

return T
