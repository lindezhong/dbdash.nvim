-- doc/dbdash.txt must stay complete: every command, template filter, test, global
-- and setup option is documented, help tags build, and lines fit in 78 columns.
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local DOC = table.concat(vim.fn.readfile("doc/dbdash.txt"), "\n")

local function missing(names, fmt)
  local out = {}
  for _, n in ipairs(names) do
    if not DOC:find(fmt:format(n), 1, true) then
      out[#out + 1] = n
    end
  end
  table.sort(out)
  return out
end

T["every user command has a help tag"] = function()
  vim.cmd("runtime plugin/dbdash.lua")
  local names = {}
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match("^DbDash") or name == "Mksession" then
      names[#names + 1] = name
    end
  end
  eq(#names > 10, true)
  eq(missing(names, "*:%s*"), {})
end

T["every template filter, test and global is documented"] = function()
  require("dbdash.template")
  local R = require("dbdash.template.runtime")
  local names = {}
  for _, tbl in ipairs({ R.filters, R.tests, R.globals }) do
    for k in pairs(tbl) do
      names[#names + 1] = k
    end
  end
  eq(missing(names, "%s"), {})
  eq(missing(R.METHOD_NAMES, "%s("), {})
end

T["every setup option is documented"] = function()
  local names = {}
  for k, v in pairs(require("dbdash").DEFAULTS) do
    names[#names + 1] = k
    if type(v) == "table" and not vim.islist(v) then
      for sub in pairs(v) do
        names[#names + 1] = sub
      end
    end
  end
  table.insert(names, "height") -- nil by default, so not a key of DEFAULTS.defaults
  eq(missing(names, " %s = "), {})
end

T["help tags build and lines fit in 78 columns"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/doc", "p")
  vim.fn.writefile(vim.fn.readfile("doc/dbdash.txt"), dir .. "/doc/dbdash.txt")
  vim.cmd("helptags " .. vim.fn.fnameescape(dir .. "/doc")) -- raises on duplicate tags
  local long = {}
  for i, l in ipairs(vim.split(DOC, "\n")) do
    if vim.fn.strdisplaywidth(l) > 78 then
      long[#long + 1] = i
    end
  end
  eq(long, {})
end

return T
