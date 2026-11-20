-- dbdash.nvim entry point: commands, global mappings and autocmds. Modules load lazily.
if vim.g.loaded_dbdash then
  return
end
vim.g.loaded_dbdash = true

if vim.fn.has("nvim-0.12") == 0 then
  vim.notify("dbdash.nvim requires Neovim 0.12 or newer", vim.log.levels.ERROR)
  return
end

local function cmds()
  return require("dbdash.commands")
end

local command = vim.api.nvim_create_user_command

command("DbDashStart", function(o)
  cmds().start(o.fargs, o.bang)
end, {
  nargs = "+",
  bang = true,
  complete = function(a, l)
    return cmds().complete_start(a, l)
  end,
  desc = "Start a dashboard: DbDashStart[!] <config> [name=value ...]",
})
command("DbDashRestart", function()
  cmds().restart()
end, { desc = "Refresh the current dashboard now" })
command("DbDashStop", function(o)
  cmds().stop(o.args)
end, {
  nargs = "?",
  complete = function(a)
    return cmds().complete_running(a)
  end,
  desc = "Stop a dashboard",
})
command("DbDashList", function()
  cmds().list()
end, { desc = "List running dashboards" })
command("DbDashStatus", function()
  cmds().status()
end, { desc = "Show the current dashboard's status" })
command("DbDash", function()
  cmds().browse()
end, { desc = "Open the dbdash sidebar" })
command("DbDashClose", function()
  cmds().close()
end, { desc = "Close the dbdash sidebar" })
command("DbDashShowVariables", function()
  cmds().show_variables()
end, { desc = "Show dashboard arguments" })
command("DbDashModifyVariable", function()
  cmds().modify_variable()
end, { desc = "Modify a dashboard argument" })
command("DbDashUpdateVariable", function(o)
  local name = table.remove(o.fargs, 1)
  cmds().update_variable(name, #o.fargs > 0 and table.concat(o.fargs, " ") or nil)
end, {
  nargs = "+",
  complete = function(a, l)
    return cmds().complete_update(a, l)
  end,
  desc = "Set a dashboard argument: DbDashUpdateVariable <name> <value>",
})
command("DbDashResetVariables", function()
  cmds().reset_variables()
end, { desc = "Reset dashboard arguments to their defaults" })
command("DbDashShowSQL", function()
  cmds().show_sql()
end, { desc = "Show the rendered query" })
command("DbDashStyle", function(o)
  cmds().style(o.fargs)
end, {
  nargs = "*",
  complete = function(a, l)
    return cmds().complete_style(a, l)
  end,
  desc = "Switch the chart style: DbDashStyle <type> <style> | canvas <name> | reset",
})
for _, name in ipairs({ "DbDashMksession", "Mksession" }) do
  command(name, function(o)
    cmds().mksession(o.bang, o.args)
  end, { nargs = "?", bang = true, complete = "file", desc = "Write a session (dashboards included)" })
end
vim.cmd([[cnoreabbrev <expr> mksession (getcmdtype() ==# ':' && getcmdline() ==# 'mksession') ? 'DbDashMksession' : 'mksession']])

local group = vim.api.nvim_create_augroup("dbdash", { clear = true })

vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "dbdash://*",
  callback = function(ev)
    local path = require("dbdash.view.buffer").path_of(ev.match)
    if path then
      require("dbdash.scheduler").start(path, { buf = ev.buf, no_show = true })
    end
  end,
})
vim.api.nvim_create_autocmd("SessionLoadPost", {
  group = group,
  callback = function()
    require("dbdash.scheduler").adopt_session_buffers()
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if package.loaded["dbdash.scheduler"] then
      require("dbdash.scheduler").stop_all()
    end
  end,
})
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
  group = group,
  callback = function()
    if package.loaded["dbdash.scheduler"] then
      require("dbdash.scheduler").on_resize()
    end
  end,
})
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    require("dbdash.render.highlight").setup()
  end,
})

require("dbdash.render.highlight").setup()
require("dbdash").set_mappings()
