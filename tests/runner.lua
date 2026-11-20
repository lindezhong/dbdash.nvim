-- Test entry point used by `make test`. Runs one file when FILE is given, else all test_*.lua.
local M = {}

---@param file string? path to a single test file, empty for the whole suite
function M.run(file)
  local opts = {
    execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }) },
  }
  if file and file ~= "" then
    opts.collect = { find_files = function() return { file } end }
  else
    opts.collect = {
      find_files = function()
        return vim.fn.globpath("tests", "**/test_*.lua", false, true)
      end,
    }
  end
  MiniTest.run(opts)
end

return M
