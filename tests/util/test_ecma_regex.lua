-- ECMA-262 patterns (JSON Schema's `pattern`) against results recorded from a real
-- ECMAScript engine (tests/util/regex_gen.js). Lookaround, backreferences and Unicode
-- properties other than general categories are refused (by us; they are valid ECMAScript).
local re = require("dbdash.util.ecma_regex")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local cases = vim.json.decode(table.concat(vim.fn.readfile("tests/util/regex_cases.json"), "\n"))

T["matches like ECMAScript"] = function()
  local wrong = {}
  for _, c in ipairs(cases) do
    if not c.error then
      local r, err = re.get(c.pattern)
      local got
      if r then
        got = r:test(c.input)
      else
        got = "error: " .. tostring(err)
      end
      if got ~= c.match then
        wrong[#wrong + 1] = ("%s on %q: %s"):format(c.pattern, c.input, tostring(got))
      end
    end
  end
  eq(wrong, {})
end

T["invalid and unsupported patterns are errors"] = function()
  local accepted = {}
  for _, c in ipairs(cases) do
    if c.error and re.get(c.pattern) then
      accepted[#accepted + 1] = c.pattern
    end
  end
  eq(accepted, {})
  local _, err = re.get("(?=a)")
  eq(assert(err):find("lookaround", 1, true) ~= nil, true)
end

T["long inputs do not overflow the stack"] = function()
  local r = assert(re.get("^[a-z]+$"))
  eq(r:test(("a"):rep(100000)), true)
  eq(assert(re.get("^(ab)*$")):test(("ab"):rep(2000)), true)
end

return T
