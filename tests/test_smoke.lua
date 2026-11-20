-- Sanity check that the test harness works.
local T = MiniTest.new_set()

T["harness runs"] = function()
  MiniTest.expect.equality(1 + 1, 2)
end

return T
