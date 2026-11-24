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

return T
