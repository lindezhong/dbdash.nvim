local W = require("dbdash.util.width")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["width counts CJK as two cells"] = function()
  eq(W.width("abc"), 3)
  eq(W.width("当前时间"), 8)
  eq(W.width("a中b"), 4)
end

T["truncate adds ellipsis and respects wide chars"] = function()
  eq(W.truncate("hello world", 5), "hell…")
  eq(W.truncate("hello", 5), "hello")
  eq(W.truncate("当前时间", 5), "当前…")
  eq(W.truncate("当前时间", 4, ""), "当前")
  eq(W.truncate("abc", 0), "")
end

T["pad aligns to exact width"] = function()
  eq(W.pad("ab", 4), "ab  ")
  eq(W.pad("ab", 4, "right"), "  ab")
  eq(W.pad("ab", 5, "center"), " ab  ")
  eq(W.pad("中", 3), "中 ")
  eq(W.pad("toolong", 4), "too…")
end

return T
