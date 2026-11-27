-- Test entry point used by `make test`. Runs one file when FILE is given, else all test_*.lua.
local M = {}

---@param file string? path to a single test file, empty for the whole suite
function M.run(file)
  local files = (file and file ~= "") and { file }
    or vim.fn.globpath("tests", "**/test_*.lua", false, true)
  -- A test file that does not compile would make mini.test wait forever: fail fast instead.
  for _, f in ipairs(files) do
    local ok, err = loadfile(f)
    if not ok then
      io.stderr:write("cannot load " .. f .. ": " .. tostring(err) .. "\n")
      vim.cmd("cquit 1")
    end
  end
  MiniTest.run({
    collect = {
      find_files = function()
        return files
      end,
    },
    execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }) },
  })
end

return M
