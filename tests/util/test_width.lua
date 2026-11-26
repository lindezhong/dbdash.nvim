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

T["wrap: at spaces, long words cut, by character"] = function()
  eq(W.wrap("short", 10), { "short" })
  eq(W.wrap("the quick brown fox", 10), { "the quick", "brown fox" })
  eq(W.wrap("a  b", 2), { "a", "b" })
  eq(W.wrap("abcdefghij k", 4), { "abcd", "efgh", "ij k" })
  eq(W.wrap("中文中文", 4), { "中文", "中文" })
  eq(W.wrap("abcdef", 4, "char"), { "abcd", "ef" })
  eq(W.wrap("", 4), { "" })
end

T["clamp: at most n lines, the last ends with the ellipsis"] = function()
  eq(W.clamp({ "a", "b" }, 3, 5), { "a", "b" })
  eq(W.clamp({ "a", "b", "c" }, 2, 5), { "a", "b…" })
  eq(W.clamp({ "aaaaa", "b" }, 1, 5), { "aaaa…" })
  eq(W.clamp({ "aa", "b" }, 1, 5, "..."), { "aa..." })
  eq(W.clamp({ "a", "b" }, nil, 5), { "a", "b" })
end

return T
