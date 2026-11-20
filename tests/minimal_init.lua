-- Minimal init for headless test runs: only this plugin and mini.test on the runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath = { root, root .. "/deps/mini.nvim", vim.env.VIMRUNTIME }
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
vim.o.swapfile = false
require("mini.test").setup()
