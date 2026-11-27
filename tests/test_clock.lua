-- The clock of a dashboard (dashboard/timer.lua): a panel's own interval and the top-level
-- one meeting at the same moment are one tick, so one query and no skipped tick.
local sched = require("dbdash.dashboard")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("dbdash").setup({ lua = { confirm = false }, dashboard = { pause_hidden = false } })
    end,
    post_case = function()
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
    end,
  },
})

T["own and top-level deadlines at the same moment: one query"] = function()
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile({
    "database: { url: 'lua://' }",
    "interval: 2s",
    "query: { sql: 'return { { x = 1 } }' }",
    "show: { type: table, interval: 1s }",
  }, f)
  sched.start(f, { no_show = true })
  local d = assert(sched.get(sched.normalize(f)))
  local p = d.panels[1]
  vim.wait(4300, function()
    return false
  end, 20)
  local ran, skipped = 0, 0
  for _, h in ipairs(p.history) do
    if h.skipped then
      skipped = skipped + 1
    elseif h.rows then
      ran = ran + 1
    end
  end
  -- at 0, 1, 2 (own and top-level), 3, 4: five queries, not seven
  eq({ ran >= 4 and ran <= 5, skipped }, { true, 0 })
end

return T
