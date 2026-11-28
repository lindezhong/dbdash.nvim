-- Timing of loading a config (DBDASH_PERF=0 skips): the first load in a fresh Neovim finds
-- the validators, the drivers and the chart types on the runtimepath (ARCHITECTURE.md
-- #extending); later loads reuse what was found. Budgets about 3x what was measured.
local H = require("tests.perf.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

-- measured on the development machine: first 25 ms (before finding: 22 ms), then 2.7 ms
local FIRST, AGAIN = 80, 10

T["loading a config: the first in a fresh Neovim, then again"] = function()
  if not H.timing_enabled() then
    MiniTest.skip("DBDASH_PERF=0")
  end
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({
    "vim.opt.rtp:prepend(vim.fn.getcwd())",
    "local f = vim.fn.getcwd() .. '/example/dashboards/multi_panel.yaml'",
    "local t0 = vim.uv.hrtime()",
    "assert(require('dbdash.config').load(f))",
    "local first = (vim.uv.hrtime() - t0) / 1e6",
    "t0 = vim.uv.hrtime()",
    "for _ = 1, 10 do require('dbdash.config').load(f) end",
    "io.stdout:write(('%.1f %.1f'):format(first, (vim.uv.hrtime() - t0) / 1e6 / 10))",
  }, script)
  local r = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, { text = true })
    :wait()
  local first, again = (r.stdout or ""):match("^([%d.]+) ([%d.]+)$")
  first, again = tonumber(first), tonumber(again)
  MiniTest.add_note(("config.load: first %s ms, then %s ms"):format(first, again))
  eq({ first ~= nil, (first or 1e9) <= FIRST, (again or 1e9) <= AGAIN }, { true, true, true })
end

return T
