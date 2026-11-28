-- Push sources in dashboards: the queue and its single consumer, drawing on the interval,
-- the end of a source, restarting, callbacks on the same item, hidden dashboards, stopping.
local sched = require("dbdash.dashboard")
local eq = MiniTest.expect.equality

local RUN_LUA = vim.fs.normalize(vim.fn.fnamemodify("tests/fixtures/run_lua.lua", ":p"))
local INTERP = ("[%q, '--clean', '-l', %q]"):format(vim.v.progpath, RUN_LUA)

local dir, notes
local real_notify = vim.notify
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      -- (no_show dashboards are not visible: keep them from pausing)
      require("dbdash").setup({ lua = { confirm = false }, dashboard = { pause_hidden = false } })
      notes = {}
      ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
      vim.notify = function(msg)
        notes[#notes + 1] = msg
      end
    end,
    post_case = function()
      vim.notify = real_notify
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      vim.wait(100)
      require("dbdash").setup({})
    end,
  },
})

local function start(text)
  local path = dir .. "/push.yaml"
  sched.stop(sched.normalize(path)) -- a case may start a second one
  vim.fn.writefile(vim.split(text, "\n"), path)
  require("dbdash.view.dashboard").start(path, { no_show = true })
  return assert(sched.get(sched.normalize(path)), "dashboard did not start")
end

local function wait(fn, ms)
  vim.wait(ms or 5000, fn, 10)
  return fn()
end

local function rows(p)
  return p.state.result and p.state.result.rows or {}
end

T["every item is processed in order, one at a time; meta.run.kind is push"] = function()
  local d = start([[
database: { url: "luastream://" }
query:
  sql: |
    for i = 1, 5 do print(i) end
  transform: |
    assert(not store.busy, "two at once")
    store.busy = true
    dbdash.sleep(30)
    store.busy = false
    store.seen = store.seen or {}
    table.insert(store.seen, rs)
    return { { n = tonumber(rs), kind = meta.run.kind, prev = meta.prev and meta.prev.kind or "" } }
show: { type: table, interval: 1s }
]])
  local p = d.panels[1]
  eq(
    wait(function()
      return p.ended
    end),
    true
  )
  eq(p.store.seen, { "1", "2", "3", "4", "5" })
  eq(rows(p), { { "push", 5, "push" } }) -- (columns by name: kind, n, prev)
  eq({ p.stream.received, p.stream.processed, p.refresh_count }, { 5, 5, 5 })
  eq(p.state.source, "ended")
  eq(p.state.error, nil)
end

T["without query.transform an item must be JSON rows"] = function()
  local d = start([=[
database: { url: "luastream://" }
query:
  sql: |
    print('[{"a": 1, "b": "x"}]')
    print('{"columns": ["c"], "rows": [[2]]}')
show: { type: table, interval: 1s }
]=])
  local p = d.panels[1]
  wait(function()
    return p.ended
  end)
  eq({ p.state.result.columns[1].name, rows(p) }, { "c", { { 2 } } })
  d = start([[
database: { url: "luastream://" }
query: { sql: "print('not json')" }
show: { type: table, interval: 1s }
]])
  p = d.panels[1]
  wait(function()
    return p.ended
  end)
  eq(sched.format_error(p.state.error):find("add query.transform", 1, true) ~= nil, true)
end

T["drawing: at most once per interval, only when something is new"] = function()
  local d = start([[
database: { url: "luastream://" }
query:
  sql: |
    for i = 1, 40 do print(i) dbdash.sleep(25) end
  transform: "return { { n = tonumber(rs) } }"
show: { type: table, interval: 1s }
]])
  local p = d.panels[1]
  local draws = 0
  local view = require("dbdash.view.dashboard")
  local real = view.redraw
  ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
  view.redraw = function(dd)
    draws = draws + (dd == d and 1 or 0)
    return real(dd)
  end
  MiniTest.finally(function()
    ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
    view.redraw = real
  end)
  wait(function()
    return p.ended
  end, 8000)
  -- ~1 s of items: about two interval ticks and the final draw (no draw per item).
  eq(draws <= 5, true)
  eq(rows(p), { { 40 } })
  -- Nothing new: no draws (after the end's own draw, which is coalesced like any other).
  vim.wait(50)
  draws = 0 -- (view.redraw still counts)
  vim.wait(2200)
  eq(draws, 0)
end

T["the end stops this panel only; r starts it again"] = function()
  local d = start([[
database: { url: "sqlite:///:memory:" }
panels:
  - database: { url: "luastream://" }
    query: { sql: "print('[{\"n\": 1}]')" }
    show: { type: table, interval: 1s }
  - query: { sql: "SELECT 1 AS x" }
    show: { type: table, interval: 1s }
]])
  local p, other = d.panels[1], d.panels[2]
  wait(function()
    return p.ended
  end)
  local count = other.refresh_count or 0
  vim.wait(1300)
  eq((other.refresh_count or 0) > count, true) -- the other panel keeps refreshing
  eq(p.next_at, nil) -- no next tick
  d:restart() -- r
  eq(p.state.source ~= "ended", true)
  wait(function()
    return p.ended
  end)
  eq(p.stream.processed, 1)
end

T["changed arguments restart the source with the new values"] = function()
  local d = start([[
database: { url: "luastream://" }
args: [ { name: word, default: one } ]
query:
  sql: |
    print("{{ args.word }}") while true do dbdash.sleep(50) end
  transform: "return { { w = rs } }"
show: { type: table, interval: 1s }
]])
  local p = d.panels[1]
  eq(
    wait(function()
      return rows(p)[1] and rows(p)[1][1] == "one"
    end),
    true
  )
  local first = assert(p.stream)
  require("dbdash.args").set_modified(d.arg_state, "word", "two")
  d:restart()
  eq(
    wait(function()
      return rows(p)[1] ~= nil and rows(p)[1][1] == "two"
    end),
    true
  )
  eq(first.token.cancelled, true) -- the old one stopped
end

T["dbdash.run() in a push panel works on the same item"] = function()
  local d = start([[
database: { url: "luastream://" }
args: [ { name: x, type: int, default: 1 } ]
query:
  sql: "print('a') print('b')"
  transform: |
    if meta.run.kind == "callback" then return { { v = rs .. args.x } } end
    local other = dbdash.run({ x = 2 })
    return { { item = rs, callback = other.rows[1][1], parent = meta.run.kind } }
show: { type: table, interval: 1s }
]])
  local p = d.panels[1]
  wait(function()
    return p.ended
  end)
  eq(rows(p), { { "b2", "b", "push" } })
end

T["a full queue drops the oldest items"] = function()
  require("dbdash").setup({
    lua = { confirm = false },
    dashboard = { pause_hidden = false },
    push = { max_queue = 3 },
  })
  local d = start([[
database: { url: "luastream://" }
query:
  sql: "for i = 1, 10 do print(i) end"
  transform: |
    dbdash.sleep(50)
    store.seen = store.seen or {}
    table.insert(store.seen, tonumber(rs))
    return { { n = tonumber(rs) } }
show: { type: table, interval: 1s }
]])
  local p = d.panels[1]
  wait(function()
    return p.ended
  end)
  eq({ p.stream.received, p.stream.dropped }, { 10, 6 })
  eq(p.store.seen, { 1, 8, 9, 10 }) -- the first one was being processed
end

T["hidden: items keep coming, drawing waits until shown"] = function()
  local d = start([[
database: { url: "luastream://" }
query:
  sql: |
    for i = 1, 6 do print(i) dbdash.sleep(100) end
  transform: "return { { n = tonumber(rs) } }"
show: { type: table, interval: 1s }
]])
  local p = d.panels[1]
  wait(function()
    return p.stream and p.stream.processed >= 1
  end)
  d:pause()
  local draws = 0
  local view = require("dbdash.view.dashboard")
  local real = view.redraw
  ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
  view.redraw = function(dd)
    draws = draws + (dd == d and 1 or 0)
    return real(dd)
  end
  MiniTest.finally(function()
    ---@diagnostic disable-next-line: duplicate-set-field (replaced for the test)
    view.redraw = real
  end)
  local before = p.stream.processed
  vim.wait(350)
  eq(p.stream.processed > before, true) -- still consuming
  eq(draws, 0)
  d:resume()
  eq(
    wait(function()
      return draws > 0
    end, 1500),
    true
  )
end

T["stopping the dashboard kills the script"] = function()
  local pidfile = dir .. "/pid"
  local d = start(([[
database:
  url: "exec://"
  options: { interpreter: %s }
query:
  sql: |
    local f = io.open(%q, "w") f:write(vim.fn.getpid()) f:close()
    while true do io.write('[{"t": 1}]\n') io.stdout:flush() vim.uv.sleep(100) end
show: { type: table, interval: 1s }
]]):format(INTERP, pidfile))
  local p = d.panels[1]
  eq(
    wait(function()
      return p.state.result ~= nil
    end),
    true
  )
  local pid = assert(tonumber(vim.fn.readfile(pidfile)[1]))
  sched.stop(d.path)
  eq(
    wait(function()
      return vim.uv.kill(pid, 0) ~= 0
    end),
    true
  )
end

T["webhook: requests become items of the panel; its header says where it listens"] = function()
  local d = start([[
database: { url: "webhook://127.0.0.1:0/in" }
query:
  sql: ""
  transform: "return { { got = rs, method = request.method } }"
show: { type: table, interval: 1s }
]])
  local p = d.panels[1]
  eq(
    wait(function()
      return p.state.source:match("^listening") ~= nil
    end),
    true
  )
  local port = tonumber(p.state.source:match(":(%d+)$"))
  local done
  vim.system({
    vim.v.progpath,
    "--clean",
    "--headless",
    "-l",
    RUN_LUA,
    ([[
    local tcp = vim.uv.new_tcp()
    tcp:connect("127.0.0.1", %d, function()
      tcp:write("POST /in HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n\r\nhello\n")
    end)
    vim.wait(1000)
  ]]):format(port),
  }, {}, function()
    done = true
  end)
  eq(
    wait(function()
      return rows(p)[1] ~= nil
    end),
    true
  )
  eq(rows(p), { { "hello", "POST" } })
  wait(function()
    return done
  end)
end

return T
