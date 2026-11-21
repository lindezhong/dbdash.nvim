-- Sidebar file listing options (sidebar.dir, pattern, exclude, recursive).
local sidebar = require("dbdash.view.sidebar")
local dbdash = require("dbdash")
local eq = MiniTest.expect.equality

local dir
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fn.tempname()
      for _, f in ipairs({ "a.yaml", "b.yml", "c.schema.yaml", "notes.txt", "d.dash.yaml", "sub/e.yaml", ".hidden/f.yaml" }) do
        vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. f), "p")
        vim.fn.writefile({}, dir .. "/" .. f)
      end
    end,
    post_case = function()
      dbdash.setup({})
    end,
  },
})

T["defaults: *.yaml and *.yml in the directory, without schemas"] = function()
  dbdash.setup({})
  eq(sidebar.config_files(dir), { "a.yaml", "b.yml", "d.dash.yaml" })
end

T["pattern and exclude"] = function()
  dbdash.setup({ sidebar = { pattern = { "*.dash.yaml" } } })
  eq(sidebar.config_files(dir), { "d.dash.yaml" })
  dbdash.setup({ sidebar = { exclude = { "a.*" } } })
  eq(sidebar.config_files(dir), { "b.yml", "c.schema.yaml", "d.dash.yaml" })
end

T["recursive lists subdirectories except hidden ones"] = function()
  dbdash.setup({ sidebar = { recursive = true } })
  eq(sidebar.config_files(dir), { "a.yaml", "b.yml", "d.dash.yaml", "sub/e.yaml" })
end

T["dir: path, relative path, function, default cwd"] = function()
  dbdash.setup({ sidebar = { dir = dir .. "/sub" } })
  eq(sidebar.dir(), vim.fs.normalize(dir .. "/sub"))
  dbdash.setup({ sidebar = { dir = function()
    return dir
  end } })
  eq(sidebar.dir(), vim.fs.normalize(dir))
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  dbdash.setup({ sidebar = { dir = "sub" } })
  eq(sidebar.dir(), vim.fs.normalize(vim.fn.getcwd() .. "/sub"))
  dbdash.setup({})
  eq(sidebar.dir(), vim.fs.normalize(vim.fn.getcwd()))
  vim.cmd.cd(vim.fn.fnameescape(cwd))
end

return T
