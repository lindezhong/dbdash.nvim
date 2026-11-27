-- Conventions of the code (ARCHITECTURE.md#layers covers the requires): every module says
-- what it is on its first line and is `local M = ...` ... `return M`; no function is 100
-- lines or longer (split it into named functions).
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function modules()
  return vim.fn.globpath("lua/dbdash", "**/*.lua", false, true)
end

local function read(path)
  return vim.fn.readfile(path)
end

T["every module has a header line and returns M"] = function()
  local bad = {}
  for _, path in ipairs(modules()) do
    local lines = read(path)
    local last
    for i = #lines, 1, -1 do
      if lines[i]:match("%S") then
        last = lines[i]
        break
      end
    end
    if not (lines[1] or ""):match("^%-%-") or last ~= "return M" then
      bad[#bad + 1] = path
    end
  end
  eq(bad, {})
end

T["no function is 100 lines or longer"] = function()
  local long = {}
  for _, path in ipairs(modules()) do
    local lines = read(path)
    for i, l in ipairs(lines) do
      local indent = l:match("^(%s*)")
      local opens = l:match("^%s*local%s+function%f[%W]")
        or l:match("^%s*function%f[%W]")
        or l:match("=%s*function%s*%(")
      if opens and not l:match("end[,)]?%s*$") then
        for j = i + 1, #lines do
          local lj = lines[j]
          if lj:match("%S") then
            local ij = lj:match("^(%s*)")
            if #ij == #indent and lj:match("^%s*end%f[%W]") then
              if j - i + 1 >= 100 then
                long[#long + 1] = ("%s:%d (%d lines)"):format(path, i, j - i + 1)
              end
              break
            elseif #ij < #indent then
              break
            end
          end
        end
      end
    end
  end
  eq(long, {})
end

return T
