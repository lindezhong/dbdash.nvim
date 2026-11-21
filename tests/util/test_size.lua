local size = require("dbdash.util.size")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["numbers are cells"] = function()
  eq(size.resolve(30, 200), 30)
  eq(size.check(30), nil)
end

T["percentages of the total, floored, at least 1"] = function()
  eq(size.resolve("30%", 200), 60)
  eq(size.resolve("33%", 100), 33)
  eq(size.resolve(" 12.5 % ", 81), 10)
  eq(size.resolve("1%", 20), 1)
  eq(size.resolve("100%", 77), 77)
end

T["invalid specs are rejected"] = function()
  for _, v in ipairs({ 0, -3, 2.5, "30", "0%", "120%", "abc%", true, {} }) do
    eq({ v, size.check(v) ~= nil }, { v, true })
  end
  eq(pcall(size.resolve, "30", 100), false)
end

return T
