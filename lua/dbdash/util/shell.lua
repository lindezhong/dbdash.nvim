-- Command lines for vim.system: a list runs directly, a string through the system shell.
local M = {}

---@param cmd string|string[]
---@return string[]
function M.argv(cmd)
  if type(cmd) == "table" then
    return cmd
  end
  if jit.os == "Windows" then
    return { "cmd.exe", "/d", "/s", "/c", cmd }
  end
  return { "sh", "-c", cmd }
end

return M
