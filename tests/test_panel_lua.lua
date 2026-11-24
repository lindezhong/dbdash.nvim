-- Lua state of a panel across refreshes: `store`, meta.prev_*, dbdash.run() callbacks and
-- assigning arguments (from Lua and {% set args.x %}).
local sched = require("dbdash.scheduler")
local eq = MiniTest.expect.equality

local dir
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      require("dbdash").setup({ lua = { confirm = false } }) -- trust is tested in test_trust.lua
    end,
    post_case = function()
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
  sched.start(path, { no_show = true })
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
  local d = start("store", [[
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
]])
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

T["meta.prev_query / prev_result: the previous refresh's results, before and after the transform"] = function()
  local d = start("prev", [[
database: { url: "sqlite:///:memory:" }
query:
  sql: |
    SELECT {{ meta.refresh_count }} AS n,
           {{ (meta.prev_result.rows[0][0] if meta.prev_result is not none else 0) }} AS prev_doubled,
           {{ (meta.prev_query.rows[0][0] if meta.prev_query is not none else 0) }} AS prev_raw,
           {{ 1 if meta.prev_error is none else 0 }} AS ok
  transform: |
    local r = rs.rows[1]
    local pq = meta.prev_query and meta.prev_query.columns[1] or "none"
    return { columns = { "doubled", "prev_doubled", "prev_raw", "ok", "prev_query_col" },
             rows = { { r[1] * 2, r[2], r[3], r[4], pq } } }
]])
  local p = d.panels[1]
  eq(p.rs.rows[1], { 2, 0, 0, 1, "none" })
  again(p)
  -- prev_result is the transformed row (doubled = 2), prev_query the query's own (n = 1)
  eq(p.rs.rows[1], { 4, 2, 1, 1, "n" })
end

T["meta.prev_error: the previous refresh's error; prev_* keep the last success"] = function()
  local d = start("err", [[
database: { url: "lua://" }
query:
  sql: |
    store.n = (store.n or 0) + 1
    if store.n == 2 then error("boom") end
    return { { n = store.n, prev = meta.prev_result and meta.prev_result.rows[1][2] or 0, -- (err, n, prev)
               err = meta.prev_error or "" } }
]])
  local p = d.panels[1]
  eq(p.rs.rows[1], { "", 1, 0 }) -- columns sorted: err, n, prev
  again(p)
  eq(p.error ~= nil, true)
  again(p)
  local row = p.rs.rows[1]
  eq({ row[2], row[3] }, { 3, 1 }) -- the last success was refresh 1
  eq(row[1]:find("boom", 1, true) ~= nil, true)
  again(p)
  eq(p.rs.rows[1][1], "") -- refresh 3 succeeded: no prev_error
end

T["show.refresh_hidden: keeps refreshing while the dashboard is paused"] = function()
  local d = start("hidden", [[
database: { url: "lua://" }
show: { interval: 1s }
panels:
  - query: { sql: "return { { x = 1 } }" }
    show: { refresh_hidden: true }
  - query: { sql: "return { { x = 2 } }" }
]])
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
  local d = start("hidden_global", [[
database: { url: "lua://" }
interval: 1s
panels:
  - query: { sql: "return { { x = 1 } }" }
    show: { refresh_hidden: true }
  - query: { sql: "return { { x = 2 } }" }
]])
  local p1, p2 = d.panels[1], d.panels[2]
  eq(p1.cfg.follows_global, true)
  d:pause()
  eq(d.gtimer ~= nil, true) -- kept for panel 1
  local h1, h2 = #p1.history, #p2.history
  vim.wait(2600, function()
    return false
  end, 50)
  eq(#p1.history >= h1 + 2, true)
  eq(#p2.history, h2)
  d:resume()
end

T["dbdash.run(): the panel's pipeline with other arguments; meta.callback is the depth"] = function()
  local d = start("cb", [[
database: { url: "sqlite:///:memory:" }
query:
  args: [{ name: n, type: int, default: 1 }]
  sql: |
    SELECT {{ args.n }} AS n, {{ meta.callback }} AS depth,
    {% lua %}
      if meta.callback < 2 then
        local r = dbdash.run({ n = args.n * 10 }).rows[1]
        return "'" .. r[1] .. ":" .. r[2] .. "," .. r[3] .. "'"
      end
      return "'-'"
    {% endlua %} AS chain
  transform: |
    return { columns = { "n", "depth", "chain" }, rows = { rs.rows[1] } }
]])
  local p = d.panels[1]
  assert(p.rs, p.error and sched.format_error(p.error))
  -- the refresh: n = 1, depth 0; its callback: n = 10, depth 1; that one's: n = 100, depth 2
  eq(p.rs.rows[1], { 1, 0, "10:1,100:2,-" })
  eq(p.refresh_count, 1) -- callbacks are not refreshes
end

T["dbdash.run(): from imported modules, transforms and lua://; returns the transformed rows"] = function()
  vim.fn.writefile({ "local M = {}", "function M.twice() return dbdash.run({ k = 2 }).rows[1][1] end", "return M" }, dir .. "/m.lua")
  local d = start("cbs", [[
database: { url: "lua://" }
panels:
  - query:
      args: [{ name: k, type: int, default: 1 }]
      sql: |
        {% import 'm.lua' as m %}
        return { { v = {{ args.k }} * 7, via_module = {{ m.twice() if meta.callback == 0 else 0 }} } }
      transform: |
        local via_transform = meta.callback == 0 and dbdash.run({ k = 3 }).rows[1][1] or 0
        return { { v = rs[1].v, via_module = rs[1].via_module, via_transform = via_transform } }
  - query:
      args: [{ name: k, type: int, default: 1 }]
      sql: |
        if meta.callback == 0 then return { { v = dbdash.run({ k = 5 }).rows[1][1] } } end
        return { { v = args.k * 11 } }
]])
  local p1, p2 = d.panels[1], d.panels[2]
  assert(p1.rs, p1.error and sched.format_error(p1.error))
  -- columns sorted: v, via_module, via_transform
  eq(p1.rs.rows[1], { 7, 14, 21 })
  eq(p2.rs.rows[1][1], 55)
end

T["dbdash.run(): the depth and total limits fail the refresh"] = function()
  local d = start("loop", [[
database: { url: "lua://" }
query: { sql: "dbdash.run(); return {}" }
]])
  local p = d.panels[1]
  eq(sched.format_error(p.error):find("dbdash.run: callbacks nested deeper than 10 (lua.max_callback_depth)", 1, true) ~= nil, true)
  -- shallow but wide: 3 calls per level, 5 levels = 3 + 9 + 27 + 81 + 243 calls
  require("dbdash").setup({ lua = { confirm = false, max_callbacks = 50, max_callback_depth = 5 } })
  d = start("wide", [[
database: { url: "lua://" }
query: { sql: "if meta.callback < 5 then for _ = 1, 3 do dbdash.run() end end; return { { c = meta.callback } }" }
]])
  p = d.panels[1]
  eq(sched.format_error(p.error):find("dbdash.run: more than 50 callbacks in one refresh (lua.max_callbacks)", 1, true) ~= nil, true)
  -- each refresh counts from 0: 3 + 9 = 12 calls per refresh fit 50 every time
  require("dbdash").setup({ lua = { confirm = false, max_callbacks = 12 } })
  d = start("fits", [[
database: { url: "lua://" }
query: { sql: "if meta.callback < 2 then for _ = 1, 3 do dbdash.run() end end; return { { c = 1 } }" }
]])
  p = d.panels[1]
  eq(p.error, nil)
  again(p)
  again(p)
  eq({ p.error, p.refresh_count }, { nil, 3 })
end

T["dbdash.run(): unknown arguments and wrong types are errors"] = function()
  local d = start("badrun", [[
database: { url: "lua://" }
query:
  args: [{ name: n, type: int }]
  sql: "if meta.callback == 0 then dbdash.run({ {{ 'nope' if true }} = 1 }) end; return {}"
]])
  eq(sched.format_error(d.panels[1].error):find("'nope' is not an argument of this panel", 1, true) ~= nil, true)
  d = start("badtype", [[
database: { url: "lua://" }
query:
  args: [{ name: n, type: int }]
  sql: "if meta.callback == 0 then dbdash.run({ n = 'x' }) end; return {}"
]])
  eq(sched.format_error(d.panels[1].error):find("argument 'n' is an int, got a string", 1, true) ~= nil, true)
end

T["dbdash.run(): the outer script keeps its timeout after a callback"] = function()
  local d = start("timeout", [[
database: { url: "lua://" }
query:
  timeout: 1s
  sql: |
    if meta.callback > 0 then return { { x = 1 } } end
    dbdash.run()
    while true do end
]])
  local e = d.panels[1].error
  eq(e ~= nil and sched.format_error(e):find("did not finish within 1.0s", 1, true) ~= nil, true)
end

T["timeouts: a waiting script's deadline does not fire in other code"] = function()
  local d = start("waiting", [[
database: { url: "lua://" }
query:
  timeout: 1s
  sql: |
    dbdash.sleep(300)
    return { { x = 1 } }
]])
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

return T
